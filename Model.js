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

// PSI percentages can be far below 1% (e.g. 0.09%) and the kernel only reports
// them to 2 decimals — a whole-percent round would show a misleading "0%".
// Add precision in the range where it matters: integers above 10%, one decimal
// between 1..10%, and two decimals below 1% so a real 0.09% stall is visible.
function formatPsiPct(value) {
  var v = parseFloat(value)
  if (!isFinite(v) || v < 0) return "--"
  if (v >= 10) return Math.round(v) + "%"
  if (v >= 1) return (Math.round(v * 10) / 10) + "%"
  return (Math.round(v * 100) / 100) + "%"
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

// Format a KiB value as a compact memory size for the RAM dropdown's
// distribution section, e.g. "2.3GB", "512.0MB". Returns "--" out of range.
function formatRamSize(kib) {
  var v = parseFloat(kib)
  if (!isFinite(v) || v < 0) return "--"
  var mb = v / 1024          // KiB -> MiB
  if (mb >= 1024) {
    var gb = mb / 1024
    return (Math.round(gb * 10) / 10) + "GB"
  }
  return Math.round(mb) + "MB"
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

// Format a per-process RSS (in MiB) as "NNNMB", or "x.xGB" once it crosses a
// GiB, for the top-memory-process table. Returns "--" out of range.
function formatRss(mib) {
  var v = parseFloat(mib)
  if (!isFinite(v) || v < 0) return "--"
  if (v >= 1024) return (Math.round(v / 10.24) / 100) + "GB"
  return Math.round(v) + "MB"
}

// ============================ NETWORK =====================================
// Parses the tab-separated output of net.sh into a single object the panel
// binds to. net.sh emits:
//   iface / type / mac / ssid / ip / gateway / connected / online
//   pingMs / publicIp
//   down<KB/s> / up<KB/s>       aggregate download / upload rate
//   totalDown / totalUp         lifetime bytes (boot)
//   proc\t<pid>\t<upKB/s>\t<downKB/s>\t<comm>
// Returns { iface, type, mac, ssid, ip, gateway, connected, online, pingMs,
//           publicIp, down, up, totalDown, totalUp, ready,
//           procs:[{pid,up,down,comm}] }.
// `ready` is true when aggregate rates parsed (i.e. an active interface).
// `pingMs` is -1 when no ping has succeeded yet; `online`/`publicIp` come from
// the throttled probe and may lag a tick behind the rates.
function parseNetworkOutput(raw) {
  var lines = String(raw || "").split("\n")
  var out = { iface: "", type: "unknown", mac: "", ssid: "", ip: "", gateway: "",
              connected: false, online: false, pingMs: -1, publicIp: "",
              down: -1, up: -1, totalDown: -1, totalUp: -1, ready: false, procs: [] }
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    if (kind === "iface") out.iface = String(parts[1] || "")
    else if (kind === "type") out.type = String(parts[1] || "unknown")
    else if (kind === "mac") out.mac = String(parts[1] || "")
    else if (kind === "ssid") out.ssid = String(parts[1] || "")
    else if (kind === "ip") out.ip = String(parts[1] || "")
    else if (kind === "gateway") out.gateway = String(parts[1] || "")
    else if (kind === "connected") out.connected = parts[1] === "1"
    else if (kind === "online") out.online = parts[1] === "1"
    else if (kind === "pingMs") { var pm = parseFloat(parts[1]); out.pingMs = isFinite(pm) && pm >= 0 ? pm : -1 }
    else if (kind === "publicIp") out.publicIp = String(parts[1] || "")
    else if (kind === "down") { var dn = parseFloat(parts[1]); if (isFinite(dn)) out.down = Math.round(dn * 10) / 10 }
    else if (kind === "up") { var up = parseFloat(parts[1]); if (isFinite(up)) out.up = Math.round(up * 10) / 10 }
    else if (kind === "totalDown") { var td = parseFloat(parts[1]); if (isFinite(td)) out.totalDown = td }
    else if (kind === "totalUp") { var tu = parseFloat(parts[1]); if (isFinite(tu)) out.totalUp = tu }
    else if (kind === "proc") {
      var pu = parseFloat(parts[2] || ""); var pd = parseFloat(parts[3] || "")
      if (isFinite(pu) && isFinite(pd))
        out.procs.push({ pid: String(parts[1] || "").trim(), up: Math.round(pu * 10) / 10,
                         down: Math.round(pd * 10) / 10, comm: String(parts[4] || "").trim() })
    }
  }
  out.ready = out.down >= 0 && out.up >= 0
  return out
}

// History ring buffer for the network graph. Appends {time, down, up} and
// drops anything older than `maxSeconds` — the dual-axis down/up analogue of
// appendIoHistory.
function appendNetHistory(history, nowSeconds, downKBs, upKBs, maxSeconds) {
  var h = Array.isArray(history) ? history.slice() : []
  var max = Math.max(1, parseInt(maxSeconds, 10) || 3600)
  h.push({ time: Number(nowSeconds) || 0, down: Number(downKBs) || 0, up: Number(upKBs) || 0 })
  var cutoff = (Number(nowSeconds) || 0) - max
  while (h.length > 0 && h[0].time < cutoff) h.shift()
  return h
}

// streaming timeline analogue of scrollIoWindow for the down/up pair. Returns
// exactly `buckets` {down, up} columns, NEWEST pinned at the far right; empty
// leading columns are 0. Pure and node-testable.
function scrollNetWindow(history, buckets) {
  var h = Array.isArray(history) ? history : []
  var n = Math.max(1, parseInt(buckets, 10) || 1)
  var fill = Math.min(n, h.length)
  var start = h.length - fill
  var out = []
  for (var i = 0; i < n; i++) out.push({ down: 0, up: 0 })
  for (var k = 0; k < fill; k++) {
    var e = h[start + k]
    out[n - fill + k] = { down: Number(e.down) || 0, up: Number(e.up) || 0 }
  }
  return out
}

// Normalize a net window (list of {down, up}) to 0..1 against the SHARED max
// of down and up, so the two bars of a column are comparable and the plot
// doesn't rescale every tick. Empty/zero window -> 0.
function normalizeNet(netWindow) {
  var v = Array.isArray(netWindow) ? netWindow : []
  var max = 0
  for (var i = 0; i < v.length; i++) {
    var d = Math.abs(Number(v[i].down) || 0); var u = Math.abs(Number(v[i].up) || 0)
    if (d > max) max = d; if (u > max) max = u
  }
  if (max <= 0) max = 1
  var out = []
  for (var j = 0; j < v.length; j++)
    out.push({ down: (Number(v[j].down) || 0) / max, up: (Number(v[j].up) || 0) / max })
  return out
}

// Keep the newest `limit` network rows. net.sh sends every TCP socket that
// moved in the window, already sorted desc by up+down; this caps to the
// configured number and drops purely-idle rows.
function topNetProcs(procs, limit) {
  var rows = Array.isArray(procs) ? procs : []
  var n = Math.max(1, parseInt(limit, 10) || rows.length)
  var trimmed = rows.slice(0, Math.min(n, rows.length))
  return trimmed.filter(function(p) {
    var u = Number(p && p.up) || 0; var d = Number(p && p.down) || 0
    return (u > 0 || d > 0) || String(p && p.comm || "") !== ""
  })
}

// Format a throughput in KB/s as the bar/table reads it, e.g. "27KB/s",
// "1.5MB/s", "512B/s". Returns "--" for not available / negative.
function formatNetRate(kb) {
  var v = parseFloat(kb)
  if (!isFinite(v) || v < 0) return "--"
  if (v >= 1024 * 1024) return (Math.round(v / 10.24) / 100) + "GB/s"
  if (v >= 1024) return (Math.round(v / 10.24) / 100) + "MB/s"
  if (v >= 1) return Math.round(v) + "KB/s"
  return Math.round(v * 1024) + "B/s"
}

// Format a cumulative byte total (lifetime down/up) as "123MB" or, once it
// crosses a GiB, "1.5GB". Returns "--" out of range / not available.
function formatNetTotal(bytes) {
  var v = parseFloat(bytes)
  if (!isFinite(v) || v < 0) return "--"
  var gb = v / (1024 * 1024 * 1024)
  if (gb >= 1) return (Math.round(gb * 10) / 10) + "GB"
  return Math.round(v / (1024 * 1024)) + "MB"
}

// ============================ RAM / SWAP ==================================
// Parses the tab-separated output of ram.sh into a single object the panel
// binds to. ram.sh emits (all KiB):
//   total / free / available / used / system / buffers / cached / shared
//   swapTotal / swapUsed / swapCached
//   psiSome10 / psiFull10            (PSI memory pressure %, 10s window)
//   proc\t<pid>\t<rssKiB>\t<name>
// `used` excludes the reclaimable page cache (that's `system`), so
// used + system + free == total. Returns { total, free, available, used,
// system, swapTotal, swapUsed, psiSome10, psiFull10, ready,
// procs:[{pid,rss,comm}] }.
function parseRamOutput(raw) {
  var lines = String(raw || "").split("\n")
  var out = { total: -1, free: -1, available: -1, used: -1, system: -1,
              buffers: -1, cached: -1, shared: -1,
              swapTotal: -1, swapUsed: -1, swapCached: -1,
              psiSome10: -1, psiFull10: -1,
              ready: false, procs: [] }
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    function rd() { var x = parseFloat(parts[1]); return isFinite(x) ? x : -1 }
    if (kind === "total") out.total = rd()
    else if (kind === "free") out.free = rd()
    else if (kind === "available") out.available = rd()
    else if (kind === "used") out.used = rd()
    else if (kind === "system") out.system = rd()
    else if (kind === "buffers") out.buffers = rd()
    else if (kind === "cached") out.cached = rd()
    else if (kind === "shared") out.shared = rd()
    else if (kind === "swapTotal") out.swapTotal = rd()
    else if (kind === "swapUsed") out.swapUsed = rd()
    else if (kind === "swapCached") out.swapCached = rd()
    else if (kind === "psiSome10") out.psiSome10 = rd()
    else if (kind === "psiFull10") out.psiFull10 = rd()
    else if (kind === "proc") {
      var rss = parseFloat(parts[2] || "")
      if (isFinite(rss))
        out.procs.push({ pid: String(parts[1] || "").trim(), rss: Math.round(rss),
                         comm: String(parts[3] || "").trim() })
    }
  }
  out.ready = out.total > 0
  return out
}

