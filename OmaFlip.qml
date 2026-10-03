// Windows-style ALT+TAB window list.
//
// This is the display half. All key handling and all switch state live in
// omaflip.lua next to this file, which runs inside Hyprland. This panel loads
// it with `hyprctl eval` on startup and after every config reload, so the
// install needs no edit to the Hyprland config. The Lua side writes the switch
// to $XDG_RUNTIME_DIR/omaflip.json and this panel renders whatever is there.
//
// While the list is up the panel holds the keyboard exclusively, so keys the
// switcher does not bind (ALT+ESCAPE's pass-through included) land here and
// are dropped instead of reaching the window underneath. Compositor binds and
// the Lua key hook still see every key, so cycling and the ALT release work
// as before. The watchdog bounds how long a missed release can hold the
// keyboard.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
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

  function render(text) {
    let state
    try {
      state = JSON.parse(text)
    } catch (error) {
      return // keep the last good frame
    }
    if (!state.open) {
      root.hide()
      return
    }
    // A TAB only moves the cursor; rebuilding the rows would redo every icon
    // and name lookup on each press.
    if (state.snap !== root.snap) {
      root.snap = state.snap
      root.windows = state.windows || []
    }
    root.selectedIndex = state.index || 0
    root.opened = root.windows.length > 0
    watchdog.restart()
  }

  function hide() {
    watchdog.stop()
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
  // release is ever missed the panel would sit on screen holding the keyboard,
  // so it also gives up on its own and tells the Lua side to reset.
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: {
      root.hide()
      Quickshell.execDetached(["hyprctl", "eval", "__omaflip_cancel()"])
    }
  }

  // A config reload throws away runtime binds and the Lua state with them.
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name !== "configreloaded") return
      root.hide()
      root.applyBinds()
    }
  }

  FileView {
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omaflip.json"
    watchChanges: true
    printErrors: false
    // fileChanged fires before the reread, so parse in onLoaded.
    onFileChanged: reload()
    onLoaded: root.render(text())
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

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaflip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
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
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
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
          color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"

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
              color: Color.menu.text
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
              color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
              opacity: 0.7
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: modelData.title
              color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }
}
