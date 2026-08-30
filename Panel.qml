import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The model-library panel. Reads live state from the host BarWidget (which owns
// the polling and the llama-server reconciliation); mutates through the
// llama.py sidecar. Shows the loaded server's basic usage, the list of saved
// models (load / eject / edit), and an "add model" affordance where the user
// pastes a Hugging Face GGUF reference exactly as they would to llama-server.
Panel {
  id: root
  moduleName: "llamacpp-loader"
  ipcTarget: "llamacpp-loader"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Live state mirrored from the bar widget.
  readonly property var models: root.hostWidget ? Model.asList(root.hostWidget.models) : []
  readonly property var loaded: root.hostWidget ? root.hostWidget.loaded : null
  readonly property var loadedModel: root.hostWidget ? root.hostWidget.loadedModel : null
  readonly property bool alive: root.hostWidget ? root.hostWidget.alive : false
  readonly property string phase: root.hostWidget ? root.hostWidget.phase : "unloaded"
  readonly property int downloadPercent: root.hostWidget ? root.hostWidget.downloadPercent : -1
  readonly property int promptTokens: root.hostWidget ? root.hostWidget.promptTokens : 0
  readonly property int predictedTokens: root.hostWidget ? root.hostWidget.predictedTokens : 0
  readonly property real rate: root.hostWidget ? root.hostWidget.rate : 0
  readonly property int activeSlots: root.hostWidget ? root.hostWidget.activeSlots : 0

  readonly property bool loadedIsSaved: root.loaded && root.loadedModel !== null
  readonly property string host: root.hostWidget ? root.hostWidget.host : "127.0.0.1"
  readonly property int port: root.hostWidget ? root.hostWidget.port : 8080
  readonly property bool downloading: root.phase === "downloading"
  readonly property bool starting: root.phase === "starting"
  readonly property bool crashed: root.phase === "crashed"
  readonly property string crashError: root.hostWidget ? root.hostWidget.crashError : ""

  // State color — matches the bar icon: green serving, orange loading/downloading.
  readonly property color stateColor: {
    if (root.alive) return "#23A55A"
    if (root.downloading || root.starting) return "#F0A438"
    if (root.phase === "crashed") return Color.urgent
    return Qt.darker(root.bar.foreground, 1.5)
  }

  // ---- local UI state ----
  property bool adding: false
  property string addName: ""
  property string addRef: ""
  property string addCtx: ""
  property string addLayers: ""
  property string addMoe: ""
  property string editModelId: ""
  property var edit: ({})
  property string lastActionError: ""
  property bool mutating: false
  property string pendingLoadId: ""

  // ---- server config editor ----
  property bool editingServer: false
  property string serverHost: ""
  property string serverPort: ""
  property string serverExtraArgs: ""

  // A model is loadable when nothing is loaded, or already IS the loaded one.
  function isLoaded(id) { return root.loaded && String(root.loaded.modelId) === String(id) }
  function canLoad(id) { return !root.loaded }

  function open() {
    root.refreshFromHost()
    root.controller.show()
  }
  function close() {
    root.controller.hide()
  }
  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }
  function refreshFromHost() {
    if (root.hostWidget && root.hostWidget.refresh) root.hostWidget.refresh()
  }

  function pythonBin() {
    return Quickshell.env("PYTHON") || "python3"
  }
  function llamaScript() {
    return String(Qt.resolvedUrl("llama.py")).replace(/^file:\/\//, "")
  }

  // ---- Generic mutation runner. Parses llama.py output; on success re-reads
  //      the state so the panel + bar icon agree with reality. ----
  property string actionResult: ""
  function runAction(args) {
    root.mutating = true
    root.lastActionError = ""
    root.actionResult = ""
    actionProc.command = args
    actionProc.running = true
  }
  function finishAction(code) {
    root.mutating = false
    try {
      var o = JSON.parse(String(root.actionResult || "{}"))
      if (code !== 0 || o.ok === false) {
        root.lastActionError = o.error || "action failed"
        return
      }
      root.lastActionError = ""
      if (root.pendingLoadId !== "") {
        // A "load another model" ran eject first; load the pending one now.
        var id = root.pendingLoadId
        root.pendingLoadId = ""
        root.runAction([pythonBin(), llamaScript(), "load", "--model-id", id,
                        "--host", root.host, "--port", String(root.port),
                        "--metrics", root.hostWidget && root.hostWidget.metrics ? "on" : "off"])
        return
      }
      root.refreshFromHost()
    } catch (e) {
      root.lastActionError = "unexpected output"
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.actionResult = String(text || "") }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim()
        if (m) console.warn("llamacpp-loader: " + m)
      }
    }
    onExited: function(code) { root.finishAction(code) }
  }

  // ---- Actions ----
  function loadModel(id) {
    if (root.mutating) return
    if (root.loaded && !isLoaded(id)) {
      // Another model is loaded. Eject first, then load this one.
      root.pendingLoadId = id
      runAction([pythonBin(), llamaScript(), "eject"])
      return
    }
    root.pendingLoadId = ""
    runAction([pythonBin(), llamaScript(), "load", "--model-id", id,
               "--host", root.host, "--port", String(root.port),
               "--metrics", root.hostWidget && root.hostWidget.metrics ? "on" : "off"])
  }

  function ejectModel() {
    if (root.mutating) return
    runAction([pythonBin(), llamaScript(), "eject"])
  }

  function removeModel(id) {
    if (root.mutating) return
    runAction([pythonBin(), llamaScript(), "remove", "--model-id", id])
  }

  function startAdd() {
    root.adding = true
    root.addName = ""
    root.addRef = ""
    // Default to sensible tunables; these persist on the model and are re-used
    // on every subsequent load until the user edits them again.
    root.addCtx = "8192"
    root.addLayers = "99"
    root.addMoe = "0"
    root.lastActionError = ""
    Qt.callLater(function() { addRefField.forceActiveFocus() })
  }
  function cancelAdd() {
    root.adding = false
    root.lastActionError = ""
  }
  function commitAdd() {
    var lib = Model.parseHfRef(root.addRef)
    if (lib.hfRepo === "") {
      root.lastActionError = "paste a Hugging Face repo reference"
      return
    }
    var model = lib
    model.id = root.addName.trim() !== "" ? root.addName.trim() : Model.suggestName(lib)
    model.name = root.addName.trim() !== "" ? root.addName.trim() : Model.suggestName(lib)
    model.ctxSize = Model.clampCtx(Model.toInt(root.addCtx) || 8192)
    model.nGpuLayers = Model.clampLayers(Model.toInt(root.addLayers) || 99)
    model.nCpuMoe = Model.clampMoe(Model.toInt(root.addMoe) || 0)
    model.extraArgs = []
    runAction([pythonBin(), llamaScript(), "add", "--json", JSON.stringify(model)])
    root.adding = false
  }

  // ---- Server config (host / port / extraArgs) — the same free-form args the
  //      user would pass to llama-server, stored in the state file. ----
  function startEditServer() {
    var s = root.hostWidget ? root.hostWidget.serverState : ({})
    root.serverHost = s.host !== undefined ? s.host : "127.0.0.1"
    root.serverPort = String(s.port !== undefined ? s.port : 8080)
    root.serverExtraArgs = Model.asList(s.extraArgs).join(" ")
    root.editingServer = true
    root.lastActionError = ""
  }
  function cancelEditServer() { root.editingServer = false }
  function commitEditServer() {
    var extra = root.serverExtraArgs.trim()
    var cfg = { extraArgs: extra }
    if (root.serverHost.trim() !== "") cfg.host = root.serverHost.trim()
    if (root.serverPort.trim() !== "") cfg.port = Model.toInt(root.serverPort) || 8080
    runAction([pythonBin(), llamaScript(), "config", "--json", JSON.stringify(cfg)])
    root.editingServer = false
  }

  function startEdit(id) {
    var m = null
    for (var i = 0; i < root.models.length; i++)
      if (String(root.models[i].id) === String(id)) { m = root.models[i]; break }
    if (!m) return
    root.editModelId = id
    root.edit = {
      name: m.name || "",
      hfRepo: m.hfRepo || "",
      hfFile: m.hfFile || "",
      quant: m.quant || "",
      ctxSize: String(Model.clampCtx(m.ctxSize)),
      nGpuLayers: String(Model.clampLayers(m.nGpuLayers)),
      nCpuMoe: String(Model.clampMoe(m.nCpuMoe)),
      cpuMoe: m.cpuMoe === true,
      extraArgs: Model.asList(m.extraArgs).join(" ")
    }
  }
  function cancelEdit() { root.editModelId = "" }
  function commitEdit() {
    var id = root.editModelId
    var repo = Model.parseHfRef(String(root.edit.hfRepo || "")).hfRepo
    if (repo === "") { root.lastActionError = "repo is required"; return }
    var model = {
      id: id,
      name: String(root.edit.name || "").trim(),
      hfRepo: repo,
      hfFile: String(root.edit.hfFile || "").trim(),
      quant: String(root.edit.quant || "").trim(),
      ctxSize: Model.clampCtx(root.edit.ctxSize),
      nGpuLayers: Model.clampLayers(root.edit.nGpuLayers),
      nCpuMoe: root.edit.cpuMoe ? 0 : Model.clampMoe(root.edit.nCpuMoe),
      cpuMoe: root.edit.cpuMoe === true,
      extraArgs: String(root.edit.extraArgs || "").trim()
    }
    runAction([pythonBin(), llamaScript(), "add", "--json", JSON.stringify(model)])
    root.editModelId = ""
  }

  function modelCtx(m) { return Model.humanCtx(m.ctxSize) }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: Style.space(460)
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.adding || root.editModelId !== ""
      onCloseRequested: root.editModelId !== "" ? root.cancelEdit() : (root.adding ? root.cancelAdd() : root.close())

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(14)

          // ---- Status header: loaded model + basic usage. ----
          Rectangle {
            width: parent.width
            height: statusRow.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: root.alive ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Row {
              id: statusRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                text: root.alive ? "●" : (root.downloading ? "⤓" : (root.starting ? "◌" : "○"))
                color: root.stateColor
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: root.loadedIsSaved
                    ? Model.suggestName(root.loadedModel)
                    : (root.loaded ? (root.alive ? "Loading model…" : "Starting…") : "No model loaded")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: root.loadedIsSaved
                    ? (root.alive
                        ? "● " + Model.humanTokens(root.promptTokens + root.predictedTokens) + " tok · "
                          + Model.formatRate(root.rate) + " · " + root.activeSlots + " slot" + (root.activeSlots === 1 ? "" : "s") + " · ctx " + Model.humanCtx(root.loadedModel.ctxSize) + " · " + root.host + ":" + root.port
                        : (root.crashed
                            ? "\u26A0 failed to start" + (root.crashError !== "" ? " — " + root.crashError : "")
                            : (root.downloading
                                ? "⤓ downloading " + (root.downloadPercent >= 0 ? root.downloadPercent + "%" : "…") + " · " + root.host + ":" + root.port
                                : "starting — " + root.host + ":" + root.port)))
                    : (root.host && root.port ? "click a model below to load it" : "click a model below to load it")
                  color: root.crashed ? Color.urgent : Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

            }
          }

          // ---- Add model + list. ----
          Row {
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              width: addChip.implicitWidth + Style.space(20)
              height: addChip.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.bar.foreground, Color.accent)

              Text {
                id: addChip
                anchors.centerIn: parent
                text: "＋ ADD MODEL"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startAdd()
              }
            }

            // Server settings: host / port / free-form llama-server args.
            // Disabled while a model is loaded/loading (its config is in use).
            Rectangle {
              visible: !root.adding
              width: serverChip.implicitWidth + Style.space(20)
              height: serverChip.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: "transparent"
              border.color: Qt.darker(root.bar.foreground, 1.5)
              border.width: 1
              opacity: root.loaded ? 0.5 : 1

              Text {
                id: serverChip
                anchors.centerIn: parent
                text: "⚙ SERVER"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: !root.loaded
                cursorShape: root.loaded ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: if (!root.loaded) root.editingServer ? root.cancelEditServer() : root.startEditServer()
              }
            }

            // Open the llama-server web UI. Enabled only while a model is serving.
            Rectangle {
              visible: !root.adding
              width: webChip.implicitWidth + Style.space(20)
              height: webChip.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
            color: root.alive ? Style.hoverFillFor(root.bar.foreground, root.stateColor) : "transparent"
              border.color: root.alive ? "transparent" : Qt.darker(root.bar.foreground, 1.5)
              border.width: 1
              opacity: root.alive ? 1 : 0.5

              Text {
                id: webChip
                anchors.centerIn: parent
                text: "◉ WEBUI"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.alive ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (root.alive) { Qt.openUrlExternally("http://" + root.host + ":" + root.port); root.close() }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.models.length === 0 && !root.adding && !root.editingServer
              text: "No models saved yet."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Add form (paste HF reference). ----
          Column {
            visible: root.adding
            width: parent.width
            spacing: Style.space(8)
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.cancelAdd(); event.accepted = true }
            }

            TextField {
              id: addNameField
              width: parent.width
              placeholderText: "Name (e.g. Qwen 2.5 7B)"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onTextChanged: root.addName = text
            }
            TextField {
              id: addRefField
              width: parent.width
              placeholderText: "HF reference — owner/repo[:quant] or a gguf URL"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onTextChanged: root.addRef = text
              onAccepted: root.commitAdd()
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Column {
                width: Style.space(140)
                spacing: Style.space(3)
                Text { text: "CTX"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                TextField { width: parent.width; placeholderText: "8192"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.addCtx; onTextChanged: root.addCtx = text }
              }
              Column {
                width: Style.space(140)
                spacing: Style.space(3)
                Text { text: "GPU LAYERS"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                TextField { width: parent.width; placeholderText: "99"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.addLayers; onTextChanged: root.addLayers = text }
              }
              Column {
                width: Style.space(140)
                spacing: Style.space(3)
                Text { text: "MOE CPU"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                TextField { width: parent.width; placeholderText: "0"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.addMoe; onTextChanged: root.addMoe = text }
              }
            }
            Text {
              width: parent.width
              visible: root.addName === ""
              wrapMode: Text.WordWrap
              text: "Blank name uses the repo name. ctx/gpu/moe are saved per model and re-used on load (edit them later in Edit)."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.space(10)
              Rectangle {
                width: addOk.implicitWidth + Style.space(16)
                height: addOk.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.bar.foreground, Color.accent)
                Text { id: addOk; anchors.centerIn: parent; text: "ADD"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.commitAdd() }
              }
              Rectangle {
                width: addCancel.implicitWidth + Style.space(16)
                height: addCancel.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: "transparent"
                border.color: Qt.darker(root.bar.foreground, 1.5)
                border.width: 1
                Text { id: addCancel; anchors.centerIn: parent; text: "CANCEL"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelAdd() }
              }
            }
          }

          // ---- Server settings editor (host / port / free-form args). ----
          Column {
            visible: root.editingServer
            width: parent.width
            spacing: Style.space(8)
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.cancelEditServer(); event.accepted = true }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Server the plugin launches and probes. Extra args are passed through to llama-server (e.g. --no-mmap, --load-mode none). Per-model extra args live in each model's Edit."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField { width: Style.space(140); placeholderText: "host"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.serverHost; onTextChanged: root.serverHost = text }
              TextField { width: Style.space(140); placeholderText: "port"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.serverPort; onTextChanged: root.serverPort = text }
            }
            TextField {
              width: parent.width
              placeholderText: "extra llama-server args (e.g. --no-mmap --parallel 2)"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              text: root.serverExtraArgs
              onTextChanged: root.serverExtraArgs = text
            }

            Row {
              spacing: Style.space(10)
              Rectangle {
                width: srvOk.implicitWidth + Style.space(16); height: srvOk.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.bar.foreground, Color.accent)
                Text { id: srvOk; anchors.centerIn: parent; text: "SAVE"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.commitEditServer() }
              }
              Rectangle {
                width: srvCancel.implicitWidth + Style.space(16); height: srvCancel.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: "transparent"
                border.color: Qt.darker(root.bar.foreground, 1.5)
                border.width: 1
                Text { id: srvCancel; anchors.centerIn: parent; text: "CANCEL"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelEditServer() }
              }
            }
          }

          // ---- Model list. ----
          Column {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.models
              delegate: modelRowComponent
            }
          }

          // ---- Error / message line. ----
          Text {
            width: parent.width
            visible: root.lastActionError !== ""
            wrapMode: Text.WordWrap
            text: root.lastActionError
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.mutating
            wrapMode: Text.WordWrap
            text: "Working…"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
          }
        }
      }
    }
  }

  // ---- A single saved model's row (or its editor). ----
  Component {
    id: modelRowComponent
    Item {
      required property var modelData
      width: parent.width
      height: Math.max(base.height, edit.implicitHeight)

      // Collapsed row.
      Rectangle {
        id: base
        visible: String(root.editModelId) !== String(modelData.id)
        width: parent.width
        height: inner.height + Style.space(12)
        radius: Style.cornerRadius
        color: root.isLoaded(modelData.id) ? Style.hoverFillFor(root.bar.foreground, root.stateColor) : "transparent"

        Item {
          id: inner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          height: Math.max(nameCol.implicitHeight, actionsRow.implicitHeight)

          Column {
            id: nameCol
            anchors.left: parent.left
            anchors.right: actionsRow.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              width: parent.width
              text: Model.suggestName(modelData)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: root.isLoaded(modelData.id)
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: modelData.hfRepo + (modelData.quant ? ":" + modelData.quant : "") + (modelData.hfFile ? " · " + modelData.hfFile : "")
                + "\nctx " + root.modelCtx(modelData) + " · gpu " + Model.clampLayers(modelData.nGpuLayers) + "L"
                + (Model.clampMoe(modelData.nCpuMoe) > 0 || modelData.cpuMoe ? " · moe-cpu " + (modelData.cpuMoe ? "all" : String(Model.clampMoe(modelData.nCpuMoe))) : "")
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Action chips (right-anchored so they can never overflow the card).
          Row {
            id: actionsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // Load (or Eject when loaded).
            Rectangle {
              visible: root.isLoaded(modelData.id) || root.canLoad(modelData.id)
              width: actLoad.implicitWidth + Style.space(16)
              height: actLoad.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: root.isLoaded(modelData.id) ? Style.hoverFillFor(root.bar.foreground, root.stateColor) : Style.hoverFillFor(root.bar.foreground, Color.accent)

              Text {
                id: actLoad
                anchors.centerIn: parent
                text: root.isLoaded(modelData.id) ? "\u23CF EJECT" : "\u25B6 LOAD"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.isLoaded(modelData.id) ? root.ejectModel() : root.loadModel(modelData.id)
              }
            }

            // Edit (disabled while loaded/loading so a running server's params
            // are never edited underneath it).
            Rectangle {
              visible: !root.isLoaded(modelData.id)
              width: actEdit.implicitWidth + Style.space(16)
              height: actEdit.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: "transparent"
              border.color: Qt.darker(root.bar.foreground, 1.5)
              border.width: 1
              Text {
                id: actEdit
                anchors.centerIn: parent
                text: "EDIT"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startEdit(modelData.id)
              }
            }

            // Delete (hidden while loaded/loading — a running model can't be removed).
            Rectangle {
              visible: !root.isLoaded(modelData.id)
              width: actDel.implicitWidth + Style.space(16)
              height: actDel.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: "transparent"
              border.color: Qt.darker(root.bar.foreground, 1.5)
              border.width: 1
              Text {
                id: actDel
                anchors.centerIn: parent
                text: "\u2715"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeModel(modelData.id)
              }
            }
          }
        }
      }

      // Expanded editor.
      Column {
        id: edit
        visible: String(root.editModelId) === String(modelData.id)
        width: parent.width
        spacing: Style.space(8)
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.cancelEdit(); event.accepted = true }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          TextField { width: parent.width; placeholderText: "Name"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.name !== undefined ? root.edit.name : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.name = text }
          TextField { width: parent.width; placeholderText: "owner/repo"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.hfRepo !== undefined ? root.edit.hfRepo : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.hfRepo = text }
          TextField { width: parent.width; placeholderText: "hfFile (optional) — file.gguf"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.hfFile !== undefined ? root.edit.hfFile : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.hfFile = text }
          TextField { width: parent.width; placeholderText: "quant (optional, e.g. Q4_K_M)"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.quant !== undefined ? root.edit.quant : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.quant = text }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Column {
              width: Style.space(140)
              spacing: Style.space(3)
              Text { text: "CTX"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              TextField { width: parent.width; placeholderText: "8192"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.ctxSize !== undefined ? root.edit.ctxSize : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.ctxSize = text }
            }
            Column {
              width: Style.space(140)
              spacing: Style.space(3)
              Text { text: "GPU LAYERS"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              TextField { width: parent.width; placeholderText: "99"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.nGpuLayers !== undefined ? root.edit.nGpuLayers : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.nGpuLayers = text }
            }
            Column {
              width: Style.space(140)
              spacing: Style.space(3)
              Text { text: "MOE CPU"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              TextField { width: parent.width; placeholderText: "0"; foreground: root.bar.foreground; font.family: root.bar.fontFamily; text: root.edit.nCpuMoe !== undefined ? root.edit.nCpuMoe : ""; onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.nCpuMoe = text }
            }
          }

          TextField {
            width: parent.width
            placeholderText: "extra llama-server args for this model (e.g. --parallel 2)"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            text: root.edit.extraArgs !== undefined ? root.edit.extraArgs : ""
            onTextChanged: if (String(root.editModelId) === String(modelData.id)) root.edit.extraArgs = text
          }
        }

        Row {
          spacing: Style.space(10)
          Rectangle {
            width: editSave.implicitWidth + Style.space(16); height: editSave.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.bar.foreground, Color.accent)
            Text { id: editSave; anchors.centerIn: parent; text: "SAVE"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.commitEdit() }
          }
          Rectangle {
            width: editCancel.implicitWidth + Style.space(16); height: editCancel.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: "transparent"
            border.color: Qt.darker(root.bar.foreground, 1.5)
            border.width: 1
            Text { id: editCancel; anchors.centerIn: parent; text: "CANCEL"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelEdit() }
          }
        }
      }
    }
  }
}
