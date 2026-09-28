.pragma library

// Pure layout + filtering helpers for the Where The Foo overlay. Kept out of the QML
// so the grid arithmetic stays readable and testable on its own.

// Case-insensitive substring match across the fields a user would type.
function matches(win, needle) {
  if (!needle) return true
  var n = String(needle).toLowerCase()
  return String(win.title || "").toLowerCase().indexOf(n) !== -1
    || String(win.appId || "").toLowerCase().indexOf(n) !== -1
    || String(win.appName || "").toLowerCase().indexOf(n) !== -1
    || String(win.workspaceLabel || "").toLowerCase().indexOf(n) !== -1
}

// Drops windows that don't match, then groups that end up empty.
function filterGroups(groups, needle) {
  var out = []
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    var kept = []
    for (var j = 0; j < g.windows.length; j++)
      if (matches(g.windows[j], needle)) kept.push(g.windows[j])
    if (kept.length === 0) continue
    out.push({ id: g.id, label: g.label, special: g.special, monitor: g.monitor, windows: kept })
  }
  return out
}

// Absolute positions for every header and tile, in one pass.
//
// Laying the grid out here rather than with a Flow inside a Column buys two
// things: a single flat tile list (so keyboard selection is just an index)
// and exact tile coordinates (so scrolling to the selection is arithmetic
// rather than a walk over nested delegates).
function buildLayout(groups, width, opts) {
  var tileW = opts.tileWidth
  var tileH = opts.tileHeight
  var gap = opts.gap
  var headerH = opts.headerHeight
  var groupGap = opts.groupGap

  var columns = Math.max(1, Math.floor((width + gap) / (tileW + gap)))
  var usedWidth = columns * tileW + (columns - 1) * gap
  var offsetX = Math.max(0, Math.round((width - usedWidth) / 2))

  var tiles = []
  var headers = []
  var y = 0

  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    headers.push({ y: y, height: headerH, label: g.label, special: g.special,
                   monitor: g.monitor, count: g.windows.length, x: offsetX, width: usedWidth })
    y += headerH

    for (var j = 0; j < g.windows.length; j++) {
      var col = j % columns
      var row = Math.floor(j / columns)
      tiles.push({
        index: tiles.length,
        x: offsetX + col * (tileW + gap),
        y: y + row * (tileH + gap),
        width: tileW,
        height: tileH,
        win: g.windows[j]
      })
    }

    var rows = Math.ceil(g.windows.length / columns)
    y += rows * tileH + Math.max(0, rows - 1) * gap
    if (i < groups.length - 1) y += groupGap
  }

  return { tiles: tiles, headers: headers, height: y, columns: columns }
}

// Workspaces in reading order, with the special/scratchpad ones last.
function compareGroups(a, b) {
  if (a.special !== b.special) return a.special ? 1 : -1
  return a.id - b.id
}

// Stable window order inside a workspace: focused first, then by app, then title.
function compareWindows(a, b) {
  if (a.focused !== b.focused) return a.focused ? -1 : 1
  var byApp = String(a.appId || "").localeCompare(String(b.appId || ""))
  if (byApp !== 0) return byApp
  return String(a.title || "").localeCompare(String(b.title || ""))
}
