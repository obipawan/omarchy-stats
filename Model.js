// obi.stats — stat attribute definitions.
//
// Pure JS so the whole list is trivially testable and easy to extend without
// touching the QML panel. Each entry describes one bar item the panel renders
// and the dropdown it opens. Functionality (live values) is added later by
// giving each definition a data source; the panel shell stays the same.

// The ordered list of stats shown in the bar, left to right.
// The icons are literal Nerd Font glyphs (single characters, no escapes) so
// they survive whatever JS engine loads the module.
function statDefinitions() {
  return [
    { id: "cpu", label: "CPU", icon: "󰶲", section: "CPU" },
    { id: "gpu", label: "GPU", icon: "󱍀", section: "GPU" },
    { id: "disk", label: "Disk", icon: "󰷄", section: "Disk" },
    { id: "ram", label: "RAM", icon: "󰴃", section: "RAM" },
    { id: "battery", label: "Battery", icon: "󰭄", section: "Battery" },
    { id: "network", label: "Network", icon: "󰭆", section: "Network" },
  ]
}

// Look up a stat by id; the bar item for `id` and the dropdown it opens both
// come from the same entry so they can never drift apart.
function statById(definitions, id) {
  var defs = Array.isArray(definitions) ? definitions : []
  for (var i = 0; i < defs.length; i++) {
    if (defs[i] && defs[i].id === String(id)) return defs[i]
  }
  return null
}

// The moment the cursor parks on a stat item, this returns the display name
// the panel should lead with. Distinct from `label` so a stat can keep a
// short bar label (e.g. "CPU") while showing something richer in the panel.
function sectionTitle(stat) {
  if (!stat) return ""
  return String(stat.section || stat.label || "").toUpperCase()
}

// ============================ CPU =========================================
// Parses the tab-separated output of cpu.sh into a single object the panel
// binds to. cpu.sh emits:
//   total\t<percent>
//   core\t<index>\t<percent>
//   proc\t<pid>\t<percent>\t<comm>
// Returns { total, cores:[{name,pct}], procs:[{pid,pct,comm}] }.
function parseCpuOutput(raw) {
  var lines = String(raw || "").split("\n")
  var total = -1
  var cores = []
  var procs = []
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    if (kind === "total") {
      total = parseFloat(parts[1])
      if (!isFinite(total)) total = -1
    } else if (kind === "core") {
      var corePct = parseFloat(parts[2] || "")
      if (isFinite(corePct)) cores.push({ name: String(parts[1] || ""), pct: Math.round(corePct) })
    } else if (kind === "proc") {
      var procPct = parseFloat(parts[2] || "")
      if (isFinite(procPct))
        procs.push({ pid: String(parts[1] || ""), pct: Math.round(procPct * 10) / 10, comm: String(parts[3] || "") })
    }
  }
  return { total: total === -1 ? 0 : Math.round(total * 10) / 10, cores: cores, procs: procs }
}

// Keep the newest `limit` process rows (cpu.sh already sorts desc by %; this
// is a defensive cap and a testable unit on its own).
function topProcRows(procs, limit) {
  var rows = Array.isArray(procs) ? procs : []
  var n = Math.max(1, parseInt(limit, 10) || rows.length)
  var trimmed = rows.slice(0, Math.min(n, rows.length))
  return trimmed.filter(function(p) { return p.pct > 0 || p.comm !== "" })
}

// History ring buffer. Appends {time, total} and drops anything older than
// `maxSeconds`. Pure so it is node-testable; the panel just calls it with the
// previous array and the new value.
function appendHistory(history, nowSeconds, value, maxSeconds) {
  var h = Array.isArray(history) ? history.slice() : []
  var max = Math.max(1, parseInt(maxSeconds, 10) || 3600)
  h.push({ time: Number(nowSeconds) || 0, total: Number(value) || 0 })
  var cutoff = (Number(nowSeconds) || 0) - max
  while (h.length > 0 && h[0].time < cutoff) h.shift()
  return h
}

// Downsample a long history to fit a fixed bar width, so the graph window is
// fixed regardless of refresh frequency. Buckets evenly across min..max time.
function downsample(history, buckets) {
  var h = Array.isArray(history) ? history : []
  var count = Math.max(1, parseInt(buckets, 10) || h.length || 1)
  if (h.length <= 1) return h
  var earliest = h[0].time
  var latest = h[h.length - 1].time
  var span = Math.max(1, latest - earliest)
  var out = []
  for (var i = 0; i < count; i++) {
    var targetStart = earliest + span * (i / count)
    var targetEnd = earliest + span * ((i + 1) / count)
    var sum = 0, n = 0
    for (var j = 0; j < h.length; j++) {
      if (h[j].time >= targetStart && h[j].time < targetEnd) { sum += h[j].total; n++ }
    }
    // Buckets with no sample carry the last seen value forward so the graph
    // has no holes, then fall to the global average if nothing at all.
    var value = n > 0 ? sum / n : (out.length > 0 ? out[out.length - 1].total : averageValue(h))
    out.push({ time: targetStart, total: value })
  }
  return out
}

// A true moving/streaming timeline. Returns exactly `buckets` values mapping
// ONE live sample per column, NEWEST pinned at the far right edge. On each
// refresh the newest sample lands on the right and everything shifts one
// column left, so old values are literally pushed left. Before the window is
// full, the newest is still at the right edge and empty leading columns are
// 0 — the trace fills right-to-left, then scrolls. Pure and node-testable.
function scrollWindow(history, buckets) {
  var h = Array.isArray(history) ? history : []
  var n = Math.max(1, parseInt(buckets, 10) || 1)
  // Result has length n. The last `fill` samples sit at the RIGHT end (newest
  // at position n-1); any room left over at the start is empty (0). When the
  // history is full this is exactly the most recent n samples in order, so
  // each new sample pushes everything one column left.
  var fill = Math.min(n, h.length)
  var start = h.length - fill
  var out = []
  for (var i = 0; i < n; i++) out.push(0)
  for (var k = 0; k < fill; k++) out[n - fill + k] = Number(h[start + k].total || 0)
  return out
}

function averageValue(history) {
  var h = Array.isArray(history) ? history : []
  if (h.length === 0) return 0
  var sum = 0
  for (var i = 0; i < h.length; i++) sum += Number(h[i].total || 0)
  return sum / h.length
}

// Normalize a list of pct values to 0..1 against the max (min 1). Used to turn
// per-core or history values into bar/column heights.
function normalize(values, floor) {
  var v = Array.isArray(values) ? values : []
  var lo = floor === undefined ? 0 : Number(floor)
  var max = lo
  for (var i = 0; i < v.length; i++) if (Number(v[i]) > max) max = Number(v[i])
  if (max <= 0) max = 1
  var out = []
  for (var j = 0; j < v.length; j++) out.push(Number(v[j]) / max)
  return out
}

function formatPct(value) {
  var v = parseFloat(value)
  if (!isFinite(v) || v < 0) return "--"
  return Math.round(v) + "%"
}

if (typeof module !== "undefined") {
  module.exports = {
    statDefinitions: statDefinitions,
    statById: statById,
    sectionTitle: sectionTitle,
    parseCpuOutput: parseCpuOutput,
    topProcRows: topProcRows,
    appendHistory: appendHistory,
    downsample: downsample,
    scrollWindow: scrollWindow,
    averageValue: averageValue,
    normalize: normalize,
    formatPct: formatPct
  }
}
