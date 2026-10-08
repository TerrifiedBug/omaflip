// Windows-style ALT+TAB window list.
//
// This is the display half. All key handling and all switch state live in
// omaflip.lua next to this file, which runs inside Hyprland. This panel loads
// it with `hyprctl eval` on startup and after every config reload, so the
// install needs no edit to the Hyprland config. The Lua side sends each step
// as a Hyprland custom event (`custom>>omaflip:<json>`) on the event socket
// Quickshell already reads, so a TAB costs no process spawn.
//
// The panel takes no keyboard focus. While a switch is up the Lua side holds
// the keyboard in a submap whose catchall drops unbound keys, so nothing
// leaks to the window underneath and focus can still move on commit.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  // Injected by Omarchy's panel loader.
  property var shell: null
  property var manifest: null
  property bool opened: false
  property var windows: []
  property int selectedIndex: 0
  property int snap: -1
  // Set once the reveal delay has passed, so a quick ALT+TAB flip never maps
  // the list at all.
  property bool revealed: false
  // The panel loader hands a panel no settings, so the plugins[] entry is read
  // straight out of shell.json.
  property var pluginEntry: ({})

  readonly property string pluginId: String((manifest && manifest.id) || "io.github.terrifiedbug.omaflip")
  readonly property bool showIcons: pluginEntry.showIcons !== false
  readonly property string luaPath: decodeURIComponent(String(Qt.resolvedUrl("omaflip.lua")).replace(/^file:\/\//, ""))

  readonly property int rowHeight: Math.max(Style.space(34), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int maxCardHeight: panel.height - Style.gapsOut * 2

  function applyBinds() {
    Quickshell.execDetached(["hyprctl", "eval", "dofile(" + JSON.stringify(root.luaPath) + ")"])
  }

  function render(json) {
    let message
    try {
      message = JSON.parse(json)
    } catch (error) {
      return // keep the last good frame
    }
    if (message.hide) {
      root.hide()
      return
    }
    // The rows arrive once per switch; a TAB only moves the cursor, so the
    // icon and name lookups are not redone on each press.
    if (message.windows) {
      root.snap = message.snap
      root.windows = message.windows
      revealTimer.restart()
    } else if (message.snap !== root.snap) {
      return // a step of a switch this panel never saw start
    }
    root.selectedIndex = message.index || 0
    root.opened = root.windows.length > 0
    watchdog.restart()
  }

  function hide() {
    watchdog.stop()
    revealTimer.stop()
    root.revealed = false
    root.opened = false
  }

  function readSettings(text) {
    try {
      const plugins = JSON.parse(text).plugins || []
      for (let i = 0; i < plugins.length; i++) {
        if (plugins[i] && plugins[i].id === root.pluginId) {
          root.pluginEntry = plugins[i]
          return
        }
      }
      root.pluginEntry = ({})
    } catch (error) {
      // Mid-write or malformed: keep the last good entry.
    }
  }

  function setPluginSetting(name, rawValue) {
    if (name !== "showIcons") return "unknown setting: " + name

    const value = String(rawValue || "").trim().toLowerCase()
    if (value !== "true" && value !== "false") return "showIcons must be true or false"
    if (!shell || typeof shell.updateEntryInline !== "function") return "unavailable"

    const next = ({})
    for (const key in root.pluginEntry) if (key !== "id") next[key] = root.pluginEntry[key]
    next[name] = value === "true"
    shell.updateEntryInline(root.pluginId, next)
    root.pluginEntry = Object.assign({ id: root.pluginId }, next)
    return value
  }

  function friendlyAppName(appClass) {
    const raw = String(appClass || "").trim()
    if (!raw) return "Unknown"

    // Window classes usually match a desktop-file id or StartupWMClass.
    // Let Quickshell resolve both before falling back to formatting the id.
    const entry = DesktopEntries.heuristicLookup(raw)
    if (entry && entry.name) return String(entry.name)

    let name = raw.replace(/^steam_app_/i, "")
    if (name.indexOf(".") !== -1) name = name.split(".").pop()
    name = name.replace(/[_-]+/g, " ").trim()
    return name.replace(/(^|\s)\S/g, function(letter) { return letter.toUpperCase() })
  }

  function appIcon(appClass) {
    const raw = String(appClass || "").trim()
    const entry = raw ? DesktopEntries.heuristicLookup(raw) : null
    const icon = entry ? String(entry.icon || "") : ""

    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  Component.onCompleted: applyBinds()

  // A switch ends when ALT is released, which the Lua side sees. If that
  // release is ever missed the switch would sit on screen with the keyboard
  // held in its submap, so the panel gives up on its own and resets the Lua
  // side.
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: {
      root.hide()
      Quickshell.execDetached(["hyprctl", "eval", "__omaflip_cancel()"])
    }
  }

  // A flip (tap TAB, let go) is over well inside this; only a held ALT shows
  // the list. Same delay the other hold-to-reveal switchers settled on.
  Timer {
    id: revealTimer
    interval: 90
    onTriggered: root.revealed = true
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name === "custom" && event.data.indexOf("omaflip:") === 0) {
        root.render(event.data.slice(8))
      } else if (event.name === "configreloaded") {
        // A reload throws away runtime binds and the Lua state with them.
        root.hide()
        root.applyBinds()
      }
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readSettings(text())
  }

  IpcHandler {
    target: "omaflip"

    function state(): string {
      return root.opened ? "open" : "closed"
    }

    function set(name: string, value: string): string {
      return root.setPluginSetting(name, value)
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened && root.revealed
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaflip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    BorderSurface {
      id: card

      width: root.cardWidth
      // BorderSurface exposes its padding as numbers rather than insetting its
      // children, so the rows below carry the same insets by hand and the card
      // is measured to match. Filling it outright leaves dead space under the
      // last row.
      height: Math.min(
        root.maxCardHeight,
        root.windows.length * root.rowHeight + card.contentTopInset + card.contentBottomInset
      )
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      ListView {
        id: list

        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        clip: true
        interactive: false
        model: root.windows
        currentIndex: root.selectedIndex
        highlightMoveDuration: 0
        // Keep the cursor on screen when there are more windows than fit.
        preferredHighlightBegin: 0
        preferredHighlightEnd: height
        highlightRangeMode: ListView.ApplyRange

        delegate: Rectangle {
          required property int index
          required property var modelData

          width: list.width
          height: root.rowHeight
          radius: Style.cornerRadius
          color: index === root.selectedIndex ? Commons.Color.menu.selectedBackground : "transparent"

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.md

            // Workspace number, so a switch across workspaces is legible.
            Text {
              Layout.preferredWidth: Style.space(24)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: modelData.workspace
              color: Commons.Color.menu.text
              opacity: 0.5
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Image {
              visible: root.showIcons
              Layout.preferredWidth: Style.space(24)
              Layout.preferredHeight: Style.space(24)
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: root.showIcons ? root.appIcon(modelData.appClass) : ""
              asynchronous: true
            }

            Text {
              Layout.preferredWidth: Style.space(88)
              Layout.maximumWidth: Style.space(88)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.friendlyAppName(modelData.appClass)
              color: index === root.selectedIndex ? Commons.Color.menu.selectedText : Commons.Color.menu.text
              opacity: 0.7
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: modelData.title
              color: index === root.selectedIndex ? Commons.Color.menu.selectedText : Commons.Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }
}
