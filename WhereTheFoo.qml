import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// Where The Foo: every open window on every workspace, as a grid of live
// thumbnails — the answer to "where the foo is that window?".
//
// Click a tile (or select it and press Enter) to jump to that window's
// workspace and focus it. Thumbnails come from the Wayland screencopy
// protocol, which Hyprland serves for windows on inactive workspaces too, so
// no screenshots are taken or cached anywhere on disk.
//
// Summon:  omarchy-shell shell toggle io.github.dabit.wherethefoo '{}'
Item {
  id: root

  // Host injection (see shell/README.md "Plugin manifest").
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // The host reads `opened` for isPluginOpen(), and calls open()/close().
  property bool opened: false

  // The monitor the overlay is mounted on, latched for the life of a summon.
  property var overlayScreen: null

  // The Quickshell screen matching the monitor Hyprland has focus on, so the
  // overlay opens where the user is already looking.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    var screens = Quickshell.screens
    if (!focused || !screens || screens.length === 0) return null
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name) === String(focused.name)) return screens[i]
    return null
  }

  property string filterText: ""
  property int selectedIndex: 0

  // ------------------------------------------------------------ host contract

  function open(payloadJson) {
    root.filterText = ""
    root.selectedIndex = 0
    // Resolved once per summon, never bound: a window opening on the other
    // monitor moves Hyprland's focus, and a live binding would yank the
    // overlay across screens while the user is looking at it.
    root.overlayScreen = root.focusedScreen()
    root.opened = true
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      root.selectFocusedWindow()
    })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.dabit.wherethefoo")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Introspection for `omarchy-shell shell call io.github.dabit.wherethefoo metrics ''` —
  // useful when tuning the grid on a display you can't eyeball.
  function metrics() {
    return JSON.stringify({
      screen: root.overlayScreen ? String(root.overlayScreen.name) : null,
      usingLua: Hyprland.usingLua,
      gridWidth: Math.round(grid.width),
      gridHeight: Math.round(grid.height),
      tileWidth: root.tileWidth,
      tileHeight: root.tileHeight,
      columns: root.layout.columns,
      tiles: root.tileCount,
      groups: root.filteredGroups.length,
      contentHeight: Math.round(root.layout.height)
    })
  }

  // ------------------------------------------------------------ theme tokens

  readonly property color scrimColor: Color.menu.scrim
  readonly property color surface: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily

  // Tiles grow with the available width up to a cap, so a 2560pt-wide
  // display gets readable thumbnails rather than a stamp collection, and a
  // laptop panel still fits two or three per row.
  readonly property int minTileWidth: Style.space(240)
  readonly property int maxTileWidth: Style.space(420)
  readonly property int targetColumns: 6
  readonly property int tileWidth: {
    var avail = grid.width
    if (avail <= 0) return root.minTileWidth
    var fair = Math.floor((avail - root.tileGap * (root.targetColumns - 1)) / root.targetColumns)
    return Math.round(Math.max(root.minTileWidth, Math.min(root.maxTileWidth, fair)))
  }
  readonly property int captionHeight: Style.space(34)
  // 16:10 thumbnail area; individual captures are letterboxed inside it.
  readonly property int thumbHeight: Math.round(tileWidth * 0.62)
  readonly property int tileHeight: thumbHeight + captionHeight
  readonly property int tileGap: Style.spacing.lg
  readonly property int headerHeight: Style.space(30)
  readonly property int groupGap: Style.spacing.xxl

  // ------------------------------------------------------------ window model

  // Bumped by the Hyprland connections below to force a model rebuild on
  // events that don't themselves touch a bound property.
  property int revision: 0

  function appIdOf(toplevel) {
    if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
    var ipc = toplevel.lastIpcObject
    return ipc && ipc.class ? String(ipc.class) : ""
  }

  function workspaceLabel(ws) {
    var name = String(ws.name || "")
    if (ws.id < 0) return name.indexOf("special:") === 0 ? name.substring(8) : (name || "special")
    return name || String(ws.id)
  }

  // [{ id, label, special, monitor, windows: [...] }], workspaces in reading
  // order with the special/scratchpad ones last.
  readonly property var groups: {
    root.revision
    var activeToplevel = Hyprland.activeToplevel
    var values = Hyprland.workspaces.values
    var out = []

    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var toplevels = ws.toplevels ? ws.toplevels.values : []
      if (!toplevels || toplevels.length === 0) continue

      var windows = []
      for (var j = 0; j < toplevels.length; j++) {
        var tl = toplevels[j]
        var ipc = tl.lastIpcObject || {}
        var appId = root.appIdOf(tl)
        var size = ipc.size && ipc.size.length === 2 ? ipc.size : null
        windows.push({
          address: String(tl.address || ""),
          appId: appId,
          appName: root.appInfo(appId).name,
          title: String(tl.title || ""),
          focused: activeToplevel ? tl === activeToplevel : !!(tl.wayland && tl.wayland.activated),
          // ScreencopyView needs the Wayland toplevel handle, not the Hyprland one.
          toplevel: tl.wayland || null,
          aspect: size && size[1] > 0 ? size[0] / size[1] : 16 / 9,
          workspaceId: ws.id,
          workspaceLabel: root.workspaceLabel(ws)
        })
      }

      windows.sort(Layout.compareWindows)
      out.push({
        id: ws.id,
        label: root.workspaceLabel(ws),
        special: ws.id < 0,
        monitor: ws.monitor ? String(ws.monitor.name || "") : "",
        windows: windows
      })
    }

    out.sort(Layout.compareGroups)
    return out
  }

  readonly property var filteredGroups: Layout.filterGroups(root.groups, root.filterText)
  readonly property var layout: Layout.buildLayout(root.filteredGroups, grid.width, {
    tileWidth: root.tileWidth,
    tileHeight: root.tileHeight,
    gap: root.tileGap,
    headerHeight: root.headerHeight,
    groupGap: root.groupGap
  })
  readonly property int tileCount: root.layout.tiles.length
  readonly property int totalWindows: {
    var n = 0
    for (var i = 0; i < root.groups.length; i++) n += root.groups[i].windows.length
    return n
  }

  Connections {
    target: Hyprland
    // Only events that add, remove or move a window need a model rebuild.
    // windowtitle fires constantly and would churn every live capture.
    readonly property var interesting: ["openwindow", "closewindow", "movewindow",
      "movewindowv2", "changefloatingmode", "fullscreen", "openlayer"]
    function onRawEvent(event) {
      if (!root.opened) return
      if (interesting.indexOf(String(event.name || "")) === -1) return
      Hyprland.refreshToplevels()
      root.revision++
    }
  }

  // ------------------------------------------------------------ app icons

  property var iconCache: ({})

  function appInfo(appId) {
    var key = String(appId || "")
    if (key === "") return { source: "", name: "" }
    var cached = root.iconCache[key]
    if (cached) return cached

    var entry = DesktopEntries.byId(key)
    if (!entry) entry = DesktopEntries.byId(key.toLowerCase())
    if (!entry && typeof DesktopEntries.heuristicLookup === "function")
      entry = DesktopEntries.heuristicLookup(key)

    var iconName = entry && entry.icon ? String(entry.icon) : key
    var source = iconName.charAt(0) === "/" ? Util.fileUrl(iconName) : Quickshell.iconPath(iconName, true)
    var info = { source: source, name: entry && entry.name ? String(entry.name) : key }
    root.iconCache[key] = info
    return info
  }

  // ------------------------------------------------------------ selection

  function clampSelection() {
    if (root.tileCount === 0) { root.selectedIndex = 0; return }
    if (root.selectedIndex < 0) root.selectedIndex = 0
    else if (root.selectedIndex >= root.tileCount) root.selectedIndex = root.tileCount - 1
  }

  function selectFocusedWindow() {
    var tiles = root.layout.tiles
    for (var i = 0; i < tiles.length; i++) {
      if (tiles[i].win.focused) { root.select(i); return }
    }
    root.select(0)
  }

  function select(index) {
    if (root.tileCount === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.tileCount - 1, index))
    root.ensureVisible(root.selectedIndex)
  }

  function step(delta) {
    if (root.tileCount === 0) return
    root.select((root.selectedIndex + delta + root.tileCount) % root.tileCount)
  }

  function stepRow(delta) {
    if (root.tileCount === 0) return
    var next = root.selectedIndex + delta * root.layout.columns
    if (next < 0 || next >= root.tileCount) return
    root.select(next)
  }

  // Scrolls the flickable just far enough to bring a tile fully into view.
  function ensureVisible(index) {
    var tiles = root.layout.tiles
    if (index < 0 || index >= tiles.length) return
    var tile = tiles[index]
    var top = tile.y
    var bottom = tile.y + tile.height
    var viewTop = grid.contentY
    var viewBottom = viewTop + grid.height
    if (top < viewTop) grid.contentY = Math.max(0, top - root.tileGap)
    else if (bottom > viewBottom)
      grid.contentY = Math.min(Math.max(0, grid.contentHeight - grid.height), bottom - grid.height + root.tileGap)
  }

  function setFilter(next) {
    root.filterText = next
    Qt.callLater(function() {
      root.selectedIndex = 0
      root.ensureVisible(0)
    })
  }

  // ------------------------------------------------------------ activation

  property string pendingFocus: ""

  // The focus dispatch has to happen AFTER the overlay's layer surface is
  // gone. Dismissing a surface that holds exclusive keyboard focus makes
  // Hyprland re-evaluate focus, and that fallback runs late and overrides
  // anything dispatched before it — the symptom is landing on the right
  // workspace with the wrong window focused, even with seconds in between.
  // So: dismiss, let the unmap settle, then focus. This is also why the
  // manifest sets `keepLoaded` — without it the host destroys this item on
  // hide and takes the timer with it, and nothing is dispatched at all.
  Timer {
    id: focusTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (root.pendingFocus === "") return
      var address = root.pendingFocus
      root.pendingFocus = ""
      // Hyprland's Lua config (Omarchy 4) rejects the bare
      // `focuswindow address:…` form, so pick the dispatcher the running
      // compositor actually parses. Focusing a window also switches to its
      // workspace, so one dispatch does both halves of the job.
      Hyprland.dispatch(Hyprland.usingLua
        ? 'hl.dsp.focus({ window = "address:' + address + '" })'
        : "focuswindow address:" + address)
    }
  }

  function activate(win) {
    if (!win || !/^0x[0-9a-fA-F]+$/.test(String(win.address))) return
    root.pendingFocus = String(win.address)
    root.dismiss()
    focusTimer.restart()
  }

  function activateSelected() {
    var tiles = root.layout.tiles
    if (root.selectedIndex < 0 || root.selectedIndex >= tiles.length) return
    root.activate(tiles[root.selectedIndex].win)
  }

  // ------------------------------------------------------------ surface

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.overlayScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io-github-dabit-wherethefoo"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimColor
    }

    // Clicking the backdrop closes, same as Escape.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else root.dismiss()
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.step(-1); event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
          root.step(1); event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.stepRow(-1); event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.stepRow(1); event.accepted = true
        } else if (event.key === Qt.Key_Home) {
          root.select(0); event.accepted = true
        } else if (event.key === Qt.Key_End) {
          root.select(root.tileCount - 1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateSelected(); event.accepted = true
        } else if (event.text && event.text.length === 1
          && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      anchors.margins: Style.gapsOut * 2
      radius: root.cornerRadius
      color: root.surface
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // Swallow clicks on the card so they don't reach the dismiss backdrop.
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Item {
          id: headerRow
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: titleText.implicitHeight

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText !== ""
              ? "Filter: " + root.filterText
              : (root.totalWindows === 1 ? "1 window" : root.totalWindows + " windows")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter / click focus   ·   ↑↓←→ move   ·   type to filter   ·   Esc close"
            color: Util.alpha(root.fg, 0.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.top: headerRow.bottom
          anchors.topMargin: Style.spacing.xxl
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.tileCount === 0
          text: root.totalWindows === 0 ? "No open windows." : "No windows match “" + root.filterText + "”."
          color: Util.alpha(root.fg, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Flickable {
          id: grid
          anchors.top: headerRow.bottom
          anchors.topMargin: Style.spacing.md
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          clip: true
          contentWidth: width
          contentHeight: root.layout.height
          boundsBehavior: Flickable.StopAtBounds
          flickDeceleration: 6000

          Repeater {
            model: root.layout.headers

            delegate: Item {
              id: headerTile
              required property var modelData
              x: modelData.x
              y: modelData.y
              width: modelData.width
              height: modelData.height

              Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.spacing.xs
                spacing: Style.spacing.sm

                Text {
                  text: headerTile.modelData.special
                    ? headerTile.modelData.label
                    : "Workspace " + headerTile.modelData.label
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  text: {
                    var md = headerTile.modelData
                    var n = md.count === 1 ? "1 window" : md.count + " windows"
                    return md.monitor ? n + " · " + md.monitor : n
                  }
                  color: Util.alpha(root.fg, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Util.alpha(root.fg, 0.12)
              }
            }
          }

          Repeater {
            model: root.layout.tiles

            delegate: Item {
              id: tile
              required property var modelData
              readonly property var win: modelData.win
              readonly property bool selected: root.selectedIndex === modelData.index
              readonly property bool hovered: tileMouse.containsMouse

              x: modelData.x
              y: modelData.y
              width: modelData.width
              height: modelData.height

              Rectangle {
                anchors.fill: parent
                radius: root.cornerRadius > 0 ? Style.space(6) : 0
                color: tile.selected ? Color.menu.selectedBackground : Util.alpha(root.fg, 0.04)
                border.width: tile.selected || tile.hovered ? 2 : 1
                border.color: tile.selected ? Color.accent
                  : (tile.hovered ? Util.alpha(Color.accent, 0.6) : Util.alpha(root.fg, 0.15))
                Behavior on border.color { ColorAnimation { duration: 90 } }
              }

              // Thumbnail area: the capture is sized to the window's own aspect
              // ratio and centred, so a portrait window is letterboxed instead
              // of stretched.
              Item {
                id: thumbBox
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.spacing.sm
                height: root.thumbHeight - Style.spacing.sm * 2
                clip: true

                ScreencopyView {
                  id: capture
                  readonly property real ratio: sourceSize.width > 0 && sourceSize.height > 0
                    ? sourceSize.width / sourceSize.height
                    : (tile.win.aspect > 0 ? tile.win.aspect : 16 / 9)

                  anchors.centerIn: parent
                  width: Math.max(1, Math.min(thumbBox.width, thumbBox.height * ratio))
                  height: Math.max(1, Math.min(thumbBox.height, thumbBox.width / ratio))
                  // Cap the capture resolution: N live captures at full size
                  // would be a lot of GPU work for thumbnails this small.
                  constraintSize: Qt.size(Math.round(width * 2), Math.round(height * 2))
                  // keepLoaded means these delegates outlive a summon, so the
                  // capture source is dropped on close, not just paused.
                  captureSource: root.opened ? (tile.win.toplevel || null) : null
                  live: root.opened
                  opacity: hasContent ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                // Placeholder until the first frame lands (or for a window
                // that has no Wayland handle to capture, e.g. Xwayland).
                Rectangle {
                  anchors.fill: parent
                  visible: !capture.hasContent
                  color: Util.alpha(root.fg, 0.06)

                  Image {
                    anchors.centerIn: parent
                    width: Style.space(40)
                    height: width
                    source: root.appInfo(tile.win.appId).source
                    sourceSize.width: width * 2
                    sourceSize.height: height * 2
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                  }
                }
              }

              // Caption: app icon, window title, and a dot for the focused window.
              Item {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                height: root.captionHeight

                Image {
                  id: captionIcon
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  height: width
                  source: root.appInfo(tile.win.appId).source
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }

                Rectangle {
                  id: focusDot
                  visible: tile.win.focused
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: Color.accent
                }

                Text {
                  anchors.left: captionIcon.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: focusDot.visible ? focusDot.left : parent.right
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: tile.win.title !== "" ? tile.win.title : root.appInfo(tile.win.appId).name
                  elide: Text.ElideRight
                  color: tile.selected ? Color.menu.selectedText : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                id: tileMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                onPositionChanged: root.selectedIndex = tile.modelData.index
                onClicked: root.activate(tile.win)
              }
            }
          }
        }
      }
    }
  }

  onTileCountChanged: root.clampSelection()
}
