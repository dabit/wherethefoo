import QtQuick
import qs.Ui

// Bar entry for Where The Foo: a grid glyph that opens the overlay.
//
// This exists because a plugin cannot ship a keybinding - the manifest has no
// field for one and Omarchy has no command that writes bindings. Without a bar
// entry, a fresh install does nothing at all until the user hand-edits
// bindings.lua. Same shape as the first-party omarchy.menu widget.
BarWidget {
  id: root
  moduleName: "io.github.dabit.wherethefoo"

  // Host injection: the capability-scoped shell facade, which may toggle this
  // plugin's own overlay and nothing else.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.dabit.wherethefoo"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function toggleOverlay() {
    if (root.shell && typeof root.shell.toggle === "function") {
      root.shell.toggle(root.pluginId, "{}")
      return
    }
    // Fallback for a host that did not inject the facade: same command the
    // keybinding runs.
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("omarchy-shell shell toggle " + root.pluginId + " '{}'")
  }

  // BarIconButton, not WidgetButton: it renders the glyph through OpticalGlyph
  // inside a fixed icon slot, correcting for the fact that an icon glyph's ink
  // is rarely centred within its advance width. WidgetButton centres the text
  // box instead, which leaves the visible mark off-centre. Every single-glyph
  // bar widget in the shell uses this; omarchy.menu is the exception only
  // because its glyph comes from a purpose-drawn icon font.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Font Awesome "th-large": a 2x2 grid, i.e. the tiles the overlay shows.
    // Same Nerd Font the other bar widgets draw their icons from.
    text: "\uf009"
    tooltipText: "Where The Foo \u2014 all windows"
    active: root.shell && typeof root.shell.isPluginOpen === "function"
      ? root.shell.isPluginOpen(root.pluginId) : false
    onPressed: function(which) {
      if (which === Qt.LeftButton) root.toggleOverlay()
    }
  }
}
