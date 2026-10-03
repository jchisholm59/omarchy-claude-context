import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Claude Context: Claude Code's /context as a bar panel. A 20x10 grid where each
// cell is 0.5% of the context window, coloured by category; a legend with tokens
// and share; and a picker for the most recent sessions.
//
// Data comes from bin/claude-context, which runs /context on a throwaway fork of
// the session (claude -p --resume <id> --fork-session --no-session-persistence):
// no API call, ~3 s, and the real session is never written to. It only runs when
// the panel opens or you refresh it.
Panel {
  id: root
  moduleName: "jim.claude-context"
  ipcTarget: "jim.claude-context"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string helper: Qt.resolvedUrl("bin/claude-context").toString().replace(/^file:\/\//, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property int gridCols: 20
  readonly property int gridRows: 10
  readonly property var categoryColours: ({
    "System prompt": "#8F9C8E",
    "System tools": "#61756A",
    "MCP tools": "#509475",
    "MCP server instructions": "#2DD5B7",
    "Custom agents": "#ACD4CF",
    "Memory files": "#E67E50",
    "Skills": "#E5C736",
    "Messages": "#8C83C9"
  })
  readonly property color otherColour: "#D2689C"
  readonly property color dim: Qt.darker(Color.popups.text, 1.6)
  readonly property color freeBorder: Util.alpha(Color.popups.text, 0.18)
  readonly property color bufferFill: Util.alpha(Color.urgent, 0.35)

  property var ctx: null          // last claude-context result
  property var sessions: []
  property string sessionId: ""   // "" = the newest session
  property bool pickerOpen: false
  property double nowMs: Date.now()

  readonly property bool running: ctxProc.running
  readonly property bool hasData: !!(ctx && ctx.window)
  readonly property var categories: hasData ? ctx.categories : []
  readonly property var cells: buildCells()

  function formatTokens(n) {
    n = Number(n || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"
  function friendlyModelName(id) {
    if (!id) return "Unknown"
    var parts = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "").replace(/\[.*\]$/, "").split("-")
    var words = [], version = []
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      if (part === "") continue
      if (/^\d/.test(part)) { version.push(part); continue }
      if (version.length) words.push(version.join("."))
      version = []
      words.push(part.charAt(0).toUpperCase() + part.slice(1))
    }
    if (version.length) words.push(version.join("."))
    return words.join(" ")
  }

  function isLoaded(name) { return !/deferred|^Free space$|^Autocompact buffer$/i.test(name) }
  function colourFor(name) { return categoryColours[name] || otherColour }

  function sessionLabel(s) {
    if (!s) return { title: running ? "Loading…" : "No session", meta: "" }
    var age = s.mtime ? formatDuration(nowMs - s.mtime * 1000) : ""
    var dir = String(s.cwd || "").replace(home, "~")
    return { title: s.title || String(s.id).slice(0, 8), meta: [dir, age ? age + " ago" : ""].filter(function(x) { return !!x }).join(" · ") }
  }

  // Loaded categories in /context order, then free space, then the autocompact buffer.
  function buildCells() {
    var total = gridCols * gridRows
    var out = []
    if (!hasData) {
      for (var e = 0; e < total; e++) out.push("free")
      return out
    }
    var cats = ctx.categories
    for (var i = 0; i < cats.length; i++) {
      var cat = cats[i]
      if (!isLoaded(cat.name) || !(cat.tokens > 0)) continue
      var n = Math.max(1, Math.round(cat.tokens / ctx.window * total))
      for (var j = 0; j < n; j++) out.push(colourFor(cat.name))
    }
    var bufferCells = 0
    for (var k = 0; k < cats.length; k++)
      if (/^Autocompact buffer$/i.test(cats[k].name)) bufferCells = Math.round(cats[k].tokens / ctx.window * total)
    while (out.length < total - bufferCells) out.push("free")
    while (out.length < total) out.push("buffer")
    out.length = total
    return out
  }

  function refresh() {
    if (ctxProc.running) return
    ctxProc.command = sessionId ? [helper, sessionId] : [helper]
    ctxProc.running = true
  }

  function loadSessions() {
    if (!listProc.running) listProc.running = true
  }

  function pickSession(s) {
    sessionId = sessions.length && s.id === sessions[0].id ? "" : s.id
    pickerOpen = false
    refresh()
  }

  onOpenedChanged: {
    if (!opened) { pickerOpen = false; return }
    nowMs = Date.now()
    refresh()
  }

  Process {
    id: ctxProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) {}
        root.ctx = data || { error: "claude-context printed nothing" }
        root.nowMs = Date.now()
      }
    }
  }

  Process {
    id: listProc
    command: [root.helper, "--list"]
    stdout: StdioCollector {
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) {}
        root.sessions = Array.isArray(data) ? data : []
      }
    }
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕰"
    active: root.opened
    tooltipText: "Claude context"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { root.refresh(); root.open() }
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  component Label: Text {
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") { root.pickerOpen = !root.pickerOpen; if (root.pickerOpen) root.loadSessions() }
      }

      Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.spacing.xl

          // Session picker
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: pickRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: pickMouse.containsMouse || root.pickerOpen ? Util.alpha(Color.popups.text, 0.08) : "transparent"
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(Color.popups.text, 0.15)

            ColumnLayout {
              id: pickRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.spacing.xxs
              Label {
                Layout.fillWidth: true
                text: root.sessionLabel(root.ctx ? root.ctx.session : null).title + "  ▾"
                font.bold: true
              }
              Label {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.sessionLabel(root.ctx ? root.ctx.session : null).meta
                color: root.dim
                font.pixelSize: Style.font.bodySmall
              }
            }
            MouseArea {
              id: pickMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.pickerOpen = !root.pickerOpen
                if (root.pickerOpen) root.loadSessions()
              }
            }
          }

          // Session list
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.pickerOpen
            spacing: Style.spacing.xs
            Label {
              visible: root.sessions.length === 0
              text: "Loading…"
              color: root.dim
            }
            Repeater {
              model: root.sessions
              delegate: Rectangle {
                id: item
                required property var modelData
                readonly property var info: root.sessionLabel(modelData)
                readonly property bool current: root.ctx && root.ctx.session && root.ctx.session.id === modelData.id
                Layout.fillWidth: true
                implicitHeight: itemCol.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: itemMouse.containsMouse ? Util.alpha(Color.popups.text, 0.08) : "transparent"
                ColumnLayout {
                  id: itemCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: 0
                  Label { Layout.fillWidth: true; text: item.info.title; font.bold: item.current; color: item.current ? Color.accent : Color.popups.text }
                  Label { Layout.fillWidth: true; text: item.info.meta; color: root.dim; font.pixelSize: Style.font.bodySmall }
                }
                MouseArea {
                  id: itemMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickSession(item.modelData)
                }
              }
            }
          }

          // Status / error while there's nothing to draw
          Label {
            Layout.fillWidth: true
            visible: !root.hasData
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            text: root.running || !root.ctx ? "Running /context…" : "Couldn't read context: " + (root.ctx.error || "unknown error")
            color: root.running || !root.ctx ? root.dim : Color.urgent
          }

          // Headline: model, tokens used of the window
          RowLayout {
            Layout.fillWidth: true
            visible: root.hasData
            Label {
              Layout.fillWidth: true
              text: root.hasData ? root.friendlyModelName(root.ctx.model) : ""
            }
            Label {
              text: root.hasData ? root.formatTokens(root.ctx.used) + " / " + root.formatTokens(root.ctx.window)
                + " (" + Math.round(root.ctx.used / root.ctx.window * 100) + "%)" : ""
              font.bold: !root.running
              color: root.running ? root.dim : Color.popups.text
            }
          }

          // The grid: each cell is 0.5% of the window
          Grid {
            id: grid
            Layout.alignment: Qt.AlignHCenter
            columns: root.gridCols
            spacing: Style.space(4)
            readonly property real cell: Math.floor((column.width - spacing * (columns - 1)) / columns)
            opacity: root.running && root.hasData ? 0.6 : 1.0
            Repeater {
              model: root.cells
              delegate: Rectangle {
                required property var modelData
                width: grid.cell
                height: grid.cell
                radius: Math.max(2, Style.space(3))
                color: modelData === "free" ? "transparent" : modelData === "buffer" ? root.bufferFill : modelData
                border.width: modelData === "free" || modelData === "buffer" ? 1 : 0
                border.color: modelData === "buffer" ? Util.alpha(Color.urgent, 0.6) : root.freeBorder
              }
            }
          }

          // Legend: every category with its share; deferred tools are listed but not loaded
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.hasData
            spacing: Style.spacing.sm
            Repeater {
              model: root.categories
              delegate: RowLayout {
                id: row
                required property var modelData
                readonly property bool loaded: root.isLoaded(modelData.name)
                readonly property bool isFree: /^Free space$/i.test(modelData.name)
                readonly property bool isBuffer: /^Autocompact buffer$/i.test(modelData.name)
                Layout.fillWidth: true
                spacing: Style.spacing.lg
                Rectangle {
                  implicitWidth: Style.space(10)
                  implicitHeight: Style.space(10)
                  radius: Math.max(2, Style.space(2))
                  color: row.isBuffer ? root.bufferFill : row.loaded ? root.colourFor(row.modelData.name) : "transparent"
                  border.width: row.loaded && !row.isBuffer ? 0 : 1
                  border.color: row.isBuffer ? Util.alpha(Color.urgent, 0.6) : root.freeBorder
                }
                Label {
                  Layout.fillWidth: true
                  text: row.modelData.name
                  color: row.loaded || row.isFree || row.isBuffer ? Color.popups.text : root.dim
                }
                Label {
                  text: root.formatTokens(row.modelData.tokens)
                  font.bold: row.loaded
                  color: row.loaded ? Color.popups.text : root.dim
                  horizontalAlignment: Text.AlignRight
                  Layout.preferredWidth: Style.space(52)
                }
                Label {
                  text: (row.modelData.tokens / root.ctx.window * 100).toFixed(1) + "%"
                  color: root.dim
                  horizontalAlignment: Text.AlignRight
                  Layout.preferredWidth: Style.space(44)
                }
              }
            }
          }

          Label {
            Layout.fillWidth: true
            visible: root.hasData && !!(root.ctx.session && root.ctx.session.lastRequest)
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            color: root.dim
            font.pixelSize: Style.font.caption
            text: root.hasData && root.ctx.session
              ? "Last API call sent " + root.formatTokens(root.ctx.session.lastRequest) + " tokens. The breakdown is /context run on "
                + "a throwaway copy of the session, so tool sizes can differ slightly from the live one."
              : ""
          }

          // Footer: freshness and refresh
          RowLayout {
            Layout.fillWidth: true
            Label {
              Layout.fillWidth: true
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              text: root.running ? "Running /context…"
                : root.ctx && root.ctx.updatedAt
                  ? (root.nowMs - root.ctx.updatedAt * 1000 < 60000 ? "Updated just now"
                     : "Updated " + root.formatDuration(root.nowMs - root.ctx.updatedAt * 1000) + " ago")
                  : ""
            }
            Button {
              text: "Refresh"
              foreground: Color.popups.text
              bordered: true
              enabled: !root.running
              tooltipText: "Run /context again (R)"
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }
}
