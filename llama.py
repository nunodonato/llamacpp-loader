#!/usr/bin/env python3
"""llama.py — process and state manager for the llamacpp-loader omarchy shell plugin.

The QML bar widget and panel never talk to llama-server directly for mutations.
They call this CLI, which owns:

  * the model-library state file
  * building the llama-server argv from a model's stored settings
  * launching llama-server fully detached (so it survives the shell dying)
  * ejecting a loaded server safely (pid-verified SIGTERM)

Live status probing (/health, /slots, /metrics) is done from QML over the HTTP
API, not here; this tool is about launch/eject/persistence.

Usage:
  llama.py list                            print the model library (JSON array)
  llama.py status                          print the whole state file (JSON)
  llama.py add --json '<model object>'     upsert a model by id
  llama.py remove --model-id <id>          remove a model (fails if loaded)
  llama.py load --model-id <id> [--host H] [--port P] [--metrics on|off] [--dry-run]
  llama.py eject [--force]
  llama.py build --model-id <id> [--host H] [--port P] [--metrics on|off]  print the argv
  llama.py config [--json '{"host":...,"port":...,"extraArgs":[...]}']  read/merge server config
  llama.py progress                        report the launch phase (unloaded/downloading/starting/crashed)

State file (JSON):
  {
    "version": 1,
    "server": { "host": "127.0.0.1", "port": 8080, "extraArgs": ["--no-mmap"] },
    "models": [ { "id", "name", "hfRepo", "hfFile", "quant", "ctxSize",
                  "nGpuLayers", "nCpuMoe", "cpuMoe", "embeddings", "extraArgs": [], "hfSize": 0 } ],
    "loaded": { "modelId", "pid", "port", "startedAt", "argv" }
  }
"""

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Default paths (overridable for tests). NOTE: Path("") is NOT falsy (it equals
# Path(".")), so guard on the env STRING, not on the constructed Path.
# ---------------------------------------------------------------------------
_DIR = os.environ.get("LLAMA_STATE_DIR", "")
STATE_DIR = Path(_DIR) if _DIR else Path.home() / ".local" / "state" / "omarchy" / "llama"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = STATE_DIR / "llama-server.log"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8080

# llama.cpp / HF hub download cache. The in-progress download is "*.downloadInProgress".
_HF = os.environ.get("HF_HOME", "")
HF_CACHE_DIR = Path(_HF) if _HF else Path.home() / ".cache" / "huggingface"
HF_REPOS_DIR = HF_CACHE_DIR / "hub"


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
def load_state(path=STATE_FILE):
    if not path.exists():
        return {"version": 1, "models": [], "loaded": None,
                "server": {"host": DEFAULT_HOST, "port": DEFAULT_PORT, "extraArgs": []}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("state is not a JSON object")
        data.setdefault("version", 1)
        data.setdefault("models", [])
        if "loaded" not in data:
            data["loaded"] = None
        if "server" not in data or not isinstance(data["server"], dict):
            data["server"] = {}
        data.setdefault("server", {})
        s = data["server"]
        s.setdefault("host", DEFAULT_HOST)
        s.setdefault("port", DEFAULT_PORT)
        s.setdefault("extraArgs", [])
        return data
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"could not read state: {e}"}), flush=True)
        sys.exit(1)


def save_state(state, path=STATE_FILE):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def find_model(state, model_id):
    for m in state.get("models", []):
        if m.get("id") == model_id:
            return m
    return None


# ---------------------------------------------------------------------------
# argv construction (single source of truth; Model.js keeps a display mirror)
# ---------------------------------------------------------------------------
def server_binary():
    path = shutil.which("llama-server")
    return path or "llama-server"


def normalize_extra_args(value):
    """Accept a list of tokens or a shell-ish string; return a list of tokens."""
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if str(v) != ""]
    try:
        return shlex.split(str(value))
    except Exception:
        return str(value).split()


