# Where The Foo (`io.github.dabit.wherethefoo`)

A fullscreen overlay showing **every open window on every workspace** as a grid
of live thumbnails, grouped by workspace. Click a tile — or arrow to it and
press Enter — to jump to that window's workspace and focus the window.

## Using it

| Input | Action |
|-------|--------|
| `SUPER + E` | Open / close the overlay |
| Click a tile | Go to that workspace and focus that window |
| `←` `→` `Tab` | Move the selection |
| `↑` `↓` | Move a row |
| `Home` / `End` | First / last window |
| `Enter` | Focus the selected window |
| Type anything | Filter by window title, app, or workspace name |
| `Esc` | Clear the filter, or close the overlay |
| Click the backdrop | Close |

The overlay opens on whichever monitor Hyprland currently has focus on, and
starts with the focused window selected and scrolled into view. Special
workspaces (the scratchpad) are listed last.

## How the thumbnails work

Tiles are live captures via the Wayland screencopy protocol
(`ScreencopyView`), which Hyprland serves for windows on inactive workspaces
too. Nothing is screenshotted to disk and nothing is cached between summons —
the captures start when the overlay opens and stop when it closes. Each
capture is constrained to twice its on-screen tile size so a dozen live
captures stay cheap.

A window with no Wayland handle yet (or one that hasn't produced a frame)
shows its app icon on a flat placeholder instead.

## Requirements

- Omarchy 4 with the Quickshell-based `omarchy-shell` (plugin `schemaVersion: 1`).
- Hyprland, for the window/workspace model and the focus dispatch.

No other dependencies, no setup steps, no configuration file. The plugin adds
no packages and runs no external commands.

### Privileges and data

- **No network access.** Nothing is fetched, uploaded, or phoned home.
- **No subprocesses.** Window focus goes over Hyprland's own IPC socket via
  `Hyprland.dispatch`, not through a shell.
- **No disk writes.** No cache, no state file, no screenshots saved anywhere.
- **Reads** the Hyprland window/workspace model, the desktop-entry database
  (for app icons), and live window content through the Wayland screencopy
  protocol — all of it already available to any plugin in the shell process.

Like every Omarchy plugin, this runs unsandboxed inside `omarchy-shell`.

## Files

```
manifest.json     plugin metadata — kind "overlay", entry point WhereTheFoo.qml
WhereTheFoo.qml   the overlay: model, grid, keyboard handling, activation
Layout.js         pure grid arithmetic and filtering (no QML dependencies)
LICENSE           MIT
```

## Install

```bash
omarchy plugin add https://github.com/dabit/wherethefoo.git --enable --yes
```

That clones the repo into `~/.config/omarchy/plugins/io.github.dabit.wherethefoo/`
and enables it. To install from a local checkout instead:

```bash
git clone ~/git/wherethefoo ~/.config/omarchy/plugins/io.github.dabit.wherethefoo
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.dabit.wherethefoo
```

The plugin folder must be a real directory — `omarchy plugin validate` refuses
a symlinked one, so a checkout that lives elsewhere gets cloned in rather than
linked in.

Then add a keybinding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + E", "Where The Foo", "omarchy-shell shell toggle io.github.dabit.wherethefoo '{}'")
```

`SUPER + E` is unbound in a stock Omarchy install. Reload with
`hyprctl reload` and check with `hyprctl configerrors`.

## Update

```bash
omarchy plugin update io.github.dabit.wherethefoo   # git-managed checkouts
omarchy restart shell                                # see "Hacking on it"
```

## Removal

```bash
omarchy plugin remove io.github.dabit.wherethefoo --yes
```

That disables the plugin, drops its entry from
`~/.config/omarchy/shell.json`, and deletes
`~/.config/omarchy/plugins/io.github.dabit.wherethefoo/`. Then remove the
`o.bind("SUPER + E", ...)` line from `~/.config/hypr/bindings.lua` and run
`hyprctl reload`.

Nothing else is left behind: the plugin writes no files outside its own
directory and its `shell.json` entry.

## Hacking on it

The installed plugin is a git checkout, so the loop is edit here, commit, pull
there, restart:

```bash
git -C ~/git/wherethefoo commit -am "..."
git -C ~/.config/omarchy/plugins/io.github.dabit.wherethefoo pull
omarchy restart shell
```

**The restart is not optional.** Once the overlay has been summoned in a shell
session, edits to its QML do not take effect from a save or from
`omarchy-shell shell rescanPlugins` — the shell logs
`Local plugin changed, reloading: …` and keeps rendering the old code, and
`summon` still returns `ok`. Only `omarchy restart shell` applies the change.
The quickest way to tell "my change is wrong" from "my change is not running"
is to add a method and call it: `shell call <id> <method> ''` returns
`unknown` while the stale item is still mounted.

To check the computed grid without eyeballing it — useful when tuning tile
sizes on a display you can't see:

```bash
omarchy-shell shell summon io.github.dabit.wherethefoo '{}'
omarchy-shell shell call io.github.dabit.wherethefoo metrics ''
# {"screen":"DP-9","usingLua":true,"gridWidth":3006,"tileWidth":490,"columns":6,...}
omarchy-shell shell hide io.github.dabit.wherethefoo
```

### Tuning

All in `WhereTheFoo.qml`, near the top:

- `minTileWidth` / `maxTileWidth` / `targetColumns` — tile size. Tiles grow
  with the window until `maxTileWidth`, so wide displays get bigger
  thumbnails rather than more columns.
- `thumbHeight` — the thumbnail box height, currently `tileWidth * 0.62`.
  Captures are letterboxed inside it at the window's own aspect ratio.

### Activation

Focusing a window also switches to its workspace, so a single dispatch does
both. Hyprland's Lua config (Omarchy 4) rejects the bare
`dispatch focuswindow address:0x…` form, so the plugin branches on
`Hyprland.usingLua` and sends `hl.dsp.focus({ window = "address:0x…" })`
instead, falling back to `focuswindow` on a non-Lua setup.
