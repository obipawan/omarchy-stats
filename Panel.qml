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
// distribution, and top memory processes. The remaining stats (battery,
// network) still show a placeholder.
//
// Per-widget settings come from the shell.json entry (see `setting()`), e.g.:
//   topProcesses       default 8     how many heavy processes to list (CPU)
//   refreshSeconds     default 2     base sample cadence (CPU + GPU + disk)
//   cpuRefreshSeconds  default base  CPU poll period, independent override
//   gpuRefreshSeconds  default base  GPU poll period, independent override
//   fileioRefreshSeconds default base  disk I/O poll period, independent override
//   diskMount          default /     filesystem monitored for space
//   diskTopProcesses   default 5     rows in the disk top-I/O table
//   historyMinutes     default 60    length of the usage-history window
// Set them with: omarchy bar set obi.stats <key> <value>
Panel {
  id: root
  moduleName: "obi.stats"
  ipcTarget: "obi.stats"
  manageIpc: false

  // The ordered list of stats (pure data, in Model.js).
  readonly property var defs: Model.statDefinitions()

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
  readonly property var cpuGraph: Model.scrollWindow(cpuHistory, historyBuckets)
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
  readonly property var gpuGraph: Model.scrollWindow(gpuHistory, historyBuckets)
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
  readonly property var diskIoWindow: Model.scrollIoWindow(diskHistory, historyBuckets)
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
  readonly property var ramGraph: Model.scrollWindow(ramHistory, historyBuckets)
  readonly property var ramGraphHeights: Model.normalize(ramGraph, 100)
  readonly property string ramMemText:
    (ramState.used >= 0 && ramState.total >= 0)
      ? Model.formatRamSize(ramState.used) + " / " + Model.formatRamSize(ramState.total)
      : "--"
  readonly property string ramSwapText:
    ramState.swapTotal > 0
      ? Model.formatRamSize(ramState.swapUsed) + " / " + Model.formatRamSize(ramState.swapTotal)
      : "off"

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

  // The bar host draws an accent pill under/over a module slot while one of
  // its dropdowns is open (see bar/Bar.qml `openPanelIndicator`). It defaults
  // to ~55% of the whole module slot — which sweeps under ALL stat icons at
  // once and looks off. obi.stats paints its own per-icon active highlight on
  // the clicked item, so shrink the host's pill to ~invisible. The hint must
  // be > 0 (the bar treats 0 as "unset" and falls back to the big default),
  // hence 1px.
  readonly property real openPanelIndicatorWidth: 1
  readonly property real openPanelIndicatorHeight: 1

  // Whether a stat renders as a live two-line % stack in the bar.
  function isLiveStat(stat) {
    if (!stat) return false
    var id = String(stat.id)
    return id === "cpu" || id === "gpu" || id === "disk" || id === "ram"
  }

  function barItemWidth(stat) {
    if (stat && String(stat.id) === "cpu") return root.cpuBarWidth
    if (stat && String(stat.id) === "gpu") return root.gpuBarWidth
    if (stat && String(stat.id) === "disk") return root.diskBarWidth
    if (stat && String(stat.id) === "ram") return root.ramBarWidth
    return Style.bar.iconSlot
  }

  function barItemHeight(stat) {
    if (stat && String(stat.id) === "cpu") return root.cpuBarHeight
    if (stat && String(stat.id) === "gpu") return root.gpuBarHeight
    if (stat && String(stat.id) === "disk") return root.diskBarHeight
    if (stat && String(stat.id) === "ram") return root.ramBarHeight
    return Style.bar.sizeHorizontal
  }

  // ---- Bar widgets: one clickable glyph per stat ------------------------
  implicitWidth: statRow.implicitWidth
  implicitHeight: statRow.implicitHeight

  Row {
    id: statRow
    spacing: Style.space(5)

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
        visible: stat.id !== "disk"
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        text: stat.label.toLowerCase()
        color: root.cpuText
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.bold: true
      }
      Text {
        id: pctLine
        visible: stat.id !== "disk"
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        text: root.livePctText(stat.id)
        color: root.livePctColor(stat.id)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.bold: true
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
    if (stat.id === "cpu") refreshCpu()
    else if (stat.id === "gpu") refreshGpu()
    else if (stat.id === "disk") refreshDisk()
    else if (stat.id === "ram") refreshRam()
    root.controller.show()
  }

  function openStatId(id) {
    var stat = Model.statById(root.defs, id)
    if (!stat) return false
    root.openStat(stat, null)
    return true
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
    root.cpuState = parsed
    var now = Date.now() / 1000
    root.cpuHistory = Model.appendHistory(root.cpuHistory, now, parsed.total, root.historySeconds)
  }

  Timer {
    id: cpuPollTimer
    interval: root.cpuRefreshSeconds * 1000
    repeat: true
    running: true
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
    running: true
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
    // Refresh shortly after so the panel reflects the new tool status once
    // the terminal work is done (install + doctor). Polling already covers
    // this; the extra kick just makes the setup card feel responsive.
    gpuPollTimer.restart()
    refreshGpu()
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
    root.diskState = parsed
    var now = Date.now() / 1000
    // Only a live sample feeds the I/O history graph.
    if (parsed.ready) root.diskHistory = Model.appendIoHistory(root.diskHistory, now, parsed.read, parsed.write, root.historySeconds)
  }

  Timer {
    id: diskPollTimer
    interval: root.fileioRefreshSeconds * 1000
    repeat: true
    running: true
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
    root.ramState = parsed
    var now = Date.now() / 1000
    // Only a live sample feeds the history graph.
    if (parsed.ready) root.ramHistory = Model.appendHistory(root.ramHistory, now, parsed.used / parsed.total * 100, root.historySeconds)
  }

  Timer {
    id: ramPollTimer
    interval: root.ramRefreshSeconds * 1000
    repeat: true
    running: true
    onTriggered: { if (!root.ramPolling) root.refreshRam() }
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
    return Model.sectionTitle(root.activeStat) + " — coming soon"
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

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      // Track: the full scale, always visible, dim.
      ShapePath {
        strokeWidth: gauge.arcWidth
        strokeColor: gauge.trackColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
          centerX: gauge.width / 2
          centerY: gauge.height / 2
          radiusX: gauge.arcRadius
          radiusY: gauge.arcRadius
          startAngle: gauge.dialStart
          sweepAngle: gauge.dialSweep
        }
      }

      // Soft under-glow beneath the value arc (backlit-ring stand-in). Both
      // arcs go transparent at rest so their round caps don't leave a dot.
      ShapePath {
        strokeWidth: gauge.arcWidth * 3
        strokeColor: gauge.arcVisible ? Qt.rgba(gauge.valueColor.r, gauge.valueColor.g, gauge.valueColor.b, 0.18) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
          centerX: gauge.width / 2
          centerY: gauge.height / 2
          radiusX: gauge.arcRadius
          radiusY: gauge.arcRadius
          startAngle: gauge.dialStart
          sweepAngle: gauge.dialSweep * gauge.fraction
        }
      }

      // Value: fills behind the needle, threshold-tinted.
      ShapePath {
        strokeWidth: gauge.arcWidth
        strokeColor: gauge.arcVisible ? gauge.valueColor : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
          centerX: gauge.width / 2
          centerY: gauge.height / 2
          radiusX: gauge.arcRadius
          radiusY: gauge.arcRadius
          startAngle: gauge.dialStart
          sweepAngle: gauge.dialSweep * gauge.fraction
        }
      }
    }

    // Faint tick ring just inside the arc; every fifth tick is a major.
    Repeater {
      model: gauge.tickCount

      Item {
        required property int index
        readonly property bool major: index % 5 === 0

        anchors.fill: parent
        rotation: gauge.dialStart + (index / (gauge.tickCount - 1)) * gauge.dialSweep - 270

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: gauge.arcWidth * 2 + (parent.major ? 0 : Style.space(2))
          width: parent.major ? Math.max(2, Style.space(2)) : 1
          height: parent.major ? Style.space(9) : Style.space(5)
          radius: width / 2
          color: parent.major ? gauge.majorTickColor : gauge.minorTickColor
        }
      }
    }

    // Hubless needle: a slender sliver that fades out toward the pivot.
    Item {
      anchors.fill: parent
      rotation: gauge.dialStart + gauge.fraction * gauge.dialSweep - 270

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: gauge.arcWidth * 2 + Style.space(8)
        width: Math.max(2, Style.space(3))
        height: gauge.diameter * 0.30
        radius: width / 2

        gradient: Gradient {
          GradientStop { position: 0.0; color: gauge.valueColor }
          GradientStop { position: 0.55; color: gauge.valueColor }
          GradientStop { position: 1.0; color: "transparent" }
        }
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

      onMoveRequested: function(dx, dy) { /* reserved for per-stat navigation */ }
      onActivateRequested: root.close()
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
          Row {
            id: historyBarsRow
            anchors.fill: parent
            spacing: Style.space(1)
            Repeater {
              model: root.cpuGraphHeights
              Item {
                required property real modelData
                width: Style.space(3)
                height: historyBarsRow.height
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  width: Style.space(3)
                  height: Math.max(Style.space(1), Math.round(modelData * parent.height))
                  color: root.cpuData
                }
              }
            }
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
            Row {
              id: gpuHistoryBarsRow
              anchors.fill: parent
              spacing: Style.space(1)
              Repeater {
                model: root.gpuGraphHeights
                Item {
                  required property real modelData
                  width: Style.space(3)
                  height: gpuHistoryBarsRow.height
                  Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: Style.space(3)
                    height: Math.max(Style.space(1), Math.round(modelData * parent.height))
                    color: root.cpuData
                  }
                }
              }
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
          // Zero line at the vertical middle.
          Rectangle {
            width: parent.width
            height: 1
            y: parent.height / 2
            color: Qt.rgba(root.cpuText.r, root.cpuText.g, root.cpuText.b, 0.12)
          }
          Row {
            id: ioGraphRow
            anchors.fill: parent
            spacing: Style.space(1)
            Repeater {
              model: root.diskIoHeights
              Item {
                required property var modelData
                width: Style.space(3)
                height: ioGraphRow.height
                // Write bar grows UP from the zero line (positive).
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: parent.height / 2 - Math.max(1, Math.round(modelData.write * parent.height / 2))
                  width: Style.space(3)
                  height: Math.max(1, Math.round(modelData.write * parent.height / 2))
                  color: root.cpuData
                }
                // Read bar grows DOWN from the zero line (negative).
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: parent.height / 2
                  width: Style.space(3)
                  height: Math.max(1, Math.round(modelData.read * parent.height / 2))
                  color: root.cpuDim
                }
              }
            }
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

        // Memory usage speedometer, centered.
        Item {
          width: parent.width
          Layout.alignment: Qt.AlignHCenter
          RamGauge {
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
          Row {
            id: ramHistoryBarsRow
            anchors.fill: parent
            spacing: Style.space(1)
            Repeater {
              model: root.ramGraphHeights
              Item {
                required property real modelData
                width: Style.space(3)
                height: ramHistoryBarsRow.height
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  width: Style.space(3)
                  height: Math.max(Style.space(1), Math.round(modelData * parent.height))
                  color: root.cpuData
                }
              }
            }
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

      // ==================== Placeholder (other stats) =================
      Column {
        visible: !root.activeStat || (root.activeStat.id !== "cpu" && root.activeStat.id !== "gpu" && root.activeStat.id !== "disk" && root.activeStat.id !== "ram")
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
    if (root.activeStat && root.activeStat.id === "cpu") refreshCpu()
    else if (root.activeStat && root.activeStat.id === "gpu") refreshGpu()
    else if (root.activeStat && root.activeStat.id === "disk") refreshDisk()
    else if (root.activeStat && root.activeStat.id === "ram") refreshRam()
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }

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
  }
}