def build_server_args(model, state=None, *, host=None, port=None, metrics=True):
    """Build the llama-server argv for a model.

    host/port come from the explicit args, else from the state's server block.
    server.extraArgs are appended (global defaults), then model.extraArgs, so a
    per-model tweak can override a global default that appears earlier.
    """
    state = state or {}
    server = state.get("server") or {}
    eff_host = host or server.get("host") or DEFAULT_HOST
    eff_port = port or server.get("port") or DEFAULT_PORT

    argv = [server_binary(), "--host", str(eff_host), "--port", str(int(eff_port))]

    # Model source: Hugging Face. Repo carries an optional :quant.
    repo = (model.get("hfRepo") or "").strip()
    hf_file = (model.get("hfFile") or "").strip()
    quant = (model.get("quant") or "").strip()
    if repo:
        hf_arg = repo + (f":{quant}" if quant and not hf_file else "")
        argv += ["--hf-repo", hf_arg]
    if hf_file:
        argv += ["--hf-file", hf_file]

    # Context.
    ctx = model.get("ctxSize")
    if ctx:
        argv += ["--ctx-size", str(int(ctx))]

    # GPU offload (whole-model layers).
    ngl = model.get("nGpuLayers")
    if ngl is not None and ngl != "":
        argv += ["-ngl", str(int(ngl))]

    # MoE offload. This llama.cpp build keeps MoE weights in CPU via --n-cpu-moe
    # / --cpu-moe. Older builds used --n-gpu-layers-moe; we prefer the current
    # spelling and fall back to --n-gpu-layers-moe if unchanged behavior is seen.
    if model.get("cpuMoe"):
        argv += ["--cpu-moe"]
    else:
        ncmoe = model.get("nCpuMoe")
        if ncmoe is not None and ncmoe != "" and int(ncmoe) > 0:
            argv += ["--n-cpu-moe", str(int(ncmoe))]

    # Overrides from runtime config (panel passes these through). The server
    # defaults to metrics disabled, so we only add the flag when enabled.
    if metrics:
        argv += ["--metrics"]

    if model.get("embeddings"):
        argv += ["--embeddings"]

    # User-supplied passthrough args, global then per-model.
    argv += normalize_extra_args(server.get("extraArgs"))
    argv += normalize_extra_args(model.get("extraArgs"))

    return argv


# ---------------------------------------------------------------------------
# Detached launch
# ---------------------------------------------------------------------------
def launch(model, state, *, host=None, port=None, metrics=True):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    argv = build_server_args(model, state, host=host, port=port, metrics=metrics)

    # Record the effective port so the widget knows where to probe.
    eff_port = port or (state.get("server") or {}).get("port") or DEFAULT_PORT

    if state.get("loaded") and state["loaded"].get("modelId"):
        if state["loaded"]["modelId"] == model["id"]:
            print(json.dumps({"ok": False, "error": "model is already loaded"}), flush=True)
            sys.exit(1)
        print(json.dumps({"ok": False, "error": "another model is loaded; eject it first"}), flush=True)
        sys.exit(1)

    logf = open(LOG_FILE, "ab", buffering=0)
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    # Parent exits immediately; the server is reparented to init/systemd and
    # therefore survives the omarchy shell being restarted or killed.
    state["loaded"] = {
        "modelId": model["id"],
        "pid": proc.pid,
        "port": int(eff_port),
        "startedAt": int(time.time()),
        "argv": argv,
    }
    save_state(state)
    print(json.dumps({"ok": True, "pid": proc.pid, "argv": argv}), flush=True)


