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
// is a defensive cap and a testable unit on its own). `field` names the metric
// to filter on — "pct" for CPU rows, "mem" for GPU rows — so rows whose only
// distinguishing value is unknown (0) are dropped, not rows lacking the field
// entirely (e.g. a GPU proc with mem but no meaningful pct).
function topProcRows(procs, limit, field) {
  var rows = Array.isArray(procs) ? procs : []
  var n = Math.max(1, parseInt(limit, 10) || rows.length)
  var key = String(field || "pct")
  var trimmed = rows.slice(0, Math.min(n, rows.length))
  return trimmed.filter(function(p) {
    var v = Number(p && p[key])
    return (isFinite(v) && v > 0) || String(p && p.comm || "") !== ""
  })
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

// ============================ GPU =========================================
// Parses the tab-separated output of gpu.sh into a single object the panel
// binds to. gpu.sh emits (mirroring cpu.sh's total/core/proc shape):
//   vendor\t<name>                  intel | nvidia | amd | unknown
//   model\t<string>
//   status\t<ok|no-tool|no-gpu|error>
//   total\t<percent>                aggregate utilization (0..100)
//   temp\t<celcius>                 optional
//   memUsed\t<MiB>                  optional
//   memTotal\t<MiB>                 optional
//   engine\t<name>\t<percent>       per-engine utilization (repeats)
//   proc\t<pid>\t<memMiB>\t<comm>   top GPU processes by mem (repeats)
// Returns { vendor, model, status, ready, total, temp, memUsed, memTotal,
//           engines:[{name,pct}], procs:[{pid,mem,comm}], hints:[..], setup }.
// `ready` is true only when status === "ok" (a live sample was produced).
// `hints` collects backend `hint` lines (e.g. a permission fix to grant a
// capability), shown verbatim in the setup card.
// `setup` carries the guidance the panel shows when NOT ready.
function parseGpuOutput(raw) {
  var lines = String(raw || "").split("\n")
  var out = { vendor: "", model: "", status: "", ready: false, total: -1,
              temp: -1, memUsed: -1, memTotal: -1, engines: [], procs: [], hints: [] }
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    if (kind === "vendor") out.vendor = String(parts[1] || "")
    else if (kind === "model") out.model = String(parts[1] || "")
    else if (kind === "status") out.status = String(parts[1] || "")
    else if (kind === "total") { var tv = parseFloat(parts[1]); if (isFinite(tv)) out.total = Math.round(tv * 10) / 10 }
    else if (kind === "temp") { var tp = parseFloat(parts[1]); if (isFinite(tp)) out.temp = Math.round(tp) }
    else if (kind === "memUsed") { var mu = parseFloat(parts[1]); if (isFinite(mu)) out.memUsed = mu }
    else if (kind === "memTotal") { var mt = parseFloat(parts[1]); if (isFinite(mt)) out.memTotal = mt }
    else if (kind === "hint") { var h = String(parts[1] || "").trim(); if (h !== "") out.hints.push(h) }
    else if (kind === "engine") {
      var ep = parseFloat(parts[2] || "")
      if (isFinite(ep)) out.engines.push({ name: String(parts[1] || "").toUpperCase(), pct: Math.round(ep) })
    } else if (kind === "proc") {
      var mp = parseFloat(parts[2] || "")
      if (isFinite(mp))
        out.procs.push({ pid: String(parts[1] || "").trim(), mem: Math.round(mp),
                         comm: String(parts[3] || "").trim() })
    }
  }
  out.ready = out.status === "ok" && out.total >= 0
  out.setup = gpuSetup(out)
  return out
}

// Derive the panel-facing setup guidance from a parsed GPU state. Returns a
// { title, lines:[..] } describing what to do when the sampler isn't ready.
function gpuSetup(gpu) {
  var lines = []
  if (!gpu) return { title: "GPU unavailable", lines: ["No GPU data."] }
  if (gpu.status === "ok") return { title: "", lines: [] }
  if (gpu.status === "no-gpu") {
    return { title: "No GPU detected",
             lines: ["No GPU could be found on this system.",
                     "The GPU panel needs a supported graphics adapter."] }
  }
  if (gpu.status === "no-tool" || gpu.status === "no-perm") {
    // One setup action covers both: the helper installs the tool AND grants
    // the permission it needs, so there's no separate permission diagnostic.
    return { title: "Setup needed",
             lines: ["Tap Install GPU Helper below to finish one-time setup."] }
  }
  // status === "error": tool present but produced nothing usable
  return { title: "Something went wrong",
           lines: ["Tap Install GPU Helper below to fix it automatically."] }
}