// ============================ BATTERY / POWER =============================
// Parses the tab-separated output of battery.sh into a single object the panel
// binds to. battery.sh emits:
//   present / state / ac / pct / voltage / current (mA) / power (W signed)
//   energy / energyFull / energyFullDesign (Wh) / health / cycles / temp (°C)
//   timeToFull / timeToEmpty (seconds) / model
//   proc\t<pid>\t<pct>\t<comm>   top CPU processes (battery-drain proxy)
// Returns { present, state, ac, pct, voltage, current, power, energy,
//           energyFull, energyFullDesign, health, cycles, temp,
//           timeToFull, timeToEmpty, model, charging, discharging, ready,
//           procs:[{pid,pct,comm}] }.
// `charging`/`discharging` are derived booleans so the panel doesn't string-match
// on `state`; `ready` is true once a present battery has a level parsed.
function parseBatteryOutput(raw) {
  var lines = String(raw || "").split("\n")
  var out = { present: false, state: "unknown", ac: false, pct: -1,
              voltage: -1, current: 0, power: 0,
              energy: -1, energyFull: -1, energyFullDesign: -1,
              health: -1, cycles: -1, temp: -1,
              timeToFull: 0, timeToEmpty: 0, model: "",
              charging: false, discharging: false, ready: false, procs: [] }
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var kind = parts[0]
    if (kind === "present") { out.present = parts[1] === "1" }
    else if (kind === "state") out.state = String(parts[1] || "unknown")
    else if (kind === "ac") { out.ac = parts[1] === "1" }
    else if (kind === "pct") { var p = parseFloat(parts[1]); if (isFinite(p)) out.pct = Math.round(p) }
    else if (kind === "voltage") { var v = parseFloat(parts[1]); if (isFinite(v)) out.voltage = v }
    else if (kind === "current") { var c = parseFloat(parts[1]); if (isFinite(c)) out.current = Math.round(c) }
    else if (kind === "power") { out.power = parseFloat(parts[1]) }
    else if (kind === "energy") { var e = parseFloat(parts[1]); if (isFinite(e)) out.energy = e }
    else if (kind === "energyFull") { var ef = parseFloat(parts[1]); if (isFinite(ef)) out.energyFull = ef }
    else if (kind === "energyFullDesign") { var ed = parseFloat(parts[1]); if (isFinite(ed)) out.energyFullDesign = ed }
    else if (kind === "health") { var h = parseFloat(parts[1]); if (isFinite(h)) out.health = h }
    else if (kind === "cycles") { var cy = parseFloat(parts[1]); if (isFinite(cy)) out.cycles = cy }
    else if (kind === "temp") { var tp = parseFloat(parts[1]); if (isFinite(tp)) out.temp = tp }
    else if (kind === "timeToFull") { var ttf = parseFloat(parts[1]); if (isFinite(ttf)) out.timeToFull = ttf }
    else if (kind === "timeToEmpty") { var tte = parseFloat(parts[1]); if (isFinite(tte)) out.timeToEmpty = tte }
    else if (kind === "model") out.model = String(parts[1] || "").trim()
    else if (kind === "proc") {
      var pp = parseFloat(parts[2] || "")
      if (isFinite(pp))
        out.procs.push({ pid: String(parts[1] || "").trim(), pct: Math.round(pp * 10) / 10,
                         comm: String(parts[3] || "").trim() })
    }
  }
  out.charging = out.state === "charging"
  out.discharging = out.state === "discharging"
  // Sanity: only trust numbers that actually parsed as positives. `ready` means
  // a battery is present and we got a level (>= 0); a missing battery stays not
  // ready so the panel can show a graceful empty state rather than "-1%".
  out.ready = out.present && out.pct >= 0
  return out
}

