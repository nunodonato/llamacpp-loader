import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// LLaMA.cpp Loader — a bar status icon that drives a local llama-server.
//
// Two visual states: unloaded (dim ○) and loaded (accent ●). Hovering shows a
// tooltip with the loaded model name and context size (plus live usage). Left
// click toggles the model-library panel; middle click forces a re-scan.
//
// State tracking after the shell restarts: llama-server is launched detached,
// so it outlives the shell. On boot we remember the last loaded server from the
// plugin's state file (llama.py status) and reconcile against the server's own
// HTTP API — probe /health + /metrics + /slots on the stored port. The server is
// the source of truth, so the icon reflects reality no matter who crashed.
BarWidget {
  id: root
  moduleName: "llamacpp-loader"

  function pythonBin() {
    return Quickshell.env("PYTHON") || "python3"
  }
  // Resolved inside a function, not as a Process.command initializer: property
  // initializers on the C++ Process type lose the QML source context and would
  // resolve llama.py against the shell's working directory instead of the plugin.
  function llamaScript() {
    return String(Qt.resolvedUrl("llama.py")).replace(/^file:\/\//, "")
  }
  function stateServer(state) {
    return (state && state.server) || {}
  }

  // ---- Config (read from this widget's inline shell.json entry, but host/port
  //      are authoritative from the plugin's server config block when present). ----
  property var serverState: ({})
  readonly property string host: root.serverState.host !== undefined ? String(root.serverState.host) : String(setting("host", "127.0.0.1"))
  readonly property int port: Model.clamp(root.serverState.port !== undefined ? root.serverState.port : setting("port", 8080), 1, 65535, 8080)
  readonly property bool metrics: setting("metrics", true)
  readonly property int pollInterval: Model.clamp(setting("pollInterval", 3), 1, 60, 3)
  readonly property string baseUrl: "http://" + root.host + ":" + root.port

  // ---- State. models + loaded come from llama.py status; live is polled. ----
  property var models: []
  property var loaded: null            // { modelId, pid, port, startedAt }
  property var loadedModel: null       // the model library object for loaded.modelId

  // Launch phase: unloaded | downloading | starting | serving | crashed.
  property string phase: "unloaded"
  property int downloadPercent: -1     // -1 = unknown
  property string downloadTarget: ""
  property string crashError: ""
  property bool crashNotified: false

  // Live usage, refreshed on a timer while a server is up.
  property bool alive: false
  property bool liveServing: false
  property int promptTokens: 0
  property int predictedTokens: 0
  property int requestCount: 0
  property int activeSlots: 0
  property int totalSlots: 0
  property real rate: 0

  // Rate window: delta of predicted tokens over the last interval.
  property int lastPredicted: 0
  property var lastRateMs: 0

  readonly property bool hasLoaded: root.loaded !== null && root.loaded.modelId !== ""
  readonly property bool downloading: root.phase === "downloading"
  readonly property bool starting: root.phase === "starting"

  // State color: green when serving, orange when loading/downloading, red on crash.
  readonly property color stateColor: {
    if (root.alive) return "#23A55A"
    if (root.downloading || root.starting) return "#F0A438"
    if (root.phase === "crashed") return Color.urgent
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // ---- Bar icon. Unloaded ○ · downloading ↓ · starting ◌ · serving ● · crashed ⚠. ----
  readonly property string iconText: {
    if (!root.hasLoaded) return "○"
    if (root.alive) return "●"
    if (root.downloading) return "↓"
    if (root.starting) return "◌"
    if (root.phase === "crashed") return "\u26A0"
    return "○"
  }
  readonly property string tooltipText: {
    if (!root.hasLoaded)
      return "LLaMA.cpp Loader — no model loaded"
    if (root.alive)
      return Model.statusTooltip(root.loadedModel, { active: root.activeSlots }) +
        " · " + Model.humanTokens(root.predictedTokens + root.promptTokens) + " tok"
    if (root.downloading)
      return "LLaMA.cpp Loader — downloading " + (root.downloadTarget || root.loadedModel ? Model.suggestName(root.loadedModel) : "") +
        (root.downloadPercent >= 0 ? " · " + root.downloadPercent + "%" : "")
    if (root.starting)
      return "LLaMA.cpp Loader — starting " + Model.suggestName(root.loadedModel) + "…"
    if (root.phase === "crashed")
      return "LLaMA.cpp Loader — " + Model.suggestName(root.loadedModel) + " failed to start" +
        (root.crashError !== "" ? "\n" + root.crashError : "")
    return "LLaMA.cpp Loader — " + Model.suggestName(root.loadedModel) + " appears to have exited (see log)"
  }

  // Send a one-shot desktop notification when a load fails (OOM etc.).
  function notifyCrash(modelName, error) {
    if (root.crashNotified) return
    root.crashNotified = true
    var desc = (modelName || "Model") + " failed to load" + (error !== "" ? "\n" + error : "")
    notifyProc.command = ["omarchy-notification-send", "-u", "critical",
      "LLaMA.cpp Loader", desc]
    notifyProc.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    keepSpace: true
    interactive: true
    text: root.iconText
    active: root.hasLoaded
    useActiveColor: true
    activeColor: root.stateColor
    dimmed: !root.hasLoaded
    tooltipText: root.tooltipText
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fontSize: Style.font.body

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }

  // ---- Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  //      requires open/close/opened on the bar-widget root). ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  IpcHandler {
    target: "llamacpp-loader"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- Public: re-read the state file and reconcile with the live server. ----
  function refresh() {
    statusProc.command = [pythonBin(), llamaScript(), "status"]
    statusProc.running = true
  }

  // ---- Reconcile: after state is read, derive serverConfig + loadedModel + probe. ----
  function reconcile() {
    root.serverState = stateServer(root.statusState)
    var marker = root.loaded
    var lib = null
    if (marker && marker.modelId) {
      for (var i = 0; i < root.models.length; i++) {
        if (String(root.models[i].id) === String(marker.modelId)) { lib = root.models[i]; break }
      }
    }
    root.loadedModel = lib
    if (root.hasLoaded) {
      root.phase = "starting"
      root.probeLive()
      root.probeProgress()
    } else {
      root.alive = false
      root.liveServing = false
      root.phase = "unloaded"
      root.downloadPercent = -1
      root.downloadTarget = ""
      root.activeSlots = 0
      root.totalSlots = 0
      root.promptTokens = 0
      root.predictedTokens = 0
      root.rate = 0
    }
  }

  // ---- Poll the server's live endpoints + launch phase. ----
  function probeLive() {
    healthProc.running = true
  }
  function probeProgress() {
    progressProc.command = [pythonBin(), llamaScript(), "progress"]
    progressProc.running = true
  }

  // Rate computation on each metrics refresh (delta of predicted tokens).
  function recordRate() {
    var now = Date.now()
    if (root.lastRateMs > 0) {
      var dtSec = (now - root.lastRateMs) / 1000
      var dTok = root.predictedTokens - root.lastPredicted
      if (dtSec > 0 && dTok >= 0 && root.liveServing) root.rate = Model.tokensPerSecond(dTok, dtSec)
    }
    root.lastRateMs = now
    root.lastPredicted = root.predictedTokens
  }

  Timer {
    id: pollTimer
    interval: root.pollInterval * 1000
    repeat: true
    running: root.hasLoaded
    onTriggered: {
      root.probeLive()
      if (!root.alive) root.probeProgress()
    }
  }

  // ---- Status read (llama.py status) — gives models, server config, loaded. ----
  property var statusState: ({})
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var state = JSON.parse(raw)
          root.statusState = state
          root.models = Model.asList(state.models)
          root.loaded = state.loaded
          root.reconcile()
        } catch (e) {
          console.warn("llamacpp-loader: could not parse status: " + e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg) console.warn("llamacpp-loader: " + msg)
      }
    }
  }

  // ---- Live probe: health. Then metrics + slots when the daemon answers. ----
  Process {
    id: healthProc
    command: ["curl", "-fsS", "--max-time", "3", root.baseUrl + "/health"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        var ok = raw.indexOf("ok") !== -1 || raw.indexOf("status") !== -1
        root.alive = ok
        if (ok) {
          root.phase = "serving"
        } else if (root.phase === "serving") {
          root.phase = "starting"
        }
        if (ok && root.metrics) metricsProc.running = true
        if (ok && root.metrics) slotsProc.running = true
        if (!ok) {
          root.liveServing = false
          root.activeSlots = 0
        }
      }
    }
  }

  // ---- Launch phase (llama.py progress): downloading / starting / crashed. ----
  //      Ignored once the daemon is serving — health wins.
  Process {
    id: progressProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw || root.alive) return
        try {
          var p = JSON.parse(raw)
          if (p.phase === "downloading") {
            root.downloadTarget = p.target || root.downloadTarget
            root.downloadPercent = (p.percent !== undefined && p.percent !== null && p.percent >= 0) ? Math.round(p.percent) : -1
            root.phase = "downloading"
          } else if (p.phase === "starting") {
            root.downloadPercent = -1
            root.phase = "starting"
          } else if (p.phase === "crashed") {
            root.downloadPercent = -1
            root.phase = "crashed"
            root.crashError = p.error || ""
            root.notifyCrash(Model.suggestName(root.loadedModel), root.crashError)
          } else {
            root.phase = "unloaded"
            root.crashNotified = false
            root.crashError = ""
          }
        } catch (e) {
          console.warn("llamacpp-loader: could not parse progress: " + e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg) console.warn("llamacpp-loader: " + msg)
      }
    }
  }

  Process {
    id: notifyProc
    command: []
  }

  Process {
    id: metricsProc
    command: ["curl", "-fsS", "--max-time", "3", root.baseUrl + "/metrics"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var met = Model.parseMetrics(String(text || ""))
        if (met.available) {
          root.promptTokens = met.promptTokens
          root.predictedTokens = met.predictedTokens
          root.requestCount = met.requestCount
          root.liveServing = true
          root.recordRate()
        } else {
          root.liveServing = false
        }
      }
    }
  }

  Process {
    id: slotsProc
    command: ["curl", "-fsS", "--max-time", "3", root.baseUrl + "/slots"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var slots = Model.parseSlots(String(text || ""))
        root.activeSlots = slots.active
        root.totalSlots = slots.total
      }
    }
  }

  // ---- Boot. Read the saved state, then reconcile with the live server. ----
  Component.onCompleted: {
    root.refresh()
  }
}