// Map a vendor tag to its helper tool, package(s) and verify command. Kept
// here (not in gpu.sh) so the panel can render friendly guidance and so the
// hint is unit-testable.
function gpuToolFor(vendor) {
  switch (String(vendor || "").toLowerCase()) {
    case "intel":
      return { tool: "intel_gpu_top", pkg: "intel-gpu-tools", pkgs: ["intel-gpu-tools"],
               install: "sudo pacman -S intel-gpu-tools",
               verify: "intel_gpu_top -J   (Ctrl-C to stop)" }
    case "nvidia":
      return { tool: "nvidia-smi", pkg: "nvidia-utils", pkgs: ["nvidia-utils"],
               install: "sudo pacman -S nvidia-utils",
               verify: "nvidia-smi --query-gpu=name" }
    case "amd":
      return { tool: "rocm-smi", pkg: "rocm-smi-lib", pkgs: ["rocm-smi-lib", "radeontop"],
               install: "sudo pacman -S rocm-smi-lib   (or: sudo pacman -S radeontop)",
               verify: "rocm-smi --showuse" }
    default:
      return { tool: "", pkg: "", pkgs: [], install: "", verify: "" }
  }
}

// Format a MiB value as a human size (e.g. "512M", "7.5G"). Returns "--" out
// of range / for "not available" (-1).
function formatBytes(mib) {
  var v = parseFloat(mib)
  if (!isFinite(v) || v < 0) return "--"
  if (v >= 1024) return (Math.round(v / 102.4) / 10) + "G"
  return Math.round(v) + "M"
}

// Format a temperature as "NN°C", or "--" when not available.
function formatTemp(celsius) {
  var v = parseFloat(celsius)
  if (!isFinite(v) || v < 0) return "--"
  return Math.round(v) + "°C"
}

// ============================ DISK / I/O =================================
// Parses the tab-separated output of disk.sh into a single object the panel
// binds to. disk.sh emits (mirroring cpu.sh's shape):
//   mount\t<path>
//   fsTotal\t<bytes>
//   fsFree\t<bytes>
//   fsUsed\t<bytes>
//   fsUsePct\t<percent>
//   read\t<KB/s>       aggregate disk read rate
//   write\t<KB/s>      aggregate disk write rate
//   proc\t<pid>\t<readKB/s>\t<writeKB/s>\t<comm>   top by read+write, desc
// Returns { mount, fsTotal, fsFree, fsUsed, fsUsePct, read, write, ready,
//           procs:[{pid,read,write,comm}] }.
// `ready` is true when at least a read/write sample was produced.
function parseDiskOutput(raw) {
  var lines = String(raw || "").split("\n")
  var out = { mount: "", fsTotal: -1, fsFree: -1, fsUsed: -1, fsUsePct: -1,
              read: -1, write: -1, ready: false, procs: [] }
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    var v
    if (kind === "mount") out.mount = String(parts[1] || "")
    else if (kind === "fsTotal") { v = parseFloat(parts[1]); if (isFinite(v)) out.fsTotal = v }
    else if (kind === "fsFree") { v = parseFloat(parts[1]); if (isFinite(v)) out.fsFree = v }
    else if (kind === "fsUsed") { v = parseFloat(parts[1]); if (isFinite(v)) out.fsUsed = v }
    else if (kind === "fsUsePct") { v = parseFloat(parts[1]); if (isFinite(v)) out.fsUsePct = Math.round(v * 10) / 10 }
    else if (kind === "read") { v = parseFloat(parts[1]); if (isFinite(v)) out.read = Math.round(v * 10) / 10 }
    else if (kind === "write") { v = parseFloat(parts[1]); if (isFinite(v)) out.write = Math.round(v * 10) / 10 }
    else if (kind === "proc") {
      var r = parseFloat(parts[2] || "")
      var w = parseFloat(parts[3] || "")
      if (isFinite(r) && isFinite(w))
        out.procs.push({ pid: String(parts[1] || "").trim(),
                         read: Math.round(r * 10) / 10, write: Math.round(w * 10) / 10,
                         comm: String(parts[4] || "").trim() })
    }
  }
  out.ready = out.read >= 0 && out.write >= 0
  return out
}