// Keep the newest `limit` battery-process rows (top CPU consumers, the drain
// proxy — battery.sh already sorts desc by %). Mirrors topProcRows.
function topBatteryProcs(procs, limit) {
  var rows = Array.isArray(procs) ? procs : []
  var n = Math.max(1, parseInt(limit, 10) || rows.length)
  var trimmed = rows.slice(0, Math.min(n, rows.length))
  return trimmed.filter(function(p) {
    var v = Number(p && p.pct)
    return (isFinite(v) && v > 0) || String(p && p.comm || "") !== ""
  })
}

// Format a duration in seconds as "H:MM", e.g. 7540s -> "2:06". Minutes round
// to the nearest so a partial minute is visible (59s -> "0:01", 3601s ->
// "1:00"). Returns "--" for zero / not available so a full or idle battery
// shows a dash rather than "0:00".
function formatBatteryTime(seconds) {
  var s = Math.round(parseFloat(seconds))
  if (!isFinite(s) || s <= 0) return "--"
  var h = Math.floor(s / 3600)
  var m = Math.round((s % 3600) / 60)
  if (m === 60) { m = 0; h = h + 1 }
  return String(h) + ":" + (m < 10 ? "0" : "") + m
}

// Format battery watts, signed (positive = charging rate, negative = discharge
// draw): "12.4W", showing sign only for discharge. Returns "--" out of range.
function formatWatts(watts) {
  var v = parseFloat(watts)
  if (!isFinite(v)) return "--"
  var a = Math.abs(v)
  var s = a >= 100 ? Math.round(a) + "W" : (Math.round(a * 10) / 10) + "W"
  return v < 0 ? "-" + s : s
}

