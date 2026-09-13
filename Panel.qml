import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// obi.stats — a row of clickable system-stat bar items (CPU, GPU, disk,
// RAM, battery, network). Clicking an item opens a dropdown anchored to that
// item, styled like the network/audio dropdowns.
//
// This file is the bar-widget entry point (see manifest.json) AND the host
// for the dropdown, mirroring omarchy.network: one Panel that paints its own
// bar widgets and pops up its own KeyboardPanel.
//
// CPU is wired up end to end: a periodic Process samples cpu.sh, the result is
// shown as an aggregate %, per-core bars, the top-N heavy processes, and a
// configurable history graph. Disk is wired too: a two-line F:/U: bar item plus
// a dropdown with a dual-axis read/write I/O history and top I/O processes.
// RAM is wired too: a two-line "ram / NN%" bar item plus a dropdown with a
// memory-pressure speedometer, usage history, a user/system/free/swap
// distribution, and top memory processes. Battery is wired too: a one-line
// "HH:MM  <icon>NN%" bar item plus a dropdown with a big charge icon, power
// details (W / mA / V / health / cycles / temp) and top processes. Network is
// wired too: a two-line down/up rate bar item plus a dropdown with a dual-axis
// download/upload history, aggregate totals, connection details (internet
// state / ping / interface / MAC / SSID / local+public IP) and top processes
// by network.
//
// Per-widget settings come from the shell.json entry (see `setting()`), e.g.:
//   topProcesses       default 8     how many heavy processes to list (CPU)
//   refreshSeconds     default 2     base sample cadence (CPU + GPU + disk)
//   cpuRefreshSeconds  default base  CPU poll period, independent override
//   gpuRefreshSeconds  default base  GPU poll period, independent override
//   fileioRefreshSeconds default base  disk I/O poll period, independent override
//   batteryRefreshSeconds default base  battery poll period, independent override
//   diskMount          default /     filesystem monitored for space
//   diskTopProcesses   default 5     rows in the disk top-I/O table
//   topBatteryProcesses default 5    rows in the battery top-processes table
//   batteryAlarmPct    default 20    battery % below which it's alarming
//   batteryMildPct     default 60    above which it's calm (mild in between)
//   networkRefreshSeconds default base  network poll period, independent override
//   networkTopProcesses default 5    rows in the network top-processes table
//   networkProbeSeconds default 10   seconds between public-IP HTTP probes
//   networkPingHost     default 1.1.1.1  internet probe (ping/public-IP) host
//   historyMinutes     default 60    length of the usage-history window
// Set them with: omarchy bar set obi.stats <key> <value>
Panel {
  id: root
  moduleName: "obi.stats"
  ipcTarget: "obi.stats"
  manageIpc: false

  // The ordered list of stats (pure data, in Model.js).
  readonly property var defs: Model.statDefinitions()

  // Vertical separator drawn between stats. Uses the workspace active-indicator
  // color (bar.urgent == Color.bar.active) and sits vertically centred in the
  // bar slot.
  readonly property int separatorWidth: Style.space(2)
  readonly property int separatorHeight: Style.space(8)
  readonly property color separatorColor: root.bar ? root.bar.urgent : Color.bar.active

  // ---- Dropdown state ---------------------------------------------------
  property var activeStat: null
  property var activeButton: null

  // Id -> BarIconButton, filled during construction so any stat can be opened
  // by id (bar click, hotkey IPC, summon payload). Used to anchor the panel.
  property var statButtons: ({})
  function registerBarButton(id, button) {
    root.statButtons[String(id)] = button
  }

  readonly property color cpuText: bar ? bar.foreground : Color.foreground
  readonly property color cpuDim: Qt.darker(cpuText, 1.4)
  readonly property color cpuData: Style.selectedStateColor(cpuText, Color.accent)

  // Subtle top-corner radius for bars: square bottom, slight rounding on top
  // (Rectangle.radius always rounds all corners, so keep it small and uniform).
  readonly property int cornerTiny: Math.max(1, Math.min(4, Style.cornerRadius > 0 ? Style.space(2) : 0))

  // ---- CPU config -------------------------------------------------------
  readonly property string cpuScript: root.pluginDir + "/cpu.sh"
  readonly property string gpuScript: root.pluginDir + "/gpu.sh"
  readonly property string diskScript: root.pluginDir + "/disk.sh"
  readonly property string ramScript: root.pluginDir + "/ram.sh"
  readonly property string batteryScript: root.pluginDir + "/battery.sh"
  readonly property string sampleScript: root.pluginDir + "/sample.sh"
  readonly property string procsScript: root.pluginDir + "/procs.sh"
  readonly property string netScript: root.pluginDir + "/net.sh"
  // Resolve from the manifest id (moduleName), not a hardcoded folder, so the
  // script path is correct however Omarchy installed the plugin — `plugins/<id>/`.
  readonly property string pluginDir:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName
  readonly property int topProcesses: Math.max(1, parseInt(setting("topProcesses", 8), 10) || 8)
  // Base refresh cadence; each stat can override with its own key:
  //   cpuRefreshSeconds (defaults to refreshSeconds)
  //   gpuRefreshSeconds (defaults to refreshSeconds)
  // This lets a user poll stats independently, e.g. CPU every 1s, GPU every 5s.
  readonly property int refreshSeconds: Math.max(1, parseInt(setting("refreshSeconds", 2), 10) || 2)
  readonly property int cpuRefreshSeconds: Math.max(1, parseInt(setting("cpuRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  readonly property int gpuRefreshSeconds: Math.max(1, parseInt(setting("gpuRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  // Disk I/O poll cadence — independent of the space stat they're one sampler,
  // so this one cadence drives both (defaults to refreshSeconds).
  readonly property int fileioRefreshSeconds: Math.max(1, parseInt(setting("fileioRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  // Filesystem the disk bar/dropdown monitor for space (e.g. "/", "/home").
  readonly property string diskMount: setting("diskMount", "/")
  // Rows in the disk "top I/O processes" table (independent of CPU topProcesses).
  readonly property int diskTopProcesses: Math.max(1, parseInt(setting("diskTopProcesses", 5), 10) || 5)
  // RAM polls the same meminfo/status snapshot each tick; this is its poll
  // period (defaults to refreshSeconds). No sample window is needed: meminfo
  // and per-process RSS are instantaneous /proc reads.
  readonly property int ramRefreshSeconds: Math.max(1, parseInt(setting("ramRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  // Rows in the RAM "top memory processes" table.
  readonly property int topRamProcesses: Math.max(1, parseInt(setting("topRamProcesses", 5), 10) || 5)
  // Skip entries using less than this many MB of RAM in the top-memory table,
  // so the list isn't dominated by hundreds of tiny processes.
  readonly property int ramMinProcessMB: Math.max(0, parseInt(setting("ramMinProcessMB", 5), 10) || 5)
  // Battery polls the ACPI power-supply tree /sys each tick (instantaneous
  // reads like RAM — no sample window). This is its poll period (defaults to
  // refreshSeconds). The per-process drain sample inside battery.sh uses a
  // fraction of this as its own window.
  readonly property int batteryRefreshSeconds: Math.max(1, parseInt(setting("batteryRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  // Rows in the battery "top processes" table (drain proxy = top CPU consumers).
  readonly property int topBatteryProcesses: Math.max(1, parseInt(setting("topBatteryProcesses", 5), 10) || 5)
  // Battery-charge % tint thresholds — reversed from the usage tiers because a
  // LOW charge is the alarming end. Below batteryAlarmPct = alarming (urgent),
  // up to batteryMildPct = mild (accent), at/above batteryMildPct = calm.
  readonly property int batteryAlarmPct: Math.max(1, parseInt(setting("batteryAlarmPct", 20), 10) || 20)
  readonly property int batteryMildPct: Math.max(1, parseInt(setting("batteryMildPct", 60), 10) || 60)
  // Network polls the aggregate rates each tick (a short two-sample window,
  // like disk I/O); the slow internet probes (ping / online / public IP) run
  // on their own throttled cadence inside net.sh, kept independent of this.
  readonly property int networkRefreshSeconds: Math.max(1, parseInt(setting("networkRefreshSeconds", root.refreshSeconds), 10) || root.refreshSeconds)
  // Rows in the network "top processes" table.
  readonly property int networkTopProcesses: Math.max(1, parseInt(setting("networkTopProcesses", 5), 10) || 5)
  // Seconds between public-IP HTTP probes. Ping (online + latency) runs every
  // tick, so this only throttles the external curl — set it higher if you use a
  // metered link.
  readonly property int networkProbeSeconds: Math.max(3, parseInt(setting("networkProbeSeconds", 10), 10) || 10)
  // Internet probe host (ping target + public-IP sanity route).
  readonly property string networkPingHost: setting("networkPingHost", "1.1.1.1")
  readonly property int historySeconds: Math.max(30, parseInt(setting("historyMinutes", 60), 10) || 60) * 60

  // Usage tint thresholds, as percent. Settings (e.g. `omarchy bar set
  // obi.stats mildThreshold 40`) tune them without touching code.
  readonly property int calmLimit: Math.max(1, parseInt(setting("calmLimit", 30), 10) || 30)
  readonly property int mildLimit: Math.max(1, parseInt(setting("mildLimit", 60), 10) || 60)

  // Theme-cohesive usage color. Maps to the three semantic roles every theme
  // defines in colors.toml — foreground / accent / urgent — so it adapts to
  // catppuccin, latte, ethereal, dark and light alike:
  //   < calmLimit  -> foreground (calm; theme text)
  //   calmLimit..mildLimit -> accent (mild; theme highlight)
  //   >= mildLimit -> urgent (alarming; theme alarm)
  function usageColor(percent) {
    var v = Number(percent) || 0
    if (v >= root.mildLimit) return Color.urgent
    if (v >= root.calmLimit) return Color.accent
    return root.cpuText
  }

  // Disk-space bar value tints (percent 0..100), per the requested table
  // (calmLimit/mildLimit, default 30/60). Free = higher is better; Used =
  // lower is better:
  //   free (higher better):  >= mildLimit calm, calmLimit..<mildLimit mild, < calmLimit urgent
  //   used (lower better):   < calmLimit calm, calmLimit..<=mildLimit mild, > mildLimit urgent
  function diskFreeColor(percent) {
    var v = Number(percent) || 0
    if (v >= root.mildLimit) return root.cpuText
    if (v >= root.calmLimit) return Color.accent
    return Color.urgent
  }
  function diskUsedColor(percent) {
    var v = Number(percent) || 0
    if (v > root.mildLimit) return Color.urgent
    if (v < root.calmLimit) return root.cpuText
    return Color.accent
  }

  // Battery-charge tint. Reversed polarity vs the usage tiers: a LOW charge is
  // the alarming end, so below batteryAlarmPct (default 20) is urgent, mild up
  // to batteryMildPct (default 60), calm at/above that.
  function batteryColor(percent) {
    var v = Number(percent) || 0
    if (v < root.batteryAlarmPct) return Color.urgent
    if (v < root.batteryMildPct) return Color.accent
    return root.cpuText
  }

  // Battery HEALTH tint. Unlike charge %, a HIGHER health is better, so the
  // polarity is the same as the usage tiers: >= 80% calm, 50–80 mild, < 50
  // alarming.
  function batteryHealthColor(percent) {
    var v = Number(percent) || 0
    if (v >= 80) return root.cpuText
    if (v >= 50) return Color.accent
    return Color.urgent
  }

  // ---- CPU state --------------------------------------------------------
  property var cpuState: ({ total: 0, cores: [], procs: [] })
  property var cpuHistory: []
  property bool cpuPolling: false

  readonly property var cpuTopProcs: Model.topProcRows(cpuState.procs, topProcesses)
  readonly property var cpuCoreHeights: Model.normalize(
    (function() { var v = []; for (var i = 0; i < cpuState.cores.length; i++) v.push(cpuState.cores[i].pct); return v })(),
    100
  )
  readonly property int historyBuckets: Math.max(8, Math.floor((root.contentWidthEstimate - Style.space(32)) / (Style.space(3) + Style.space(1))))
  // One real sample per column, newest anchored right, shifting left each tick.
  readonly property var cpuGraph: (root.activeStat && root.activeStat.id === "cpu") ? Model.scrollWindow(cpuHistory, historyBuckets) : []
  // Constant 0..100% axis (not max-scaled) so the timeline reads as a stable,
  // scrolling chart rather than rescaling every refresh.
  readonly property var cpuGraphHeights: Model.normalize(cpuGraph, 100)
  readonly property int contentWidthEstimate: Style.space(360)

  // ---- GPU state -------------------------------------------------------
  // Mirrors cpuState, but with extra fields from the vendor-agnostic sampler:
  // vendor allows vendor-specific upgrade prompts, temp/mem are live when the
  // backend exposes them, engines hold per-engine utilization and procs hold
  // top GPU processes by memory. `setup` carries doctor-style guidance when
  // the sampler isn't ready (no tool / no GPU / error).
  property var gpuState: ({ vendor: "", model: "", status: "", ready: false,
                            total: 0, temp: -1, memUsed: -1, memTotal: -1,
                            engines: [], procs: [], hints: [],
                            setup: { title: "", lines: [] } })
  property var gpuHistory: []
  property bool gpuPolling: false

  readonly property var gpuEngineHeights: Model.normalize(
    (function() { var v = []; for (var i = 0; i < gpuState.engines.length; i++) v.push(gpuState.engines[i].pct); return v })(),
    100
  )
  // Same fixed 0..100% axis as CPU so both charts read consistently.
  readonly property var gpuGraph: (root.activeStat && root.activeStat.id === "gpu") ? Model.scrollWindow(gpuHistory, historyBuckets) : []
  readonly property var gpuGraphHeights: Model.normalize(gpuGraph, 100)
  // Memory fraction used, 0..1 (0 when unknown) for the memory bar.
  readonly property real gpuMemPct: gpuState.memTotal > 0 ? Math.min(1, Math.max(0, gpuState.memUsed / gpuState.memTotal)) : 0
  // shown memory text like "512M / 8.1G", or "--" when the backend lacks it.
  readonly property string gpuMemText:
    (gpuState.memUsed >= 0 && gpuState.memTotal >= 0)
      ? Model.formatBytes(gpuState.memUsed) + " / " + Model.formatBytes(gpuState.memTotal)
      : "--"

  // ---- Disk state ------------------------------------------------------
  // Space digits (mount/fs*) come from df for the monitored filesystem; the
  // aggregate read/write rates from /proc/diskstats feed the I/O history graph
  // and procs holds top per-process read/write rates. `ready` means a sample
  // parsed (I/O always parses; space may be unknown until df runs).
  property var diskState: ({ mount: "", fsTotal: -1, fsFree: -1, fsUsed: -1,
                             fsUsePct: -1, read: -1, write: -1, ready: false, procs: [] })
  property var diskHistory: []
  property bool diskPolling: false

  readonly property var diskTopIo: Model.topIoRows(diskState.procs, diskTopProcesses)
  // I/O history: a column per bucket holding the read+write pair, newest right.
  readonly property var diskIoWindow: (root.activeStat && root.activeStat.id === "disk") ? Model.scrollIoWindow(diskHistory, historyBuckets) : []
  // Heights normalized to 0..1 against the shared read+write max so the two
  // bars of a column are comparable and the plot doesn't rescale each tick.
  readonly property var diskIoHeights: Model.normalizeIo(diskIoWindow)
  // Used-/free-fraction 0..1 for the disk space coloring, 0 when unknown.
  readonly property real diskUsedPct: diskState.fsTotal > 0 ? Math.min(1, Math.max(0, diskState.fsUsed / diskState.fsTotal)) : 0
  readonly property real diskFreePct: diskState.fsTotal > 0 ? Math.min(1, Math.max(0, diskState.fsFree / diskState.fsTotal)) : 0
  // Bar value colors: only the number is threshold-tinted (free = higher is
  // better, used = lower is better). Fall back to theme text until df reports.
  readonly property color diskFreeBarColor: diskState.fsTotal > 0 ? diskFreeColor(diskFreePct * 100) : cpuText
  readonly property color diskUsedBarColor: diskState.fsTotal > 0 ? diskUsedColor(diskUsedPct * 100) : cpuText

  // ---- RAM state --------------------------------------------------------
  // Instantaneous /proc/meminfo snapshot plus per-process RSS from status
  // files. `used` is apps + kernel-private (excluding page cache), `system`
  // is the reclaimable page cache, so used + system + free == total.
  property var ramState: ({ total: 0, free: 0, available: 0, used: 0, system: 0,
                            buffers: 0, cached: 0, shared: 0,
                            swapTotal: 0, swapUsed: 0, swapCached: 0,
                            ready: false, procs: [] })
  property var ramHistory: []
  property bool ramPolling: false

  // Top memory consumers (RSS, MiB) — filtered by the ramMinProcessMB floor.
  readonly property var ramTopProcs: (function() {
    var rows = []
    for (var i = 0; i < ramState.procs.length; i++) {
      var p = ramState.procs[i]
      if (p.rss / 1024 >= root.ramMinProcessMB) rows.push(p)
    }
    return rows.slice(0, Math.min(root.topRamProcesses, rows.length))
  })()
  // RAM pressure % (0..100) = used / total; the same figure drives the bar, the
  // gauge arc and the history graph so they always agree.
  readonly property real ramUsedPct: ramState.total > 0 ? Math.max(0, Math.min(100, 100 * ramState.used / ramState.total)) : 0
  // Same fixed 0..100% axis as CPU/GPU so the graph reads consistently.
  readonly property var ramGraph: (root.activeStat && root.activeStat.id === "ram") ? Model.scrollWindow(ramHistory, historyBuckets) : []
  readonly property var ramGraphHeights: Model.normalize(ramGraph, 100)
  readonly property string ramMemText:
    (ramState.used >= 0 && ramState.total >= 0)
      ? Model.formatRamSize(ramState.used) + " / " + Model.formatRamSize(ramState.total)
      : "--"
  readonly property string ramSwapText:
    ramState.swapTotal > 0
      ? Model.formatRamSize(ramState.swapUsed) + " / " + Model.formatRamSize(ramState.swapTotal)
      : "off"

  // ---- Battery state ----------------------------------------------------
  // Instantaneous snapshot of the ACPI power-supply tree + a top-CPU-consumer
  // sample (the drain proxy). `ready` is true once a battery is present and a
  // level parsed; a laptop without a battery has present=false so the bar can
  // fall back to a plain icon.
  property var batteryState: ({ present: false, state: "unknown", ac: false,
                                pct: -1, voltage: -1, current: 0, power: 0,
                                energy: -1, energyFull: -1, energyFullDesign: -1,
                                health: -1, cycles: -1, temp: -1,
                                timeToFull: 0, timeToEmpty: 0, model: "",
                                charging: false, discharging: false,
                                ready: false, procs: [] })
  property var batteryHistory: []
  property bool batteryPolling: false

  // Top CPU consumers (battery-drain proxy) — called "top processes" in a
  // battery context, capped to the configured row count.
  readonly property var batteryTopProcs: Model.topBatteryProcs(batteryState.procs, topBatteryProcesses)
  // Charge-level history graph, same fixed 0..100% axis as the other stats.
  readonly property var batteryGraph: (root.activeStat && root.activeStat.id === "battery") ? Model.scrollWindow(batteryHistory, historyBuckets) : []
  readonly property var batteryGraphHeights: Model.normalize(batteryGraph, 100)
  // Charge polarity drives the bar time shown: charging shows time-to-full,
  // discharging time-to-empty, full/idle shows the dash.
  readonly property string batteryTimeText:
    batteryState.charging
      ? Model.formatBatteryTime(batteryState.timeToFull)
      : (batteryState.discharging ? Model.formatBatteryTime(batteryState.timeToEmpty) : "--")
  // A short "on plug" / "on battery" caption for the dropdown hero meta.
  readonly property string batteryStatusText:
    batteryState.ready
      ? (batteryState.discharging ? "On battery" : "On AC")
      : "No battery"

  // ---- Power profiles (dropdown) ----------------------------------------
  // Available power-profiles and the active one, from `omarchy-powerprofiles-list
  // --active-state`, plus a cursor for keyboard navigation among them. Fetched
  // on-demand while the battery dropdown is open (see refreshPowerProfiles).
  property var powerProfiles: []
  property string activePowerProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  function refreshPowerProfiles() {
    if (profilesProc.running) return
    profilesProc.running = true
  }

  function onPowerProfilesFinished(raw) {
    var parsed = Model.parsePowerProfiles(raw)
    // Preserve the last known list across a transient empty payload so the
    // buttons don't blink out mid-transition.
    if (parsed.profiles.length === 0) return
    root.powerProfiles = parsed.profiles
    root.activePowerProfile = parsed.activeProfile
    var idx = parsed.profiles.indexOf(parsed.activeProfile)
    root.profileIndex = idx >= 0 ? idx : 0
  }

  function setPowerProfile(profile) {
    if (!profile || setProfileProc.running) return
    // Same policy as omarchy.power: remember the profile per ac/battery use.
    setProfileProc.command = ["omarchy-powerprofiles-set",
      root.batteryState.discharging ? "battery" : "ac", profile]
    setProfileProc.running = true
  }

  // Keyboard cursor: move between profiles by delta, wrap around, and apply.
  function selectProfileByDelta(delta) {
    if (root.powerProfiles.length === 0) return
    root.profileIndex = (root.profileIndex + delta + root.powerProfiles.length)
      % root.powerProfiles.length
  }
  function activateSelectedProfile() {
    if (root.profileIndex < 0 || root.profileIndex >= root.powerProfiles.length) return
    root.setPowerProfile(root.powerProfiles[root.profileIndex])
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPowerProfilesFinished(text)
    }
  }

  Process {
    id: setProfileProc
    onExited: root.refreshPowerProfiles()
  }

  // ---- Network state ----------------------------------------------------
  // Snapshot of the aggregate rates (for the bar + graph), cumulative totals
  // and connection details from net.sh, plus per-process TCP up/down. `ready`
  // means an active interface produced a sample. `online` / `pingMs` /
  // `publicIp` come from net.sh's throttled probe and can lag a tick.
  property var netState: ({ iface: "", type: "unknown", mac: "", ssid: "",
                            ip: "", gateway: "", connected: false, online: false,
                            pingMs: -1, publicIp: "", down: -1, up: -1,
                            totalDown: -1, totalUp: -1, ready: false, procs: [] })
  property var netHistory: []
  property bool netPolling: false

  // Top processes by network (sum of up+down, TCP-attributed).
  readonly property var netTopProcs: Model.topNetProcs(netState.procs, networkTopProcesses)
  // Throughput history, one column per bucket holding the down/up pair.
  readonly property var netGraph: (root.activeStat && root.activeStat.id === "network") ? Model.scrollNetWindow(netHistory, historyBuckets) : []
  // Heights normalized to 0..1 against the shared down+up max so the two bars
  // of a column are comparable and the plot doesn't rescale each tick.
  readonly property var netGraphHeights: Model.normalizeNet(netGraph)
  // Current aggregate rates, formatted for the bar / headline ("27KB/s").
  readonly property string netDownText: Model.formatNetRate(netState.down)
  readonly property string netUpText: Model.formatNetRate(netState.up)
  // Lifetime totals.
  readonly property string netTotalDownText: Model.formatNetTotal(netState.totalDown)
  readonly property string netTotalUpText: Model.formatNetTotal(netState.totalUp)
  // Interface label for the detail block ("Wifi" / "Ethernet").
  readonly property string netInterfaceText:
    netState.type === "wifi" ? "Wifi" : (netState.type === "ethernet" ? "Ethernet" : "--")
  // Internet state: UP when the probe reached the net, DOWN when a link exists
  // but the probe failed, NO LINK when there is no active interface.
  readonly property string netOnlineText:
    netState.online ? "UP" : (netState.connected ? "DOWN" : "NO LINK")

  // ---- Bar widget sizing ----
  // CPU and GPU items are two-line text stacks (label over %) instead of an
  // icon, so they need a bit more height than the icon slot and enough width
  // for their label + "100%". The other stats keep the standard icon button.
  readonly property int cpuBarHeight: Style.bar.sizeHorizontal
  readonly property int cpuBarWidth: Style.space(34)
  readonly property int gpuBarHeight: Style.bar.sizeHorizontal
  readonly property int gpuBarWidth: Style.space(34)
  // Disk shows "F: <size>" / "U: <size>" (two text lines) so it needs a bit
  // more width than the CPU/GPU label-over-% stack to fit e.g. "F: 99.9GB".
  readonly property int diskBarHeight: Style.bar.sizeHorizontal
  readonly property int diskBarWidth: Style.space(48)
  // RAM shows "ram"/"NN%" (two text lines, like CPU/GPU).
  readonly property int ramBarHeight: Style.bar.sizeHorizontal
  readonly property int ramBarWidth: Style.space(34)
  // Battery bar: a two-line column (% over time-to-full/empty) to the LEFT of
  // the omarchy battery icon. The bar item's outer container centers the
  // contents in this slot width, so the width should track the rendered content
  // (two text lines + the enlarged icon) — too tight and the icon overflows into
  // the next item, too wide and it adds dead gutter. ~40 keeps the neighbours
  // at a normal gap while giving the bigger icon room.
  readonly property int batteryBarHeight: Style.bar.sizeHorizontal
  readonly property int batteryBarWidth: Style.space(40)
  // Network bar: a two-line stack of the current down/up rates (no label),
  // so it needs enough width for e.g. "27KB/s" and "1.5MB/s".
  readonly property int netBarHeight: Style.bar.sizeHorizontal
  readonly property int netBarWidth: Style.space(66)

  // The bar host draws an accent pill under/over a module slot while one of
  // its dropdowns is open (see bar/Bar.qml `openPanelIndicator`). It defaults
  // to ~55% of the whole module slot — which sweeps under ALL stat icons at
  // once and looks off. obi.stats paints its own per-icon active highlight on
  // the clicked item, so shrink the host's pill to ~invisible. The hint must
  // be > 0 (the bar treats 0 as "unset" and falls back to the big default),
  // hence 1px.
  readonly property real openPanelIndicatorWidth: 1
  readonly property real openPanelIndicatorHeight: 1

  // Whether a stat renders as a live bar item (a custom composition rather than
  // a plain icon button).
  function isLiveStat(stat) {
    if (!stat) return false
    var id = String(stat.id)
    return id === "cpu" || id === "gpu" || id === "disk" || id === "ram" || id === "battery" || id === "network"
  }

  function barItemWidth(stat) {
    if (stat && String(stat.id) === "cpu") return root.cpuBarWidth
    if (stat && String(stat.id) === "gpu") return root.gpuBarWidth
    if (stat && String(stat.id) === "disk") return root.diskBarWidth
    if (stat && String(stat.id) === "ram") return root.ramBarWidth
    if (stat && String(stat.id) === "battery") return root.batteryBarWidth
    if (stat && String(stat.id) === "network") return root.netBarWidth
    return Style.bar.iconSlot
  }

  function barItemHeight(stat) {
    if (stat && String(stat.id) === "cpu") return root.cpuBarHeight
    if (stat && String(stat.id) === "gpu") return root.gpuBarHeight
    if (stat && String(stat.id) === "disk") return root.diskBarHeight
    if (stat && String(stat.id) === "ram") return root.ramBarHeight
    if (stat && String(stat.id) === "battery") return root.batteryBarHeight
    if (stat && String(stat.id) === "network") return root.netBarHeight
    return Style.bar.sizeHorizontal
  }

  // ---- Bar widgets: one clickable glyph per stat ------------------------
  implicitWidth: statRow.implicitWidth
  implicitHeight: statRow.implicitHeight

  Row {
    id: statRow
    spacing: Style.space(16)

    Repeater {
      model: root.defs

      Item {
        required property var modelData
        width: root.barItemWidth(modelData)
        height: root.barItemHeight(modelData)

        readonly property string statId: modelData.id
        readonly property string statLabel: modelData.label
        readonly property string statIcon: modelData.icon

        // Non-live stats keep the single-icon bar button.
        BarIconButton {
          id: button
          visible: !root.isLiveStat(modelData)
          bar: root.bar
          text: statIcon
          tooltipText: root.tooltipFor(modelData)
          active: root.opened && root.activeStat && root.activeStat.id === modelData.id

          onPressed: function(b) {
            if (root.opened && root.activeStat && root.activeStat.id === modelData.id) root.toggleActiveStat()
            else root.openStat(modelData, button)
          }
        }

        // CPU and GPU show a two-line text stack "cpu / NN%" instead of an
        // icon, with the % tinted by the usage thresholds (same usageColor as
        // the panel).
        PctBarButton {
          id: pctButton
          visible: root.isLiveStat(modelData)
          stat: modelData
        }

        Component.onCompleted: root.registerBarButton(modelData.id, root.isLiveStat(modelData) ? pctButton : button)
      }
    }
  }

  // Vertical dividers drawn between stats. Kept as an absolute overlay rather
  // than an interleaved layout entry so the live bar buttons are never
  // instantiated with a null stat. Their x-position is computed from each
  // stat's known width + the row spacing, so they land centred in each gap.
  Item {
    id: separators
    anchors.fill: statRow
    visible: root.defs.length > 0
    clip: true

    readonly property var xs: (function() {
      var out = []
      var x = 0
      for (var i = 0; i < root.defs.length; i++) {
        x += root.barItemWidth(root.defs[i])
        if (i < root.defs.length - 1) {
          out.push(x + statRow.spacing / 2)
          x += statRow.spacing
        }
      }
      return out
    })()

    Repeater {
      model: separators.xs

      Rectangle {
        width: root.separatorWidth
        height: root.separatorHeight
        radius: width / 2
        color: root.separatorColor
        x: modelData - width / 2
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // A live % bar button: a clickable, tooltipped WidgetButton whose visual is
  // a two-line stack (label over the live %) rather than a glyph. Sized to fit
  // both lines in the bar's height; the % color follows the usage thresholds.
  // Drives the CPU and GPU items, whose live value/color come from the stat id.
  component PctBarButton: WidgetButton {
    id: rootbtn
    property var stat: null

    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.barItemWidth(stat)
    fixedHeight: root.barItemHeight(stat)
    horizontalMargin: 6
    verticalPadding: 2
    tooltipText: root.tooltipFor(stat)
    active: root.opened && root.activeStat && root.activeStat.id === stat.id

    onPressed: function(b) {
      if (root.opened && root.activeStat && root.activeStat.id === stat.id) root.toggleActiveStat()
      else root.openStat(stat, rootbtn)
    }

    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(0)

      // CPU/GPU: label over the live %, tinted by the usage thresholds.
      Text {
        visible: stat.id !== "disk" && stat.id !== "battery" && stat.id !== "network"
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        text: stat.label.toUpperCase()
        color: root.cpuText
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.bold: true
      }
      Text {
        id: pctLine
        visible: stat.id !== "disk" && stat.id !== "battery" && stat.id !== "network"
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        text: root.livePctText(stat.id)
        color: root.livePctColor(stat.id)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.bold: true
      }

      // Battery bar: on the left of the battery icon, two stacked lines —
      // line 1 = percentage, line 2 = time-to-full/empty. The icon uses
      // omarchy's battery set (tier-fills by charge level; while charging it's
      // the bolt-in-battery variant). The two lines stay plain theme text; ONLY
      // the icon gets the charge-threshold color treatment (low = alarming), so
      // the numbers stay readable while the icon signals the state. The two
      // lines use tight spacing (0) so their vertical gap matches the CPU/GPU
      // two-line stacks.
      //
      // Layout: the % and time lines live in a plain Column, and the icon is a
      // Text to its right in a Row. The Row hugs its content width so the icon
      // sits snugly beside the column — do NOT anchor the children (anchors
      // break a Row's content-width calculation and shove the icon away).
      Row {
        visible: stat.id === "battery"
        spacing: Style.space(4)
        Column {
          spacing: Style.space(0)
          Text {
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            text: Model.batteryPctText(root.batteryState.pct)
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Math.max(8, Style.font.caption - 1)
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            text: root.batteryTimeText
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Math.max(7, Style.font.caption - 2)
            font.bold: true
          }
        }
        // The icon, sized up clearly (caption+9 ≈ 19px vs the 14px value lines) so the
        // bump is actually visible, and vertically centred against the two-line
        // column. AlignVCenter centres it in the Row's cross-axis (= the column's
        // full height, so it lands between the % and the time).
        Text {
          textFormat: Text.PlainText
          text: root.batteryIconGlyph()
          // While charging, always use the calm state color no matter how low
          // the charge is; only the discharging icon carries the urgent/accent
          // threshold tint (low charge = alarming).
          color: root.batteryState.charging ? root.cpuText : root.batteryColor(root.batteryState.pct)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(19, Style.font.caption + 9)
          font.bold: true
          Layout.alignment: Qt.AlignVCenter
        }
      }

      // Network: two lines of the current rates, download over upload. Same font
      // and no threshold tint. Each line pins its direction arrow to the left
      // edge and right-aligns the number, so a value changing width never
      // nudges the glyph — the arrows stay fixed and the numbers share a
      // right edge.
      Column {
        visible: stat.id === "network"
        width: root.netBarWidth - Style.space(12)
        spacing: Style.space(0)
        Layout.alignment: Qt.AlignHCenter
        NetRateRow { arrow: "▼"; value: root.netDownText }
        NetRateRow { arrow: "▲"; value: root.netUpText }
      }

      // Disk: two lines. The F:/U: prefix stays theme text; only the value is
      // threshold-tinted (free: higher-is-better; used: lower-is-better).
      Row {
        visible: stat.id === "disk"
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(2)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "F:"
          color: root.cpuText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(8, Style.font.caption - 1)
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: Model.formatGb(root.diskState.fsFree)
          color: root.diskFreeBarColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(8, Style.font.caption - 1)
          font.bold: true
        }
      }
      Row {
        visible: stat.id === "disk"
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(2)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "U:"
          color: root.cpuText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(8, Style.font.caption - 1)
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: Model.formatGb(root.diskState.fsUsed)
          color: root.diskUsedBarColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(8, Style.font.caption - 1)
          font.bold: true
        }
      }
    }
  }

  // A single network bar line: direction arrow at the left edge, a fixed space,
  // then the value growing right. The arrow is pinned (first element of a
  // constant-width row) so it never shifts as the value changes width.
  component NetRateRow: Row {
    required property string arrow
    required property string value
    width: parent.width
    Text {
      textFormat: Text.PlainText
      text: arrow
      color: root.cpuText
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 1)
      font.bold: true
    }
    Item {
      width: Style.space(4)
      height: 1
    }
    Text {
      textFormat: Text.PlainText
      text: value
      color: root.cpuText
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 1)
      font.bold: true
    }
  }

  // The battery icon uses omarchy's exact icon set (Model.batteryIcon): two
  // 10-tier Material Design battery arrays — a plain filled battery that drains
  // with charge, and a bolt-in-battery variant used while charging. Selecting by
  // charge tier makes the icon itself show the charge level (omarchy's approach);
  // the % and time render beside it. A plain outline is shown when absent.
  readonly property string batteryOutlineGlyph: "󰉃"
  function batteryIconGlyph() {
    if (!root.batteryState.ready) return root.batteryOutlineGlyph
    return Model.batteryIcon(root.batteryState.pct, root.batteryState.charging)
  }

  // The CPU/GPU bar items surface the live aggregate on their tooltip.
  function tooltipFor(stat) {
    if (!stat) return ""
    if (stat.id === "cpu") return stat.label + " " + Model.formatPct(root.cpuState.total)
    if (stat.id === "gpu") {
      if (root.gpuState.ready) return stat.label + " " + Model.formatPct(root.gpuState.total)
      return stat.label + " — " + (root.gpuState.setup ? root.gpuState.setup.title : "setup needed")
    }
    if (stat.id === "disk")
      return stat.label + " — " + Model.formatGb(root.diskState.fsUsed) + " used / " +
             Model.formatGb(root.diskState.fsFree) + " free"
    if (stat.id === "ram")
      return stat.label + " — " + root.ramMemText + (root.ramState.swapTotal > 0 ? "  ·  swap " + root.ramSwapText : "")
    if (stat.id === "battery") {
      if (!root.batteryState.ready) return stat.label + " — no battery"
      var charge = Model.batteryPctText(root.batteryState.pct)
      var t = root.batteryState.charging ? "to full " + root.batteryTimeText
             : (root.batteryState.discharging ? "left " + root.batteryTimeText : "full")
      return stat.label + " — " + charge + "  ·  " + root.batteryStatusText +
             (t && t !== "full" ? "  ·  " + t : "")
    }
    if (stat.id === "network")
      return stat.label + " — ▼ " + root.netDownText + "  ▲ " + root.netUpText +
             (root.netState.iface !== "" ? "  ·  " + root.netInterfaceText : "")
    return stat.label
  }

  // Live % text/color for a stat's bar label, keyed by stat id (cpu/gpu/ram).
  function livePctText(id) {
    if (String(id) === "cpu") return Model.formatPct(root.cpuState.total)
    if (String(id) === "gpu") return root.gpuState.ready ? Model.formatPct(root.gpuState.total) : "…"
    if (String(id) === "ram") return Model.formatPct(root.ramUsedPct)
    return "--"
  }

  function livePctColor(id) {
    if (String(id) === "cpu") return root.usageColor(root.cpuState.total)
    if (String(id) === "gpu") return root.usageColor(root.gpuState.total)
    if (String(id) === "ram") return root.usageColor(root.ramUsedPct)
    return root.cpuText
  }

  function openStat(stat, button) {
    root.activeStat = stat
    root.activeButton = button || root.statButtons[stat.id]
    root.cursorActive = false
    // Skip a redundant full-sample kick when the last combined sample is still
    // fresh — the always-on timer keeps bar + dropdown data current, so opening
    // right after a tick need not re-run all six samplers. Kick only if the
    // data is getting stale (on-demand per-process tables still update via
    // syncProcsPolling).
    var now = Date.now() / 1000
    if (now - root.lastSampleAt >= Math.max(1.0, root.refreshSeconds * 0.5)) root.sampleRefresh()
    root.syncProcsPolling()
    if (stat.id === "battery") {
      root.cursorActive = false
      root.refreshPowerProfiles()
    }
    root.controller.show()
  }

  function openStatId(id) {
    var stat = Model.statById(root.defs, id)
    if (!stat) return false
    root.openStat(stat, null)
    return true
  }

  // ============================ Combined sampling ======================
  // One sampler (sample.sh) fetches every always-on stat in a single spawn,
  // running the six samplers in parallel and emitting section-marked output.
  // The per-stat timers below are disabled; a single refreshSeconds cadence
  // drives this. `procs.sh` (the on-demand per-process tables) still runs only
  // while a relevant dropdown is open (see syncProcsPolling).
  property bool samplePolling: false
  // Wall-clock (s) of the last combined sample that completed; used to avoid a
  // redundant full-sample kick when a dropdown opens shortly after a tick.
  property real lastSampleAt: 0
  readonly property string sampleWindow:
    String(Math.max(0.3, Math.round(root.refreshSeconds * 0.3 * 100) / 100))
  function sampleRefresh() {
    if (root.samplePolling) return
    root.samplePolling = true
    // Only run the net `ss` per-socket sampling while the network dropdown is
    // open; the bar's aggregate rate needs only the cheap /proc/net/dev read.
    var doNet = (root.activeStat && root.activeStat.id === "network") ? "1" : "0"
    sampleProc.command = [root.sampleScript, root.sampleWindow, doNet]
    sampleProc.running = true
  }

  Process {
    id: sampleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSampleFinished(text)
    }
  }

  function onSampleFinished(raw) {
    root.samplePolling = false
    root.lastSampleAt = Date.now() / 1000
    var parts = String(raw || "").split(/^___([a-z]+)___/m)
    for (var i = 1; i + 1 < parts.length; i += 2) {
      var stat = parts[i]
      var content = parts[i + 1]
      if (stat === "cpu") root.applyCpu(Model.parseCpuOutput(content))
      else if (stat === "gpu") root.applyGpu(Model.parseGpuOutput(content))
      else if (stat === "disk") root.applyDisk(Model.parseDiskOutput(content))
      else if (stat === "ram") root.applyRam(Model.parseRamOutput(content))
      else if (stat === "battery") root.applyBattery(Model.parseBatteryOutput(content))
      else if (stat === "net") root.applyNet(Model.parseNetworkOutput(content))
    }
  }

  // Apply a parsed stat to its state + history (kept procs arrays intact).
  function applyCpu(parsed) {
    root.cpuState = Object.assign(parsed, { procs: root.cpuState.procs })
    var now = Date.now() / 1000
    root.cpuHistory = Model.appendHistory(root.cpuHistory, now, parsed.total, root.historySeconds)
  }
  function applyGpu(parsed) {
    root.gpuState = parsed
    var now = Date.now() / 1000
    if (parsed.ready) root.gpuHistory = Model.appendHistory(root.gpuHistory, now, parsed.total, root.historySeconds)
  }
  function applyDisk(parsed) {
    root.diskState = Object.assign(parsed, { procs: root.diskState.procs })
    var now = Date.now() / 1000
    if (parsed.ready) root.diskHistory = Model.appendIoHistory(root.diskHistory, now, parsed.read, parsed.write, root.historySeconds)
  }
  function applyRam(parsed) {
    root.ramState = Object.assign(parsed, { procs: root.ramState.procs })
    var now = Date.now() / 1000
    if (parsed.ready) root.ramHistory = Model.appendHistory(root.ramHistory, now, parsed.used / parsed.total * 100, root.historySeconds)
  }
  function applyBattery(parsed) {
    root.batteryState = Object.assign(parsed, { procs: root.batteryState.procs })
    var now = Date.now() / 1000
    if (parsed.ready) root.batteryHistory = Model.appendHistory(root.batteryHistory, now, parsed.pct, root.historySeconds)
  }
  function applyNet(parsed) {
    root.netState = parsed
    var now = Date.now() / 1000
    if (parsed.ready) root.netHistory = Model.appendNetHistory(root.netHistory, now, parsed.down, parsed.up, root.historySeconds)
  }

  Timer {
    id: sampleTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: true
    onTriggered: root.sampleRefresh()
  }

  // Populate the bar promptly at startup (the main timer first fires after a
  // full refreshSeconds).
  Timer {
    id: sampleStartup
    interval: 150
    repeat: false
    running: true
    onTriggered: root.sampleRefresh()
  }

  // ============================ CPU polling ==============================
  // Sample window passed to cpu.sh. Kept a fraction of the refreshInterval so
  // each run finishes inside one tick — otherwise (window >= interval) the run
  // straddles the next timer tick, which gets skipped by cpuPolling and the
  // real cadence staggers to ~2-3x the configured refreshSeconds.
  readonly property string cpuSampleWindow:
    "0.5"
  function refreshCpu() {
    if (root.cpuPolling) return
    root.cpuPolling = true
    cpuProc.command = [root.cpuScript, root.cpuSampleWindow]
    cpuProc.running = true
  }

  Process {
    id: cpuProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCpuFinished(text)
    }
  }

  function onCpuFinished(raw) {
    root.cpuPolling = false
    var parsed = Model.parseCpuOutput(raw)
    // Keep whatever the shared procs sampler planted; cpu.sh now only emits the
    // aggregate + per-core (no per-process rows).
    root.cpuState = Object.assign(parsed, { procs: root.cpuState.procs })
    var now = Date.now() / 1000
    root.cpuHistory = Model.appendHistory(root.cpuHistory, now, parsed.total, root.historySeconds)
  }

  Timer {
    id: cpuPollTimer
    interval: root.cpuRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.cpuPolling) root.refreshCpu() }
  }

  // ============================ GPU polling ==============================
  // intel_gpu_top's default refresh window is 1000ms, which would block each
  // poll for a full second and stretch the effective cadence to ~2-3x
  // refreshSeconds. Pass a window that's a fraction of the poll interval so a
  // run finishes inside one tick — same rule as cpu.sh's sample window.
  readonly property int gpuSampleMs: Math.max(150, Math.round(root.gpuRefreshSeconds * 1000 / 3))
  function refreshGpu() {
    if (root.gpuPolling) return
    root.gpuPolling = true
    gpuProc.command = [root.gpuScript, String(root.gpuSampleMs)]
    gpuProc.running = true
  }

  Process {
    id: gpuProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onGpuFinished(text)
    }
  }

  function onGpuFinished(raw) {
    root.gpuPolling = false
    var parsed = Model.parseGpuOutput(raw)
    root.gpuState = parsed
    var now = Date.now() / 1000
    // Only a live sample feeds the history graph — a device that just lost
    // its tool shouldn't spike the chart with stale/zero data.
    if (parsed.ready) root.gpuHistory = Model.appendHistory(root.gpuHistory, now, parsed.total, root.historySeconds)
  }

  Timer {
    id: gpuPollTimer
    interval: root.gpuRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.gpuPolling) root.refreshGpu() }
  }

  // ---- GPU tool install (one-shot, launched from the setup card) --------
  // `installGpuScript` is bundled with the plugin; the button launches it in
  // the user's default terminal (via Omarchy's xdg-terminal-exec + uwsm-app
  // pattern) so the sudo/password prompt appears in a real terminal, not the
  // bar. The script installs the vendor's package and runs gpu.sh --doctor.
  readonly property string gpuInstallScript: root.pluginDir + "/gpu-install.sh"

  function installGpuTool() {
    var tool = Model.gpuToolFor(root.gpuState.vendor)
    // Guard: only offer the action when we know which package to install.
    if (!tool || !tool.pkg) return
    gpuInstallProc.command = [
      "setsid", "uwsm-app", "--", "xdg-terminal-exec",
      "--app-id=org.omarchy.terminal", "--title=Install GPU Helper",
      "-e", "bash", root.gpuInstallScript
    ]
    gpuInstallProc.running = true
    // Sample shortly after so the panel reflects the new tool status once
    // the terminal work is done (install + doctor). The main sampler cadence
    // already covers this; the extra kick just keeps the setup card snappy.
    root.sampleRefresh()
  }

  Process {
    id: gpuInstallProc
  }

  // ============================ Disk polling ============================
  // One sampler returns space (for the bar) and I/O rates (for the graph +
  // processes). Sample window is a fraction of the poll interval so each run
  // finishes inside one tick — same rule as cpu/gpu sample windows.
  readonly property string diskSampleWindow:
    String(Math.max(0.2, Math.round(root.fileioRefreshSeconds * 0.4 * 100) / 100))
  function refreshDisk() {
    if (root.diskPolling) return
    root.diskPolling = true
    diskProc.command = [root.diskScript, root.diskSampleWindow, root.diskMount]
    diskProc.running = true
  }

  Process {
    id: diskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDiskFinished(text)
    }
  }

  function onDiskFinished(raw) {
    root.diskPolling = false
    var parsed = Model.parseDiskOutput(raw)
    root.diskState = Object.assign(parsed, { procs: root.diskState.procs })
    var now = Date.now() / 1000
    // Only a live sample feeds the I/O history graph.
    if (parsed.ready) root.diskHistory = Model.appendIoHistory(root.diskHistory, now, parsed.read, parsed.write, root.historySeconds)
  }

  Timer {
    id: diskPollTimer
    interval: root.fileioRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.diskPolling) root.refreshDisk() }
  }

  // ============================ RAM polling ==============================
  // A single instantaneous /proc pass (meminfo + status). No sample window —
  // unlike CPU/disk there's no rate to average, so refreshRam is a simple run
  // of ram.sh. Both the bar/`%` and the dropdown come from the same snapshot.
  function refreshRam() {
    if (root.ramPolling) return
    root.ramPolling = true
    ramProc.command = [root.ramScript, String(root.topRamProcesses)]
    ramProc.running = true
  }

  Process {
    id: ramProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onRamFinished(text)
    }
  }

  function onRamFinished(raw) {
    root.ramPolling = false
    var parsed = Model.parseRamOutput(raw)
    root.ramState = Object.assign(parsed, { procs: root.ramState.procs })
    var now = Date.now() / 1000
    // Only a live sample feeds the history graph.
    if (parsed.ready) root.ramHistory = Model.appendHistory(root.ramHistory, now, parsed.used / parsed.total * 100, root.historySeconds)
  }

  Timer {
    id: ramPollTimer
    interval: root.ramRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.ramPolling) root.refreshRam() }
  }

  // ============================ Battery polling ==========================
  // A single instantaneous /sys ACPI pass (no sample window for the battery
  // itself — those are point-in-time reads like RAM). battery.sh also samples
  // per-process CPU as the drain proxy over a small window; that window must be
  // a fraction of the poll interval so each run finishes inside one tick, same
  // rule as cpu/gpu/disk sample windows.
  readonly property string batterySampleWindow:
    String(Math.max(0.2, Math.round(root.batteryRefreshSeconds * 0.3 * 100) / 100))
  function refreshBattery() {
    if (root.batteryPolling) return
    root.batteryPolling = true
    batteryProc.command = [root.batteryScript, root.batterySampleWindow, String(root.topBatteryProcesses)]
    batteryProc.running = true
  }

  Process {
    id: batteryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onBatteryFinished(text)
    }
  }

  function onBatteryFinished(raw) {
    root.batteryPolling = false
    var parsed = Model.parseBatteryOutput(raw)
    root.batteryState = Object.assign(parsed, { procs: root.batteryState.procs })
    var now = Date.now() / 1000
    // Only a live sample feeds the charge history graph.
    if (parsed.ready) root.batteryHistory = Model.appendHistory(root.batteryHistory, now, parsed.pct, root.historySeconds)
  }

  Timer {
    id: batteryPollTimer
    interval: root.batteryRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.batteryPolling) root.refreshBattery() }
  }

  // ============================ Network polling ==========================
  // net.sh computes aggregate rates over a short two-sample window (like disk
  // I/O) and runs the slow internet probes (ping / online / public IP) on an
  // internal throttle so the per-tick sample stays fast. The window is a
  // fraction of the poll interval, same rule as the other samplers.
  readonly property string networkSampleWindow:
    String(Math.max(0.2, Math.round(root.networkRefreshSeconds * 0.4 * 100) / 100))
  function refreshNetwork() {
    if (root.netPolling) return
    root.netPolling = true
    netProc.command = [root.netScript, root.networkSampleWindow, String(root.networkProbeSeconds)]
    netProc.running = true
  }

  Process {
    id: netProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onNetFinished(text)
    }
  }

  function onNetFinished(raw) {
    root.netPolling = false
    var parsed = Model.parseNetworkOutput(raw)
    root.netState = parsed
    var now = Date.now() / 1000
    // Only a live sample feeds the throughput history graph.
    if (parsed.ready) root.netHistory = Model.appendNetHistory(root.netHistory, now, parsed.down, parsed.up, root.historySeconds)
  }

  Timer {
    id: netPollTimer
    interval: root.networkRefreshSeconds * 1000
    repeat: true
    running: false
    onTriggered: { if (!root.netPolling) root.refreshNetwork() }
  }

  // ==================== Shared per-process polling ======================
  // The CPU, RAM, disk and battery dropdown "top processes" tables all read the
  // same per-process data, so they share ONE sampler (procs.sh) that reads each
  // process once per pass (stat + io + status) and this block fans it out into
  // the four *State.procs lists. It only runs while one of those dropdowns is
  // open (at that open stat's refresh cadence), so the always-on bar polls stay
  // cheap — no sampler rescans the whole /proc process tree every tick.
  property var procRows: []
  property bool procsPolling: false

  function refreshProcs() {
    if (root.procsPolling) return
    root.procsPolling = true
    // Sample window is a fraction of the poll interval so each run finishes
    // inside one tick, same rule as the other samplers.
    procsProc.command = [root.procsScript, "0.5"]
    procsProc.running = true
  }

  Process {
    id: procsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProcsFinished(text)
    }
  }

  function onProcsFinished(raw) {
    root.procsPolling = false
    var rows = Model.parseProcRows(raw)
    root.procRows = rows
    root.cpuState.procs = Model.procRowsByCpu(rows)
    root.batteryState.procs = Model.procRowsByCpu(rows)   // drain proxy = top CPU
    root.diskState.procs = Model.procRowsByIo(rows)
    root.ramState.procs = Model.procRowsByRss(rows)
  }

  // Start/stop/re-interval the shared poller to track the currently open stat.
  // Only active while a stat with a per-process table is open; polls at that
  // stat's own refreshSeconds (so per-stat configs stay respected).
  function syncProcsPolling() {
    var s = root.activeStat
    var needs = s && (s.id === "cpu" || s.id === "ram" || s.id === "disk" || s.id === "battery")
    if (!needs) {
      procsPollTimer.stop()
      return
    }
    var ms = Math.max(300, root.refreshSeconds * 1000)
    if (procsPollTimer.running && procsPollTimer.interval === ms) {
      root.refreshProcs()   // same cadence, just re-kick so the view is fresh
      return
    }
    procsPollTimer.stop()
    procsPollTimer.interval = ms
    procsPollTimer.start()
    root.refreshProcs()
  }

  Timer {
    id: procsPollTimer
    interval: 2000
    repeat: true
    running: false
    onTriggered: root.refreshProcs()
  }

  // Hero text: for CPU the title is "CPU CORES"; for GPU it's the matching
  // "GPU CORES" (the vendor labels it engines, but "CORES" keeps the pair
  // visually consistent). Neither repeats the stat label in meta — other stats
  // keep title+meta. The concrete GPU model name is shown as content in the
  // dropdown body, not in the hero.
  function heroTitle() {
    if (!root.activeStat) return ""
    if (root.activeStat.id === "cpu") return "CPU CORES"
    if (root.activeStat.id === "gpu") return "GPU CORES"
    if (root.activeStat.id === "disk") return "DISK I/O"
    if (root.activeStat.id === "ram") return "RAM USAGE"
    if (root.activeStat.id === "battery") return "BATTERY"
    if (root.activeStat.id === "network") return "NETWORK"
    return root.activeStat.label
  }

  function heroMeta() {
    if (!root.activeStat) return ""
    if (root.activeStat.id === "cpu") return ""
    if (root.activeStat.id === "gpu") {
      if (root.gpuState.ready) return root.gpuState.vendor.toUpperCase()
      return root.gpuState.setup ? root.gpuState.setup.title : "setup needed"
    }
    if (root.activeStat.id === "disk") {
      var d = root.diskState
      return (d.fsUsed >= 0 ? "U: " + Model.formatGb(d.fsUsed) + " used" : "")
           + (d.fsUsed >= 0 && d.fsFree >= 0 ? " · " : "")
           + (d.fsFree >= 0 ? "F: " + Model.formatGb(d.fsFree) + " free" : "")
    }
    if (root.activeStat.id === "ram")
      return root.ramMemText + (root.ramState.swapTotal > 0 ? "  ·  swap " + root.ramSwapText : "")
    if (root.activeStat.id === "battery") return ""
    if (root.activeStat.id === "network") return ""
    return Model.sectionTitle(root.activeStat) + " — coming soon"
  }

  // History/usage graph rendered as ONE Canvas that paints every column in a
  // single pass, instead of one Rectangle per column (~80-90 scene nodes per
  // graph that previously built/lay-out/painted on dropdown open). `up` holds
  // the normalized 0..1 column heights; when `dual` is set, `down` adds a
  // center-zero split axis (e.g. read/write or down/up) growing downward.
  component BarGraph: Canvas {
    id: bargraph
    // `up` (and `down` for dual) hold normalized 0..1 values. `style` picks a
    // filled-column bar chart ("bars", the default) or a polyline ("line").
    // Everything is drawn in one Canvas pass, so both modes stay cheap.
    property var up: []
    property var down: []
    property color barColor: root.cpuData
    property color barColor2: root.cpuDim
    property bool dual: false
    property string style: "bars"
    // Center zero line used by the dual bar chart (drawn here, not by a parent).
    property color zeroLineColor: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
    property real barWidth: Style.space(3)
    property real spacing: Style.space(1)
    onUpChanged: requestPaint()
    onDownChanged: requestPaint()
    onDualChanged: requestPaint()
    onStyleChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var u = bargraph.up
      if (!u || !Array.isArray(u) || u.length === 0) return
      var bw = bargraph.barWidth, sp = bargraph.spacing
      var n = u.length, step = bw + sp, half = height / 2
      var px = function(i) { return i * step + bw / 2 }

      if (bargraph.style === "line") {
        var py = function(v) { return height - (Number(v) || 0) * height }
        ctx.lineWidth = 2
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        // Area fill under the up curve (single-series charts read as area lines).
        if (!bargraph.dual) {
          var c = bargraph.barColor
          ctx.beginPath()
          ctx.moveTo(px(0), py(u[0]))
          for (var fa = 1; fa < n; fa++) ctx.lineTo(px(fa), py(u[fa]))
          ctx.lineTo(px(n - 1), height)
          ctx.lineTo(px(0), height)
          ctx.closePath()
          ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 0.15)
          ctx.fill()
        }
        // up line (bars: cpuData / disk write / net up)
        ctx.strokeStyle = bargraph.barColor
        ctx.beginPath()
        ctx.moveTo(px(0), py(u[0]))
        for (var li = 1; li < n; li++) ctx.lineTo(px(li), py(u[li]))
        ctx.stroke()
        if (bargraph.dual) {
          var dn = bargraph.down
          ctx.strokeStyle = bargraph.barColor2
          ctx.beginPath()
          for (var di = 0; di < dn.length && di < n; di++) {
            if (di === 0) ctx.moveTo(px(di), py(dn[di])); else ctx.lineTo(px(di), py(dn[di]))
          }
          ctx.stroke()
        }
        return
      }

      // --- bars (default) ---
      var x = 0, i
      ctx.fillStyle = bargraph.barColor
      if (bargraph.dual) {
        ctx.fillStyle = bargraph.zeroLineColor
        ctx.fillRect(0, half - 1, width, 1)
        ctx.fillStyle = bargraph.barColor
        for (i = 0; i < n; i++) {
          var uv = Number(u[i]) || 0
          if (uv > 0) ctx.fillRect(x, half - Math.max(1, Math.round(uv * half)), bw, Math.max(1, Math.round(uv * half)))
          x += step
        }
        var dnb = bargraph.down
        ctx.fillStyle = bargraph.barColor2
        x = 0
        for (i = 0; i < dnb.length && i < n; i++) {
          var dv = Number(dnb[i]) || 0
          if (dv > 0) ctx.fillRect(x, half, bw, Math.max(1, Math.round(dv * half)))
          x += step
        }
      } else {
        for (i = 0; i < n; i++) {
          var h = Math.max(1, Math.round((Number(u[i]) || 0) * height))
          if (Number(u[i]) || 0 > 0) ctx.fillRect(x, height - h, bw, h)
          x += step
        }
      }
    }
  }

  // A memory-usage speedometer: an open 270° arc with the gap at
  // the bottom, a faint tick ring, a glowing value arc that fills behind the
  // needle, a hubless needle, and a digital readout in the middle. Themed to
  // the panel (root.cpuText / usageColor) rather than a dark overlay scrim.
  // `value` is the usage percent (0..100); the arc + needle take the same
  // threshold color as the bar item's %, so calm/mild/alarming show at a glance.
  component RamGauge: Item {
    id: gauge

    required property real value
    property string unit: "%"

    readonly property real diameter: Style.space(170)
    // 0° = 3 o'clock, clockwise (PathAngleArc's convention); 135° start with a
    // 270° sweep leaves the gap at the bottom, like a car-cluster gauge.
    readonly property real dialStart: 135
    readonly property real dialSweep: 270
    readonly property int tickCount: 41
    readonly property real arcWidth: Style.space(4)
    readonly property real arcRadius: diameter / 2 - arcWidth
    readonly property color trackColor: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.14)
    readonly property color minorTickColor: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
    readonly property color majorTickColor: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.3)
    readonly property color valueColor: root.usageColor(value)
    readonly property real fraction: Math.max(0, Math.min(1, value / 100))
    readonly property bool arcVisible: fraction > 0.004

    width: diameter
    height: diameter

    Behavior on value {
      NumberAnimation { duration: 500; easing.type: Easing.OutCubic }
    }
    onValueChanged: gaugeCanvas.requestPaint()

    // Dial drawn as a single Canvas (track + glow + value arcs, tick ring and
    // needle in one paint pass) — replaces a Shape.CurveRenderer path set and a
    // 41-item tick Repeater, which were the heaviest part of opening the RAM
    // dropdown.
    Canvas {
      id: gaugeCanvas
      anchors.fill: parent
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        var cx = width / 2, cy = height / 2
        var r = gauge.arcRadius
        var rad = function(deg) { return deg * Math.PI / 180 }
        var s0 = rad(gauge.dialStart)
        var sw = rad(gauge.dialSweep)

        // Track (full 270°, gap at bottom).
        ctx.lineCap = "round"
        ctx.strokeStyle = gauge.trackColor
        ctx.lineWidth = gauge.arcWidth
        ctx.beginPath()
        ctx.arc(cx, cy, r, s0, s0 + sw, false)
        ctx.stroke()

        if (gauge.arcVisible) {
          var vc = gauge.valueColor
          var fracSw = sw * gauge.fraction
          // Soft under-glow (backlit-ring stand-in).
          ctx.strokeStyle = Qt.rgba(vc.r, vc.g, vc.b, 0.18)
          ctx.lineWidth = gauge.arcWidth * 3
          ctx.beginPath()
          ctx.arc(cx, cy, r, s0, s0 + fracSw, false)
          ctx.stroke()
          // Value arc (fills behind the needle, threshold-tinted).
          ctx.strokeStyle = vc
          ctx.lineWidth = gauge.arcWidth
          ctx.beginPath()
          ctx.arc(cx, cy, r, s0, s0 + fracSw, false)
          ctx.stroke()
        }

        // Tick ring just inside the arc; every fifth tick is a major.
        ctx.lineCap = "butt"
        var n = gauge.tickCount, i
        for (i = 0; i < n; i++) {
          var major = (i % 5 === 0)
          var a = rad(gauge.dialStart + (i / (n - 1)) * gauge.dialSweep)
          var dx = Math.cos(a), dy = Math.sin(a)
          var r1 = major ? 68 : 70
          var r2 = major ? 77 : 75
          ctx.strokeStyle = major ? gauge.majorTickColor : gauge.minorTickColor
          ctx.lineWidth = major ? Math.max(2, Style.space(2)) : 1
          ctx.beginPath()
          ctx.moveTo(cx + dx * r1, cy + dy * r1)
          ctx.lineTo(cx + dx * r2, cy + dy * r2)
          ctx.stroke()
        }

        // Hubless needle: a slender sliver that fades out toward the pivot.
        var na = rad(gauge.dialStart + gauge.fraction * gauge.dialSweep)
        var ndx = Math.cos(na), ndy = Math.sin(na)
        var rIn = gauge.arcWidth * 2 + Style.space(10)
        var rOut = rIn + gauge.diameter * 0.30
        var ix = cx + ndx * rIn, iy = cy + ndy * rIn
        var ox = cx + ndx * rOut, oy = cy + ndy * rOut
        var vc2 = gauge.valueColor
        var grad = ctx.createLinearGradient(ix, iy, ox, oy)
        grad.addColorStop(0.0, "transparent")
        grad.addColorStop(0.55, Qt.rgba(vc2.r, vc2.g, vc2.b, 1))
        grad.addColorStop(1.0, Qt.rgba(vc2.r, vc2.g, vc2.b, 1))
        ctx.strokeStyle = grad
        ctx.lineWidth = Math.max(2, Style.space(3))
        ctx.lineCap = "round"
        ctx.beginPath()
        ctx.moveTo(ix, iy)
        ctx.lineTo(ox, oy)
        ctx.stroke()
      }
    }

    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.verticalCenter
      anchors.topMargin: Style.space(10)
      spacing: 0

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: Model.formatPct(gauge.value)
        color: gauge.valueColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: gauge.unit
        color: root.cpuDim
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- Dropdown ----------------------------------------------------------
  // One content column, sized from the content it holds. Every section is a
  // direct child with real height (no anchor-only wrappers, which collapse to
  // zero height). The card uses a comfortable minimum height so the layout
  // has room to breathe instead of overlapping.
  KeyboardPanel {
    id: panel
    anchorItem: root.activeButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.contentWidthEstimate)
    contentHeight: panel.fittedContentHeight(Math.max(dropdownColumn.implicitHeight, Style.space(330)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        // Power-profile picker is keyboard-navigable (left/right wraps) only
        // while the battery dropdown with loaded profiles is open; all other
        // stats keep the reserved no-op.
        if (root.activeStat && root.activeStat.id === "battery" && root.powerProfiles.length > 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dx !== 0) root.selectProfileByDelta(dx)
          else if (dy !== 0) root.selectProfileByDelta(dy)
        }
      }
      onActivateRequested: root.cursorActive ? root.activateSelectedProfile() : root.close()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: dropdownColumn
      width: parent.width
      spacing: Style.space(12)

      // ---- Hero ----
      PanelHero {
        readonly property var stat: Model.statById(root.defs, root.activeStat ? root.activeStat.id : "")
        title: root.heroTitle()
        meta: root.heroMeta()
        foreground: root.cpuText
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      PanelSeparator {
        foreground: root.cpuText
      }

      // ==================== CPU body ==================================
      Column {
        visible: root.activeStat && root.activeStat.id === "cpu"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // Aggregate headline — label and the bigger % share a text baseline so
        // the value doesn't sit high against the "TOTAL" caption.
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            id: totalLabel
            textFormat: Text.PlainText
            text: "TOTAL"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: totalValue
            textFormat: Text.PlainText
            anchors.baseline: totalLabel.baseline
            text: Model.formatPct(root.cpuState.total)
            color: root.usageColor(root.cpuState.total)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Text {
            textFormat: Text.PlainText
            text: root.cpuState.cores.length + " CORE" + (root.cpuState.cores.length === 1 ? "" : "S")
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        // Per-core bars (section title removed; bars sit right under the
        // TOTAL headline).
        Row {
          id: coreBarsRow
          width: parent.width
          height: Style.space(42)
          spacing: Style.space(8)
          Repeater {
            model: root.cpuCoreHeights
            Item {
              required property real modelData
              width: Style.space(20)
              height: coreBarsRow.height
              Rectangle {
                anchors.fill: parent
                color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.08)
              }
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: Style.space(20)
                height: Math.max(Style.space(1), Math.round(modelData * parent.height))
                radius: root.cornerTiny
                color: root.cpuData
              }
            }
          }
        }

        // Core labels under each bar.
        Row {
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.cpuState.cores
            Item {
              required property var modelData
              width: Style.space(20)
              height: Style.space(16)
              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: modelData.pct + "%"
                color: root.cpuText
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Usage history section ----
        PanelSectionHeader {
          text: "USAGE HISTORY"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // History graph (columns, oldest on the left) — its own block below
        // the per-core bars so the two never overlap.
        Item {
          width: parent.width
          height: Style.space(60)
          clip: true
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
          }
          BarGraph {
              anchors.fill: parent
              up: root.cpuGraphHeights
              style: "line"
            }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Top processes ----
        // Fixed column widths so a long PID never shoves the % column or makes
        // it overlap: name (flexible, elided), pid (right-aligned fixed), pct.
        PanelSectionHeader {
          text: "TOP PROCESSES"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          width: parent.width
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            // Always render exactly `topProcesses` row slots so the dropdown
            // height stays fixed no matter how many processes are running.
            // Ranks past the live process count stay blank but still hold their
            // row, so the panel never resizes as processes appear/disappear.
            model: (function() { var a = []; for (var i = 0; i < root.topProcesses; i++) a.push(i); return a })()
            Item {
              required property int modelData
              readonly property var info: root.cpuTopProcs[modelData]
              width: parent.parent.width
              height: Style.space(22)
              Row {
                visible: modelData < root.cpuTopProcs.length
                width: parent.width
                height: parent.height

                // Name: fills the space left over by pinned pid + pct columns.
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.comm : ""
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - Style.space(120))
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.pid : ""
                  width: Style.space(56)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: Style.space(4)
                  height: 1
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(60)
                  text: info ? Model.formatPct(info.pct) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.usageColor(info ? info.pct : 0)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
          }
        }
      }

      // ==================== GPU body ==================================
      // Two modes: a setup card (tool/no-gpu/error) or the live view. Both sit
      // in the same column so the panel height stays stable between them.
      Column {
        visible: root.activeStat && root.activeStat.id === "gpu"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // Device line: the GPU model/family as dropdown content (the hero
        // leads with "GPU CORES" instead, matching CPU CORES). Shown in both
        // the setup and live states; empty until a sample parses. Wraps to
        // multiple lines (no ellipsis) so a long model name stays fully
        // readable.
        Text {
          visible: root.gpuState.model !== ""
          textFormat: Text.PlainText
          text: root.gpuState.model
          wrapMode: Text.Wrap
          width: parent.width
          color: root.cpuDim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // ---- setup card (shown until a live sample is available) ----
        Column {
          visible: !root.gpuState.ready
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: root.gpuState.setup.title ? root.gpuState.setup.title : "GPU SETUP"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            wrapMode: Text.Wrap
            width: parent.width
          }
          // One-click action: opens the default terminal to finish setup — it installs
          // the vendor's tool AND grants the permission it needs in one pass —
          // then runs the doctor to verify. Shown for any not-ready state where
          // we know a package (missing tool, permission-blocked, or a tool that
          // produced nothing). A single "Install GPU Helper" CTA covers them.
          Button {
            visible: (root.gpuState.status === "no-tool" || root.gpuState.status === "no-perm" || root.gpuState.status === "error") && Model.gpuToolFor(root.gpuState.vendor).pkg !== ""
            text: "Install GPU Helper"
            bordered: true
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(14)
            verticalPadding: Style.space(4)
            Layout.alignment: Qt.AlignHCenter
            onClicked: root.installGpuTool()
          }
        }

        // ---- live view ----
        Column {
          visible: root.gpuState.ready
          width: parent.width
          spacing: Style.space(10)

          // Aggregate headline — label and the bigger % share a baseline like
          // CPU's TOTAL row; the engine count + temp live on the right.
          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "USAGE"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              anchors.baseline: usageLabel.baseline
              text: Model.formatPct(root.gpuState.total)
              color: root.usageColor(root.gpuState.total)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
            Text {
              id: usageLabel
              textFormat: Text.PlainText
              text: (root.gpuState.engines.length > 0 ? root.gpuState.engines.length + " ENGINE" + (root.gpuState.engines.length === 1 ? "" : "S") : "")
                   + (root.gpuState.temp >= 0 ? "  ·  " + Model.formatTemp(root.gpuState.temp) : "")
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // Per-engine bars (e.g. GFX, Render, Copy — mirrors CPU's core bars).
          Row {
            id: engineBarsRow
            width: parent.width
            height: Style.space(42)
            spacing: Style.space(6)
            Repeater {
              model: root.gpuEngineHeights
              Item {
                required property real modelData
                width: Style.space(24)
                height: engineBarsRow.height
                Rectangle {
                  anchors.fill: parent
                  color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.08)
                }
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  width: Style.space(24)
                  height: Math.max(Style.space(1), Math.round(modelData * parent.height))
                  radius: root.cornerTiny
                  color: root.cpuData
                }
              }
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
          }

          // Engine labels under each bar.
          Row {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.gpuState.engines
              Item {
                required property var modelData
                width: Style.space(24)
                height: Style.space(16)
                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData.name
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
          }

          // Memory row — only when the backend exposes it.
          Row {
            visible: root.gpuState.memTotal > 0
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "MEMORY"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.gpuMemText
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
            Text {
              textFormat: Text.PlainText
              text: Model.formatPct(root.gpuMemPct * 100)
              color: root.usageColor(root.gpuMemPct * 100)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          // Memory bar (horizontal track + fill). A fixed-height Item hosts the two
          // Rectangles via anchors (Rectangles directly in a Row can't be
          // fill/left-anchored, since Row lays items out left-to-right).
          Item {
            visible: root.gpuState.memTotal > 0
            width: parent.width
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
              radius: root.cornerTiny
            }
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(1), Math.round(parent.width * root.gpuMemPct))
              height: parent.height
              radius: root.cornerTiny
              color: root.cpuData
            }
          }

          PanelSeparator {
            foreground: root.cpuText
          }

          // ---- Usage history section ----
          PanelSectionHeader {
            text: "USAGE HISTORY"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Item {
            width: parent.width
            height: Style.space(60)
            clip: true
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
            }
            BarGraph {
              anchors.fill: parent
              up: root.gpuGraphHeights
              style: "line"
            }
          }
        }
      }

      // ==================== Disk body ==================================
      Column {
        visible: root.activeStat && root.activeStat.id === "disk"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // Aggregate headline: WRITE and READ each on their own line, the value
        // baseline-aligned to its label (mirrors CPU's TOTAL / GPU's USAGE rows).
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              id: diskWriteLabel
              textFormat: Text.PlainText
              text: "WRITE"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              id: diskWriteVal
              textFormat: Text.PlainText
              anchors.baseline: diskWriteLabel.baseline
              text: Model.formatRate(root.diskState.write)
              color: root.cpuData
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              id: diskReadLabel
              textFormat: Text.PlainText
              text: "READ"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              anchors.baseline: diskReadLabel.baseline
              text: Model.formatRate(root.diskState.read)
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }
        }

        // Space used/total (from df) + a horizontal used bar, only when the
        // monitored filesystem reported a size.
        Row {
          visible: root.diskState.fsTotal > 0
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: "SPACE"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatGb(root.diskState.fsUsed) + " / " + Model.formatGb(root.diskState.fsTotal)
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatPct(root.diskState.fsUsePct)
            color: root.usageColor(root.diskState.fsUsePct)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Item {
          visible: root.diskState.fsTotal > 0
          width: parent.width
          height: Style.space(6)
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
            radius: root.cornerTiny
          }
          Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(Style.space(1), Math.round(parent.width * root.diskUsedPct))
            height: parent.height
            radius: root.cornerTiny
            color: root.cpuData
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- I/O history ---- dual-axis: positive y = write, negative y = read.
        PanelSectionHeader {
          text: "I/O HISTORY"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Item {
          width: parent.width
          height: Style.space(70)
          clip: true
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
          }
          // zero-line for the dual chart is drawn by BarGraph itself
          BarGraph {
            anchors.fill: parent
            dual: true
            up: (function(){ var v=[]; for (var i=0;i<root.diskIoHeights.length;i++) v.push(root.diskIoHeights[i].write); return v })()
            down: (function(){ var v=[]; for (var i=0;i<root.diskIoHeights.length;i++) v.push(root.diskIoHeights[i].read); return v })()
            style: "line"
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Top I/O processes ----
        PanelSectionHeader {
          text: "TOP I/O PROCESSES"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          width: parent.width
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            // Always render exactly `diskTopProcesses` row slots so the dropdown
            // height stays fixed no matter how many processes are doing I/O.
            // Ranks past the live count stay blank but still hold their row, so
            // the panel never resizes as I/O processes appear/disappear.
            model: (function() { var a = []; for (var i = 0; i < root.diskTopProcesses; i++) a.push(i); return a })()
            Item {
              required property int modelData
              readonly property var info: root.diskTopIo[modelData]
              width: parent.parent.width
              height: Style.space(22)
              Row {
                visible: modelData < root.diskTopIo.length
                width: parent.width
                height: parent.height

                // Name: fills the space left over by pinned pid + read + write.
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.comm : ""
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - Style.space(180))
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.pid : ""
                  width: Style.space(52)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: Style.space(4)
                  height: 1
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(60)
                  text: info ? Model.formatRate(info.read) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: Style.space(4)
                  height: 1
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(56)
                  text: info ? Model.formatRate(info.write) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuData
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
          }
        }
      }

      // ==================== RAM body ==================================
      Column {
        visible: root.activeStat && root.activeStat.id === "ram"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // Headline: the live usage % share a baseline with a caption, like
        // the other stats' TOTAL/USAGE row. It mirrors the bar item.
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            id: pressureLabel
            textFormat: Text.PlainText
            text: "USAGE"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            anchors.baseline: pressureLabel.baseline
            text: Model.formatPct(root.ramUsedPct)
            color: root.usageColor(root.ramUsedPct)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Text {
            textFormat: Text.PlainText
            text: root.ramMemText
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        // Memory usage speedometer, centered. The wrapper needs an explicit height
        // (dial diameter), otherwise the Column collapses it to 0px and the
        // dial is painted on top of the next section — invisible.
        Item {
          width: parent.width
          height: Style.space(170)
          Layout.alignment: Qt.AlignHCenter
          RamGauge {
            anchors.centerIn: parent
            value: root.ramUsedPct
          }
        }

        // ---- Memory pressure (PSI) section ----
        // True "memory pressure": the share of the recent 10s window that at
        // least one thread was stalled waiting for memory ('some'), vs all
        // threads blocked ('full'). From /proc/pressure/memory. Hidden when the
        // kernel exposes no PSI file. Raised values (not just usage %) warn of
        // real strain — cache can't be reclaimed to relieve it.
        Column {
          visible: root.ramState.psiSome10 >= 0
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MEMORY PRESSURE (PSI)"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            width: parent.width
          }

          // 'some' — at least one thread stalled on memory.
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              id: psiSomeLabel
              textFormat: Text.PlainText
              text: "SOME"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              anchors.baseline: psiSomeLabel.baseline
              text: Model.formatPsiPct(root.ramState.psiSome10)
              color: root.usageColor(root.ramState.psiSome10)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
            Text {
              textFormat: Text.PlainText
              text: "of 10s, any thread stalled"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          // 'full' — all threads blocked.
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              id: psiFullLabel
              textFormat: Text.PlainText
              text: "FULL"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              anchors.baseline: psiFullLabel.baseline
              text: Model.formatPsiPct(root.ramState.psiFull10)
              color: root.usageColor(root.ramState.psiFull10)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
            Text {
              textFormat: Text.PlainText
              text: "all threads stalled"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Usage history section (same as the other stats) ----
        PanelSectionHeader {
          text: "USAGE HISTORY"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Item {
          width: parent.width
          height: Style.space(60)
          clip: true
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
          }
          BarGraph {
              anchors.fill: parent
              up: root.ramGraphHeights
              style: "line"
            }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Distribution section ----
        // User / system / free / swap, each as a labeled value with a thin
        // proportional bar. The first three sum to total; swap is its own gauge
        // against the swap allocation. Colors mirror the usage thresholds so a
        // hot user allocation jumps out.
        PanelSectionHeader {
          text: "DISTRIBUTION"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          width: parent.width
        }

        // user = used, fraction of total.
        Row {
          width: parent.width
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: "USER"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatRamSize(root.ramState.used)
            color: root.usageColor(root.ramUsedPct)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Item {
            width: Style.space(90)
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
              radius: root.cornerTiny
            }
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(1), Math.round(parent.width * (root.ramState.total > 0 ? Math.min(1, Math.max(0, root.ramState.used / root.ramState.total)) : 0)))
              height: parent.height
              radius: root.cornerTiny
              color: root.cpuData
            }
          }
        }

        // system = reclaimable page cache, fraction of total.
        Row {
          width: parent.width
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: "SYSTEM"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatRamSize(root.ramState.system)
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Item {
            width: Style.space(90)
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
              radius: root.cornerTiny
            }
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(1), Math.round(parent.width * (root.ramState.total > 0 ? Math.min(1, Math.max(0, root.ramState.system / root.ramState.total)) : 0)))
              height: parent.height
              radius: root.cornerTiny
              color: root.cpuData
            }
          }
        }

        // free, fraction of total.
        Row {
          width: parent.width
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: "FREE"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatRamSize(root.ramState.free)
            color: root.cpuText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Item {
            width: Style.space(90)
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
              radius: root.cornerTiny
            }
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(1), Math.round(parent.width * (root.ramState.total > 0 ? Math.min(1, Math.max(0, root.ramState.free / root.ramState.total)) : 0)))
              height: parent.height
              radius: root.cornerTiny
              color: root.cpuData
            }
          }
        }

        // swap, fraction of swap total; dimmed/absent when no swap is set up.
        Row {
          visible: root.ramState.swapTotal > 0
          width: parent.width
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: "SWAP"
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            textFormat: Text.PlainText
            text: Model.formatRamSize(root.ramState.swapUsed)
            color: root.usageColor(root.ramState.swapTotal > 0 ? 100 * root.ramState.swapUsed / root.ramState.swapTotal : 0)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: "/ " + Model.formatRamSize(root.ramState.swapTotal)
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          Item {
            Layout.fillWidth: true
            height: 1
          }
          Item {
            width: Style.space(90)
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
              radius: root.cornerTiny
            }
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(1), Math.round(parent.width * (root.ramState.swapTotal > 0 ? Math.min(1, Math.max(0, root.ramState.swapUsed / root.ramState.swapTotal)) : 0)))
              height: parent.height
              radius: root.cornerTiny
              color: root.cpuData
            }
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Top memory processes ----
        PanelSectionHeader {
          text: "TOP MEMORY PROCESSES"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          width: parent.width
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            // Always render exactly `topRamProcesses` row slots so the dropdown
            // height stays fixed no matter how many processes are resident.
            model: (function() { var a = []; for (var i = 0; i < root.topRamProcesses; i++) a.push(i); return a })()
            Item {
              required property int modelData
              readonly property var info: root.ramTopProcs[modelData]
              width: parent.parent.width
              height: Style.space(22)
              Row {
                visible: modelData < root.ramTopProcs.length
                width: parent.width
                height: parent.height

                // Name: fills the space left over by pinned pid + size columns.
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.comm : ""
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - Style.space(120))
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.pid : ""
                  width: Style.space(56)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: Style.space(4)
                  height: 1
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(60)
                  text: info ? Model.formatRss(info.rss / 1024) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
          }
        }
      }

      // ==================== Battery body ==============================
      Column {
        visible: root.activeStat && root.activeStat.id === "battery"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // ---- Setup / absent state ----
        Column {
          visible: !root.batteryState.ready
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "NO BATTERY"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            width: parent.width
          }
          Text {
            textFormat: Text.PlainText
            text: "No battery was found on this system."
            color: root.cpuDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- Live view ----
        Column {
          visible: root.batteryState.ready
          width: parent.width
          spacing: Style.space(10)

          // Hero: big battery glyph (no % inside), with the status + time +
          // % readout to its right. Tinted by the (reversed) charge thresholds.
          Row {
            width: parent.width
            spacing: Style.space(14)

            // Big icon: a large square holding just the battery glyph.
            Item {
              width: Style.space(120)
              height: Style.space(120)
              Text {
                anchors.fill: parent
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.batteryIconGlyph()
                // Same rule as the bar icon: while charging, always calm,
                // regardless of charge level.
                color: root.batteryState.charging ? root.cpuText : root.batteryColor(root.batteryState.pct)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.space(84)
                font.bold: true
              }
            }

            // Caption block: status, time-to-full/empty, then the % below it.
            Column {
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: root.batteryStatusText
                color: root.cpuDim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // The time readout: "full in 2:05" / "2:05 left" / "full".
              Text {
                textFormat: Text.PlainText
                text: root.batteryState.charging && root.batteryTimeText !== "--"
                        ? "full in " + root.batteryTimeText
                        : (root.batteryState.discharging ? root.batteryTimeText + " left" : "fully charged")
                color: root.batteryColor(root.batteryState.pct)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              // The % readout sits below the time, its own line.
              Text {
                textFormat: Text.PlainText
                text: Model.batteryPctText(root.batteryState.pct)
                color: root.batteryColor(root.batteryState.pct)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }
          }

          PanelSeparator {
            foreground: root.cpuText
          }

          // ---- Power profile picker ---------------------------------------
          // Same look, feel and click action as omarchy.power's profile row:
          // one bordered button per available profile, the active one shown
          // filled, hover/keyboard-cursor highlighting the target, and a click
          // (or Enter) applying it per the current ac/battery state.
          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            width: parent.width
          }

          Row {
            id: powerProfileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.powerProfiles.length > 0
              ? (width - spacing * (root.powerProfiles.length - 1)) / root.powerProfiles.length
              : 0

            Repeater {
              model: root.powerProfiles
              Button {
                required property var modelData
                required property int index
                width: powerProfileRow.cellWidth
                iconText: Model.powerProfileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.cpuText
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activePowerProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setPowerProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }

          // ---- Battery details: one stat per row (label left / value right) ----
          PanelSectionHeader {
            text: "BATTERY DETAILS"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            width: parent.width
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            // Power (W) — signed: +charging / -discharge.
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "POWER"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: Model.formatWatts(root.batteryState.power); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Current (mA / A).
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "CURRENT"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: Model.formatMillis(root.batteryState.current); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Voltage (V).
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "VOLTAGE"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: (root.batteryState.voltage >= 0 ? root.batteryState.voltage + "V" : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Health (%) — higher is better (batteryHealthColor).
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "HEALTH"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: Model.formatPct(root.batteryState.health); color: root.batteryHealthColor(root.batteryState.health); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Cycles.
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "CYCLES"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: (root.batteryState.cycles >= 0 ? root.batteryState.cycles + "" : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Temperature.
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "TEMP"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: Model.formatTemp(root.batteryState.temp); color: root.usageColor(root.batteryState.temp); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
            // Energy (remaining / full Wh).
            Row {
              visible: root.batteryState.energy >= 0 && root.batteryState.energyFull > 0
              width: parent.width
              spacing: Style.space(10)
              Text { textFormat: Text.PlainText; text: "ENERGY"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
              Item { Layout.fillWidth: true; height: 1 }
              Text { textFormat: Text.PlainText; text: Math.min(root.batteryState.energy, root.batteryState.energyFull) + "Wh / " + root.batteryState.energyFull + "Wh"; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            }
          }

          PanelSeparator {
            foreground: root.cpuText
          }

          // ---- Charge history (the battery's own usage graph) ----
          PanelSectionHeader {
            text: "CHARGE HISTORY"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Item {
            width: parent.width
            height: Style.space(60)
            clip: true
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
            }
            BarGraph {
              anchors.fill: parent
              up: root.batteryGraphHeights
              style: "line"
            }
          }

          PanelSeparator {
            foreground: root.cpuText
          }

          // ---- Top processes (drain proxy: top CPU consumers) ----
          PanelSectionHeader {
            text: "TOP PROCESSES"
            foreground: root.cpuText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            width: parent.width
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: (function() { var a = []; for (var i = 0; i < root.topBatteryProcesses; i++) a.push(i); return a })()
              Item {
                required property int modelData
                readonly property var info: root.batteryTopProcs[modelData]
                width: parent.parent.width
                height: Style.space(22)
                Row {
                  visible: modelData < root.batteryTopProcs.length
                  width: parent.width
                  height: parent.height
                  Text {
                    textFormat: Text.PlainText
                    text: info ? info.comm : ""
                    elide: Text.ElideRight
                    width: Math.max(0, parent.width - Style.space(120))
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.cpuText
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: info ? info.pid : ""
                    width: Style.space(56)
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.cpuText
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Item {
                    width: Style.space(4)
                    height: 1
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(60)
                    text: info ? Model.formatPct(info.pct) : ""
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.usageColor(info ? info.pct : 0)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
              }
            }
          }
        }
      }

      // ==================== Network body =================================
      Column {
        visible: root.activeStat && root.activeStat.id === "network"
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(10)

        // Headline: TRAFFIC caption, with download and upload each on their own
        // line. Each keeps its icon flush against its value, left-aligned, so
        // the two glyphs line up and the values extend right.
        Column {
          width: parent.width
          spacing: Style.space(2)

          Row {
            width: parent.width
            Text {
              id: netTrafficLabel
              textFormat: Text.PlainText
              text: "TRAFFIC"
              color: root.cpuDim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Item {
              Layout.fillWidth: true
              height: 1
            }
          }
          Row {
            spacing: Style.space(3)
            Text {
              textFormat: Text.PlainText
              text: "▼"
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.netDownText
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          Row {
            spacing: Style.space(3)
            Text {
              textFormat: Text.PlainText
              text: "▲"
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.netUpText
              color: root.cpuText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }

        // ---- Usage history ---- dual-axis: positive y = upload, negative y =
        // download (mirrors the disk I/O graph's write/read polarity).
        PanelSeparator {
          foreground: root.cpuText
        }

        PanelSectionHeader {
          text: "USAGE HISTORY"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Item {
          width: parent.width
          height: Style.space(70)
          clip: true
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.04)
          }
          // zero-line for the dual chart is drawn by BarGraph itself
          BarGraph {
            anchors.fill: parent
            dual: true
            up: (function(){ var v=[]; for (var i=0;i<root.netGraphHeights.length;i++) v.push(root.netGraphHeights[i].up); return v })()
            down: (function(){ var v=[]; for (var i=0;i<root.netGraphHeights.length;i++) v.push(root.netGraphHeights[i].down); return v })()
            style: "line"
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Connection details ---- labels left, live values right.
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "TOTAL DOWNLOAD"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: root.netTotalDownText; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "TOTAL UPLOAD"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: root.netTotalUpText; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "INTERNET"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: root.netOnlineText; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "PING"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: (root.netState.pingMs >= 0 ? Math.round(root.netState.pingMs) + " ms" : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "INTERFACE"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: root.netInterfaceText; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "PHYSICAL ADDR"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: (root.netState.mac !== "" ? root.netState.mac : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          // SSID: wifi only — the row is hidden entirely for ethernet.
          Row {
            visible: root.netState.ssid !== ""
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "SSID"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: root.netState.ssid; color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "LOCAL IP"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: (root.netState.ip !== "" ? root.netState.ip : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text { textFormat: Text.PlainText; text: "PUBLIC IP"; color: root.cpuDim; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
            Item { Layout.fillWidth: true; height: 1 }
            Text { textFormat: Text.PlainText; text: (root.netState.publicIp !== "" ? root.netState.publicIp : "--"); color: root.cpuText; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
          }
        }

        PanelSeparator {
          foreground: root.cpuText
        }

        // ---- Top processes by network ----
        PanelSectionHeader {
          text: "TOP PROCESSES"
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          width: parent.width
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            // Always render exactly `networkTopProcesses` row slots so the
            // dropdown height stays fixed no matter how many processes are
            // transferring. Ranks past the live count stay blank but hold
            // their row, so the panel never resizes.
            model: (function() { var a = []; for (var i = 0; i < root.networkTopProcesses; i++) a.push(i); return a })()
            Item {
              required property int modelData
              readonly property var info: root.netTopProcs[modelData]
              width: parent.parent.width
              height: Style.space(22)
              Row {
                visible: modelData < root.netTopProcs.length
                width: parent.width
                height: parent.height

                // Name: fills the space left over by pinned pid + up + down.
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.comm : ""
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - Style.space(210))
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: info ? info.pid : ""
                  width: Style.space(52)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: Style.space(6)
                  height: 1
                }
                // Upload and download rate columns share the same bold accent
                // styling; each is right-aligned with a fixed width so large
                // values have room and the two columns always line up.
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(64)
                  text: info ? Model.formatNetRate(info.up) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuData
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Item {
                  width: Style.space(6)
                  height: 1
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(76)
                  text: info ? Model.formatNetRate(info.down) : ""
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.cpuData
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
          }
        }
      }

      // ==================== Placeholder (other stats) =================
      Column {
        visible: !root.activeStat || (root.activeStat.id !== "cpu" && root.activeStat.id !== "gpu" && root.activeStat.id !== "disk" && root.activeStat.id !== "ram" && root.activeStat.id !== "battery" && root.activeStat.id !== "network")
        width: dropdownColumn.width - Style.space(8)
        spacing: Style.space(8)
        PanelSectionHeader {
          text: root.activeStat ? root.activeStat.label.toUpperCase() + " — coming soon" : ""
          foreground: root.cpuText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        Text {
          text: "Live values will appear here."
          color: root.cpuDim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  function toggleActiveStat() {
    if (root.activeStat) root.close()
  }

  function refresh() {
    root.sampleRefresh()
    if (root.activeStat) root.syncProcsPolling()
  }

  function open() { root.controller.show() }
  function close() { procsPollTimer.stop(); root.controller.hide() }

  // On close the panel fades out over ~140ms while still mapped, so we must
  // NOT null activeStat/activeButton here: nulling activeStat would repaint the
  // placeholder ("Live values will appear here.") into the fading panel, and
  // nulling activeButton would drop the anchor and re-lay-out to the top-left.
  // `opened` already drives the fade; state is reset when a stat is next opened.
  onOpenedChanged: {
    // no-op: content selection is immutable on close
  }

  // ---- IPC ---------------------------------------------------------------
  IpcHandler {
    target: "obi.stats"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.opened ? root.close() : root.open() }
    function refresh(): void { root.refresh() }
    function openStat(id: string): void { root.openStatId(id) }
    function openCpu(): void { root.openStatId("cpu") }
    function openGpu(): void { root.openStatId("gpu") }
    function openDisk(): void { root.openStatId("disk") }
    function openRam(): void { root.openStatId("ram") }
    function openBattery(): void { root.openStatId("battery") }
    function openNetwork(): void { root.openStatId("network") }
  }
}