// History ring buffer for the I/O graph. Appends {time, read, write} and drops
// anything older than `maxSeconds` — the dual-axis read/write analogue of
// appendHistory.
function appendIoHistory(history, nowSeconds, readKBs, writeKBs, maxSeconds) {
  var h = Array.isArray(history) ? history.slice() : []
  var max = Math.max(1, parseInt(maxSeconds, 10) || 3600)
  h.push({ time: Number(nowSeconds) || 0, read: Number(readKBs) || 0, write: Number(writeKBs) || 0 })
  var cutoff = (Number(nowSeconds) || 0) - max
  while (h.length > 0 && h[0].time < cutoff) h.shift()
  return h
}

// streaming timeline analogue of scrollWindow for two values per sample.
// Returns exactly `buckets` {read, write} columns, NEWEST pinned at the far
// right; empty leading columns are 0. Pure and node-testable.
function scrollIoWindow(history, buckets) {
  var h = Array.isArray(history) ? history : []
  var n = Math.max(1, parseInt(buckets, 10) || 1)
  var fill = Math.min(n, h.length)
  var start = h.length - fill
  var out = []
  for (var i = 0; i < n; i++) out.push({ read: 0, write: 0 })
  for (var k = 0; k < fill; k++) {
    var e = h[start + k]
    out[n - fill + k] = { read: Number(e.read) || 0, write: Number(e.write) || 0 }
  }
  return out
}

// Normalize an io window (list of {read, write}) to 0..1 against the SHARED
// max of read and write, so the two bars of a column are comparable and the
// plot doesn't rescale every tick. Empty/zero window -> 0.
function normalizeIo(ioWindow) {
  var v = Array.isArray(ioWindow) ? ioWindow : []
  var max = 0
  for (var i = 0; i < v.length; i++) {
    var r = Math.abs(Number(v[i].read) || 0)
    var w = Math.abs(Number(v[i].write) || 0)
    if (r > max) max = r
    if (w > max) max = w
  }
  if (max <= 0) max = 1
  var out = []
  for (var j = 0; j < v.length; j++)
    out.push({ read: (Number(v[j].read) || 0) / max, write: (Number(v[j].write) || 0) / max })
  return out
}

// Keep the newest `limit` I/O rows. disk.sh sends all processes that did any
// I/O, sorted desc by read+write; this caps to the configured number and
// drops purely-idle rows.
function topIoRows(procs, limit) {
  var rows = Array.isArray(procs) ? procs : []
  var n = Math.max(1, parseInt(limit, 10) || rows.length)
  var trimmed = rows.slice(0, Math.min(n, rows.length))
  return trimmed.filter(function(p) {
    var r = Number(p && p.read) || 0
    var w = Number(p && p.write) || 0
    return (r > 0 || w > 0) || String(p && p.comm || "") !== ""
  })
}

// Format a byte count as a compact disk size for the two-line bar item, e.g.
// "50GB", "8.2GB". Returns "--" out of range / not available.
function formatGb(bytes) {
  var v = parseFloat(bytes)
  if (!isFinite(v) || v < 0) return "--"
  var gb = v / (1024 * 1024 * 1024)
  if (gb >= 99.95) return Math.round(gb) + "GB"
  return (Math.round(gb * 10) / 10) + "GB"
}

// Format a throughput given in KB/s as a human rate: "512K/s", "3.4M/s",
// "850B/s". Returns "--" for not available / negative.
function formatRate(kb) {
  var v = parseFloat(kb)
  if (!isFinite(v) || v < 0) return "--"
  if (v >= 1024) return (Math.round(v / 10.24) / 100) + "M/s"
  if (v >= 1) return Math.round(v) + "K/s"
  return Math.round(v * 1024) + "B/s"
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
    formatPct: formatPct,
    parseGpuOutput: parseGpuOutput,
    gpuSetup: gpuSetup,
    gpuToolFor: gpuToolFor,
    formatBytes: formatBytes,
    formatTemp: formatTemp,
    parseDiskOutput: parseDiskOutput,
    appendIoHistory: appendIoHistory,
    scrollIoWindow: scrollIoWindow,
    normalizeIo: normalizeIo,
    topIoRows: topIoRows,
    formatGb: formatGb,
    formatRate: formatRate
  }
}