// Format battery current in milliamps: "512mA", or amps once it crosses 1A.
// Returns "--" for not available.
function formatMillis(ma) {
  var v = parseFloat(ma)
  if (!isFinite(v)) return "--"
  var a = Math.abs(v)
  var s = a >= 1000 ? (Math.round(a / 100) / 10) + "A" : Math.round(a) + "mA"
  return v < 0 ? "-" + s : s
}

// Format a wall-clock battery % that also doubles as a charge icon tier. Kept
// simple: returns the integer percent, matching formatPct but battery-specific
// so the bar can show it plainly without the "-1" edge leaking through.
function batteryPctText(pct) {
  var v = parseFloat(pct)
  if (!isFinite(v) || v < 0) return "--"
  return Math.round(v) + "%"
}

// ============================ BATTERY ICONS ==============================
// Omarchy's battery icon set (copied byte-for-byte from omarchy.power's
// panels/power/Model.js). Two parallel 10-tier Material Design battery glyph
// arrays; pick by charge tier and charging state, exactly like omarchy does:
//   - defaultIcons  : plain filled battery, drains as charge drops (0..9)
//   - chargingIcons : same tiers with a plug/bolt drawn INSIDE the battery,
//                     used while charging so the bolt is part of the icon
// index = clamp(floor(pct/10), 0, 9) — a higher tier = a fuller battery.
var batteryDefaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
var batteryChargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]

function batteryIcon(pct, charging) {
  var v = Number(pct)
  if (!isFinite(v) || v < 0) v = 0
  var index = Math.max(0, Math.min(9, Math.floor(v / 10)))
  return (charging ? batteryChargingIcons : batteryDefaultIcons)[index]
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
    formatPsiPct: formatPsiPct,
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
    formatRate: formatRate,
    formatRamSize: formatRamSize,
    formatRss: formatRss,
    parseNetworkOutput: parseNetworkOutput,
    appendNetHistory: appendNetHistory,
    scrollNetWindow: scrollNetWindow,
    normalizeNet: normalizeNet,
    topNetProcs: topNetProcs,
    formatNetRate: formatNetRate,
    formatNetTotal: formatNetTotal,
    parseRamOutput: parseRamOutput,
    batteryIcon: batteryIcon,
    parseBatteryOutput: parseBatteryOutput,
    topBatteryProcs: topBatteryProcs,
    formatBatteryTime: formatBatteryTime,
    formatWatts: formatWatts,
    formatMillis: formatMillis,
    batteryPctText: batteryPctText
  }
}