# ---------------------------------------------------------------------------
# Eject (pid-verified so a recycled pid is never killed)
# ---------------------------------------------------------------------------
def cmdline_of(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        return raw.split(b"\x00")
    except (FileNotFoundError, ProcessLookupError):
        return None
    except Exception:
        return None


def pid_matches(pid, loaded):
    parts = cmdline_of(pid)
    if not parts:
        return False
    text = b" ".join(parts).decode("utf-8", errors="replace")
    # Our recorded argv is a transcript of how we launched it. A recycled pid
    # would not carry our port + model markers. Match both to be safe.
    port = f"--port {loaded.get('port')}"
    # Model marker: the hf repo / file, if recorded.
    expected = " ".join(a for a in (loaded.get("argv") or []) if a.startswith(("--hf-", "--model", "-m")))
    if port in text:
        # If we have model markers, require one too.
        if not expected or any(marker in text for marker in expected.split()):
            return True
    return False


def eject(state, force=False, path=STATE_FILE):
    loaded = state.get("loaded")
    if not loaded:
        print(json.dumps({"ok": True, "message": "nothing loaded"}), flush=True)
        return
    pid = loaded.get("pid")
    if not pid:
        state["loaded"] = None
        save_state(state, path)
        print(json.dumps({"ok": True, "message": "cleared stale marker"}), flush=True)
        return

    matched = pid_matches(pid, loaded)
    if not matched and not force:
        alive = cmdline_of(pid) is not None
        if not alive:
            # Already gone; just clear the marker.
            state["loaded"] = None
            save_state(state, path)
            print(json.dumps({"ok": True, "message": "server already down"}), flush=True)
            return
        print(json.dumps({"ok": False, "error": "pid does not match the loaded server; recheck"}), flush=True)
        sys.exit(1)

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError as e:
        print(json.dumps({"ok": False, "error": f"cannot signal pid {pid}: {e}"}), flush=True)
        sys.exit(1)

    # Wait for a graceful exit, escalating to SIGKILL when forced/late.
    deadline = time.time() + (2 if force else 8)
    while time.time() < deadline:
        if cmdline_of(pid) is None:
            break
        time.sleep(0.2)
    else:
        if not force:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            time.sleep(0.5)

    state["loaded"] = None
    save_state(state, path)
    print(json.dumps({"ok": True, "message": "ejected", "pid": pid}), flush=True)


# ---------------------------------------------------------------------------
# add / remove
# ---------------------------------------------------------------------------
def add_model(state, model, path=STATE_FILE):
    allowed = {"id", "name", "hfRepo", "hfFile", "quant", "ctxSize",
               "nGpuLayers", "nCpuMoe", "cpuMoe", "embeddings", "extraArgs"}
    clean = {k: model[k] for k in allowed if k in model}
    if "extraArgs" in clean:
        clean["extraArgs"] = normalize_extra_args(clean["extraArgs"])
    if not clean.get("id"):
        print(json.dumps({"ok": False, "error": "model requires an id"}), flush=True)
        sys.exit(1)
    if not clean.get("hfRepo"):
        print(json.dumps({"ok": False, "error": "model requires an hfRepo"}), flush=True)
        sys.exit(1)
    # Keep per-model tunables stable when editing: only overwrite provided keys.
    clean["ctxSize"] = int(clean.get("ctxSize") or 8192)
    clean["nGpuLayers"] = int(clean.get("nGpuLayers") or 99)
    clean["nCpuMoe"] = int(clean.get("nCpuMoe") or 0)

    models = state["models"]
    for i, m in enumerate(models):
        if m.get("id") == clean["id"]:
            models[i] = {**m, **clean}
            save_state(state, path)
            print(json.dumps({"ok": True, "model": models[i]}, ensure_ascii=False), flush=True)
            return
    models.append(clean)
    save_state(state, path)
    print(json.dumps({"ok": True, "model": clean}, ensure_ascii=False), flush=True)


def remove_model(state, model_id, path=STATE_FILE):
    loaded = state.get("loaded")
    if loaded and loaded.get("modelId") == model_id:
        print(json.dumps({"ok": False, "error": "cannot remove a loaded model; eject it first"}), flush=True)
        sys.exit(1)
    before = len(state["models"])
    state["models"] = [m for m in state["models"] if m.get("id") != model_id]
    if len(state["models"]) == before:
        print(json.dumps({"ok": False, "error": "model not found"}), flush=True)
        sys.exit(1)
    save_state(state, path)
    print(json.dumps({"ok": True, "removed": model_id}), flush=True)


# ---------------------------------------------------------------------------
# server config (host/port/extraArgs) — editable from the panel or by hand
# ---------------------------------------------------------------------------
def config_server(state, updates, path=STATE_FILE):
    server = state.get("server") or {}
    if "host" in updates and str(updates["host"]) != "":
        server["host"] = str(updates["host"])
    if "port" in updates and updates["port"] not in (None, ""):
        server["port"] = int(updates["port"])
    if "extraArgs" in updates:
        server["extraArgs"] = normalize_extra_args(updates["extraArgs"])
    state["server"] = server
    save_state(state, path)
    print(json.dumps({"ok": True, "server": server}, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------------------
# download progress — llama-server (non-TTY) does not render its progress bar,
# so we watch the growing ".downloadInProgress" file in the HF hub cache and
# compare it to the expected model size from the HF API.
# ---------------------------------------------------------------------------
def hf_repo_dir(repo):
    """The HF hub cache repo dir for an owner/repo id."""
    safe = str(repo).strip().strip("/").replace("/", "--")
    return HF_REPOS_DIR / f"models--{safe}"


def find_download(model):
    """If the model is mid-download, return (temp_path, target_name, bytes)."""
    d = hf_repo_dir(model.get("hfRepo"))
    if not d.exists():
        return None
    # Walk only the snapshot/blob dirs that can hold the in-progress file.
    for root, _dirs, files in os.walk(d):
        for fname in files:
            if fname.endswith(".downloadInProgress"):
                target = fname[: -len(".downloadInProgress")]
                p = Path(root) / fname
                try:
                    size = p.stat().st_size
                except OSError:
                    size = 0
                return (p, target, size)
    return None


def hf_file_size(repo, filename, timeout=6):
    """Expected size of a gguf file in a repo, from the HF API (None on error)."""
    repo = str(repo).strip("/")
    try:
        req = urllib.request.Request(
            f"https://huggingface.co/api/models/{repo}?blobs=true",
            headers={"User-Agent": "llamacpp-loader/0.1"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        siblings = data.get("siblings", [])
        for sib in siblings:
            if sib.get("rfilename") == filename or sib.get("rfilename", "").endswith("/" + filename if filename else ""):
                return int(sib.get("size") or 0) or None
    except Exception:
        return None
    return None


def expected_bytes(model, target_name):
    """Expected download size for the model/target; cached on the model in state."""
    cached = model.get("hfSize")
    if cached:
        return int(cached) if not isinstance(cached, bool) and int(cached) > 0 else None
    size = hf_file_size(model.get("hfRepo"), target_name)
    # Only persist a real size (avoid caching None/errors).
    model["hfSize"] = size if size else None
    return size


def is_pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# log tail + failure reason extraction (for the "crashed" phase)
# ---------------------------------------------------------------------------
def read_log_tail(path=LOG_FILE, n=400):
    try:
        if not path.exists():
            return ""
        with open(path, "r", errors="replace", encoding="utf-8") as f:
            lines = f.read().splitlines()
        return "\n".join(lines[-n:])
    except Exception:
        return ""


def extract_error(tail):
    """Return the most relevant error line from a server log tail."""
    # OOM/GPU failures are the actionable case; prefer them over generic ones.
    oom = [
        "out of memory",
        "cuda error",
        "cudaError",
        "not enough memory",
        "virtual memory",
        "cannot allocate",
        "memory allocation",
    ]
    generic = [
        "ggml_assert",
        "fatal error",
        "abort",
        "terminate called",
        "exception",
        "failed to",
        "error:",
        "mmap",
    ]
    lines = str(tail or "").splitlines()

    def last_match(pats):
        for line in reversed(lines):
            low = line.lower()
            if any(p in low for p in pats):
                return line.strip()[:400]
        return ""

    return last_match(oom) or last_match(generic)


def progress(state):
    """Classify the launch phase without relying on the server's HTTP API.

    Returns {phase, percent, target, pid, error}. phase is one of:
      unloaded  — nothing loaded
      crashed   — marked loaded, but the process is gone (with reason from the log)
      downloading — a .downloadInProgress file is growing
      starting  — the process is up and (probably) loading weights
    QML combines this with its own /health probe for the final "serving" state.
    """
    loaded = state.get("loaded")
    if not loaded or not loaded.get("modelId"):
        return {"phase": "unloaded", "pid": None, "target": ""}

    pid = loaded.get("pid")
    model = find_model(state, loaded.get("modelId"))
    alive = is_pid_alive(pid)

    if not alive:
        tail = read_log_tail()
        return {"phase": "crashed", "pid": pid, "target": model and model.get("name") or "",
                "error": extract_error(tail), "log_tail": tail[-1200:]}

    if model:
        dl = find_download(model)
        if dl:
            _temp, target, cur = dl
            target_name = target
            total = expected_bytes(model, target_name)
            percent = round(100 * cur / total) if total and total > 0 else None
            return {"phase": "downloading", "pid": pid, "target": target_name,
                    "bytes": cur, "total": total, "percent": percent}

    return {"phase": "starting", "pid": pid, "target": model and model.get("name") or ""}
    return {"phase": "starting", "pid": pid, "target": model and model.get("name") or ""}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="llamacpp-loader state/process manager")
    sub = ap.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="print the model library as JSON")
    sub.add_parser("status", help="print the whole state file as JSON")

    p_add = sub.add_parser("add", help="upsert a model")
    p_add.add_argument("--json", required=True, dest="model_json", help="model object as JSON")

    p_rm = sub.add_parser("remove", help="remove a model")
    p_rm.add_argument("--model-id", required=True)

    p_build = sub.add_parser("build", help="print the llama-server argv for a model")
    p_build.add_argument("--model-id", required=True)
    p_build.add_argument("--host", default=None)
    p_build.add_argument("--port", default=None)
    p_build.add_argument("--metrics", default="on", choices=["on", "off"])

    p_load = sub.add_parser("load", help="launch a model on a detached llama-server")
    p_load.add_argument("--model-id", required=True)
    p_load.add_argument("--host", default=None)
    p_load.add_argument("--port", default=None)
    p_load.add_argument("--metrics", default="on", choices=["on", "off"])
    p_load.add_argument("--dry-run", action="store_true", help="print argv without launching")

    p_eject = sub.add_parser("eject", help="stop the loaded llama-server")
    p_eject.add_argument("--force", action="store_true")

    p_cfg = sub.add_parser("config", help="read or update the server config block")
    p_cfg.add_argument("--json", default=None, dest="config_json", help="server config as JSON (merge)")

    sub.add_parser("progress", help="report launch phase (unloaded/downloading/starting/crashed)")

    args = ap.parse_args(argv)

    if args.command in ("list", "status"):
        state = load_state()
        if args.command == "list":
            print(json.dumps(state.get("models", []), ensure_ascii=False), flush=True)
        else:
            print(json.dumps(state, ensure_ascii=False), flush=True)
        return

    if args.command == "add":
        state = load_state()
        try:
            model = json.loads(args.model_json)
        except Exception as e:
            print(json.dumps({"ok": False, "error": f"invalid --json: {e}"}), flush=True)
            sys.exit(1)
        add_model(state, model)
        return

    if args.command == "remove":
        state = load_state()
        remove_model(state, args.model_id)
        return

    if args.command == "build":
        state = load_state()
        model = find_model(state, args.model_id)
        if not model:
            print(json.dumps({"ok": False, "error": "model not found"}), flush=True)
            sys.exit(1)
        argv = build_server_args(model, state, host=args.host, port=args.port, metrics=args.metrics == "on")
        print(json.dumps({"ok": True, "argv": argv}, ensure_ascii=False), flush=True)
        return

    if args.command == "load":
        state = load_state()
        model = find_model(state, args.model_id)
        if not model:
            print(json.dumps({"ok": False, "error": "model not found"}), flush=True)
            sys.exit(1)
        argv = build_server_args(model, state, host=args.host, port=args.port, metrics=args.metrics == "on")
        if args.dry_run:
            print(json.dumps({"ok": True, "argv": argv}, ensure_ascii=False), flush=True)
            return
        launch(model, state, host=args.host, port=args.port, metrics=(args.metrics == "on"))
        return

    if args.command == "config":
        state = load_state()
        if args.config_json:
            try:
                updates = json.loads(args.config_json)
            except Exception as e:
                print(json.dumps({"ok": False, "error": f"invalid --json: {e}"}), flush=True)
                sys.exit(1)
            config_server(state, updates)
        else:
            print(json.dumps({"ok": True, "server": state.get("server", {})}, ensure_ascii=False), flush=True)
        return

    if args.command == "progress":
        state = load_state()
        print(json.dumps(progress(state), ensure_ascii=False), flush=True)
        return

    if args.command == "eject":
        state = load_state()
        eject(state, force=args.force)
        return


if __name__ == "__main__":
    main()
