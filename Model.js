// Model.js — pure helpers for the llamacpp-loader plugin. No Qt, no file I/O, so it
// unit-tests under node like ics.agenda's Model.js. The QML owns display and the
// panel owns mutation; this file handles parsing, clamping, and formatting.

// ---- Lists: QML arrays arrive as array-likes, not JSArray. Duck-type. ----
function asList(value) {
  if (!value) return []
  if (Array.isArray(value)) return value
  if (typeof value.length === "number" && isFinite(value.length)) return value
  return []
}

// ---- Numeric helpers. Values from shell.json / state occasionally land as
//      strings; coerce and clamp before they reach anything that does math. ----
function toInt(value) {
  var n = Math.round(Number(value))
  return isFinite(n) ? n : NaN
}

function clamp(value, min, max, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = toInt(value)
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function clampCtx(value) {
  return clamp(value, 256, 262144, 8192)
}

// "99" means offload-all in llama.cpp; exposing it as the default cap keeps the
// number meaningful while still being an exact layer count when tuned.
function clampLayers(value) {
  return clamp(value, 0, 999, 99)
}

// MoE expert weights kept on the CPU (0 = none). Mirrors --n-cpu-moe.
function clampMoe(value) {
  return clamp(value, 0, 999, 0)
}

// ---- Parsing a pasted Hugging Face reference into {hfRepo, hfFile, quant}.
//      Accepts:
//        owner/repo
//        owner/repo:QUANT
//        https://huggingface.co/owner/repo
//        https://huggingface.co/owner/repo/blob/main/<file>.gguf
//        https://huggingface.co/owner/repo/resolve/main/<file>.gguf
function parseHfRef(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  var out = { hfRepo: "", hfFile: "", quant: "" }
  if (text === "") return out

  // Strip query/fragment and trailing slashes, then known URL prefixes.
  text = text.replace(/[?#].*$/, "").replace(/\/+$/, "")
  text = text.replace(/^(?:hf:\/\/|https?:\/\/(?:www\.)?huggingface\.co\/|(?:www\.)?huggingface\.co\/)/i, "")

  // Isolate a possible :QUANT suffix on a bare owner/repo:QUANT shape (not on a
  // filename path, which ends in .gguf and has no colon in the repo id).
  var parts = text.split("/").filter(function(p) { return p !== "" })
  var quant = ""
  var repoPart = text
  if (!/\.[a-z0-9]+$/i.test(repoPart) && parts.length <= 2) {
    var last = parts.length ? parts[parts.length - 1] : ""
    var colon = last.indexOf(":")
    if (colon !== -1) {
      quant = last.slice(colon + 1)
      repoPart = text.slice(0, text.length - (last.length - colon))
    }
  }

  // A full HF URL contains a blob/resolve segment: the file is the final path
  // segment and the repo is everything before that segment (the revision, e.g.
  // "main", sits between them and is discarded).
  var file = ""
  var normalizedParts = repoPart.split("/").filter(function(p) { return p !== "" })
  var blobIndex = -1
  for (var i = 0; i < normalizedParts.length; i++) {
    if (normalizedParts[i] === "blob" || normalizedParts[i] === "resolve") {
      blobIndex = i
      break
    }
  }
  if (blobIndex !== -1 && normalizedParts.length > blobIndex + 1) {
    file = normalizedParts[normalizedParts.length - 1]
    normalizedParts = normalizedParts.slice(0, blobIndex)
  }

  out.hfRepo = normalizedParts.join("/")
  out.hfFile = file
  out.quant = quant
  return out
}

// ---- Build a friendly model name from stored fields when no name is given.
function suggestName(lib) {
  if (lib && lib.name && String(lib.name).trim() !== "") return String(lib.name).trim()
  if (lib && lib.hfRepo) return String(lib.hfRepo).split("/").pop() || String(lib.hfRepo)
  return "Unnamed model"
}

// ---- Usage/metrics parsing. llama-server exposes Prometheus-style text at
//      /metrics when launched with --metrics; /slots returns per-slot JSON.
function parseMetrics(text) {
  var result = {
    promptTokens: 0,
    predictedTokens: 0,
    requestCount: 0,
    available: false
  }
  var raw = String(text || "")
  if (!raw.match(/llamacpp:/)) return result
  result.available = true

  var lines = raw.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line || line.charAt(0) === "#") continue
    var m = line.match(/^llamacpp:([a-z_]+)\s+(?:{.*?}\s+)?(-?[\d.eE+]+)\s*$/)
    if (!m) continue
    var name = m[1]
    var value = parseFloat(m[2])
    if (isNaN(value)) continue
    if (name === "prompt_tokens_total") result.promptTokens = value
    else if (name === "tokens_predicted_total") result.predictedTokens = value
    else if (name === "request_count_total") result.requestCount = value
  }
  return result
}

// Tolerant parser for the /slots JSON: returns { active, total, predicted }.
// The payload may be an array of slots or { slots: [...] }; each slot may carry
// n_past (tokens in context) and n_predicted (generated so far).
function parseSlots(jsonText) {
  var result = { active: 0, total: 0, predicted: 0 }
  var data = null
  try {
    data = JSON.parse(String(jsonText || "[]"))
  } catch (e) {
    return result
  }
  var slots = null
  if (Array.isArray(data)) slots = data
  else if (data && Array.isArray(data.slots)) slots = data.slots
  if (!slots) return result

  result.total = slots.length
  for (var i = 0; i < slots.length; i++) {
    var s = slots[i]
    if (!s || typeof s !== "object") continue
    var nPast = Number(s.n_past !== undefined ? s.n_past : s.tokens_predict_done || 0)
    var predicted = Number(s.n_predicted !== undefined ? s.n_predicted : s.tokens_predicted || 0)
    if (isFinite(nPast) && nPast > 0) result.active++
    if (isFinite(predicted)) result.predicted += predicted
  }
  return result
}

// ---- Formatting for status / tooltip text. ----
function humanCtx(value) {
  var ctx = clampCtx(value)
  return (ctx >= 1024) ? (Math.round(ctx / 102.4) / 10) + "k" : String(ctx)
}

function humanTokens(value) {
  var n = Number(value)
  if (!isFinite(n)) return "0"
  if (n >= 1000000) return (Math.round(n / 10000) / 100) + "M"
  if (n >= 1000) return (Math.round(n / 100) / 10) + "k"
  return String(Math.round(n))
}

function tokensPerSecond(deltaTokens, deltaSeconds) {
  if (!isFinite(deltaSeconds) || deltaSeconds <= 0) return 0
  return (deltaTokens || 0) / deltaSeconds
}

function formatRate(rate) {
  var r = Number(rate)
  if (!isFinite(r) || r < 0) return "—"
  if (r >= 100) return Math.round(r) + " t/s"
  if (r >= 10) return Math.round(r * 10) / 10 + " t/s"
  return Math.round(r * 100) / 100 + " t/s"
}

// Build the hovering tooltip for the bar icon.
function statusTooltip(lib, live) {
  if (!lib) return "LLaMA.cpp Loader — no server loaded"
  var name = suggestName(lib)
  var ctx = humanCtx(lib.ctxSize)
  var text = "LLaMA.cpp Loader\n" + name + "\nctx " + ctx
  if (live && live.active) text += "\n" + live.active + " active slot" + (live.active === 1 ? "" : "s")
  return text
}

if (typeof module !== "undefined") {
  module.exports = {
    asList: asList,
    clamp: clamp,
    toInt: toInt,
    clampCtx: clampCtx,
    clampLayers: clampLayers,
    clampMoe: clampMoe,
    parseHfRef: parseHfRef,
    suggestName: suggestName,
    parseMetrics: parseMetrics,
    parseSlots: parseSlots,
    humanCtx: humanCtx,
    humanTokens: humanTokens,
    tokensPerSecond: tokensPerSecond,
    formatRate: formatRate,
    statusTooltip: statusTooltip
  }
}
