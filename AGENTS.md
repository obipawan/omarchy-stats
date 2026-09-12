# ⚠️️ READ THIS FIRST — do not skip

Operating context for any agent (or human) working on **obi.stats**, an Omarchy
status-bar plugin. Start here before touching anything. The single most
important caveat is reproduced up front so it cannot be missed:

> **Development happens in the LIVE-INSTALLED copy; the repository is only the
> source of truth.** Editing files in this repo does **not** change the running
> shell (which loads `~/.config/omarchy/plugins/obi.stats/`), and tested code in
> that live copy is **not** automatically reflected here. You must **develop →**
> **test live** → **back-source into the repo → commit**. See "THE CAVEAT"
> below — it is the whole point of this file.

## What this is

A system-stats bar-widget plugin for [Omarchy](https://omarchy.org/) (Hyprland).
Adds a row of clickable stat items (CPU, GPU, disk, RAM, battery, network);
CPU, GPU, disk, RAM and battery are fully wired (bars, live dropdowns with
history graphs, top-processes tables, theme-aware tinting). The network
dropdown is the remaining placeholder.

```
manifest.json   plugin manifest (id obi.stats, kind bar-widget)
Panel.qml       bar widget + dropdown UI host (QML)
Model.js        pure, node-testable data/logic helpers
cpu.sh          /proc-based CPU sampler (no mpstat/sar/htop deps)
gpu.sh          vendor-agnostic GPU sampler (Intel/NVIDIA/AMD) + --doctor
disk.sh         df + /proc diskstats + /proc/<pid>/io sampler
ram.sh          /proc/meminfo + per-process RSS sampler
battery.sh      /sys/class/power_supply + per-process drain sampler (time uses upower)
```

> **`cpu.sh`, `gpu.sh`, `disk.sh`, `ram.sh`, `battery.sh` must stay executable
> (`chmod +x`).** The shell runs them as programs; if the bit is lost (some
> manual copies strip it), the sampler silently fails and the dropdown shows
> stale/empty data. Git preserves the `100755` mode in this repo — just don't
> drop them when back-sourcing.

> **Battery "top processes" are a CPU-drain proxy.** Linux exposes no per-process
> power meter, so `battery.sh` lists the top CPU consumers (the dominant
> battery drain). It's labelled as such in the panel. Don't present those % as
> measured watts.

> **GPU is vendor-agnostic + best-effort.** `gpu.sh` shells out to whichever
> helper the detected GPU needs (`intel_gpu_top`, `nvidia-smi`, `rocm-smi`/
> `radeontop`) and ships an in-panel installer hint + `gpu.sh --doctor` when the
> tool is absent. This box has an Intel Iris 6100 with **no** GPU tooling
> installed, so we validated the Intel/NVIDIA/AMD parsing paths with fake-tool
> stubs and live-tested the no-tool fallback only.

## THE CAVEAT: two copies, and how to develop

This git repo is **not** what the running Omarchy shell loads.

- **Live copy (edit + test here):** `~/.config/omarchy/plugins/obi.stats/`
  Omarchy watches this directory and hot-reloads it. This is the sanctioned
  third-party plugin dev location.
- **This repo (source of truth):** a git history. Others install it from here
  via `omarchy plugin add <git-url>`.

**Workflow — develop live, test, then back-source into the repo:**

```bash
# 1. Edit the live copy
$EDITOR ~/.config/omarchy/plugins/obi.stats/Panel.qml
#    (or Model.js / cpu.sh / manifest.json)

# 2. Apply + verify (see Testing below)

# 3. Back-source the tested code into the repo and commit
cp ~/.config/omarchy/plugins/obi.stats/{Panel.qml,Model.js,cpu.sh,manifest.json} .
git add -A
git commit -m "summary of the change"
```

Do NOT work only in this repo and expect it to appear in the shell. Do NOT edit
`/usr/share/omarchy/` ever (it is package-owned and overwritten on update). Keep
the live copy and this repo in sync before tagging a release, or add a small
sync script if iteration is heavy.

## Testing (what actually works)

| Check | Command |
|-------|---------|
| Plugin loads | `omarchy plugin list` (expect id `obi.stats`, enabled) |
| Adjust placement/settings | `omarchy bar set obi.stats <key> <value>` |
| Open a dropdown | `omarchy-shell obi.stats openCpu` (bar-widget, not a shell panel) |
| No QML errors | `journalctl --user --since "2 min ago"` → grep `Panel.qml` |
| See it on screen | `grim -t png /tmp/x.png` then inspect/OCR |
| Sampler works | `~/.config/omarchy/plugins/obi.stats/cpu.sh 0.5` → `total`/`core`/`proc` lines |
| Pure logic | `node -e 'const M=require("./Model.js"); ...'` |

## Hard rules / things that have burned us

- **Always `omarchy restart shell` after non-trivial edits.** The *incremental*
  hot-reload does **not** clear the cached `Model.js`, so the shell can keep
  running stale code after you fixed it. Restart = guaranteed fresh.
- **The id is `obi.stats`, NOT `omarchy.stats`.** Omarchy reserves the
  `omarchy.*` namespace for its own plugins; renaming to it breaks discovery.
- **Never edit `/usr/share/omarchy/`.** Read-only reference is fine.
- **Don't run `omarchy dev ...`** — those target Omarchy *core* development
  (`omarchy dev link` = point at an Omarchy source checkout). Not applicable to
  this standalone plugin.
- **Wrap agent-config edits:** writing to `~/.config/omarchy/...` should go
  through the `omarchy` skill for privilege/convention rules.

## Useful conventions already in the code

- **Settings via widget entry:** per-widget config is read from the bar layout
  entry in `~/.config/omarchy/shell.json` using `setting("key", default)` and set
  with `omarchy bar set obi.stats <key> <value>`. Existing keys:
  `refreshSeconds` (2), `historyMinutes` (60), `topProcesses` (8),
  `calmLimit` (30), `mildLimit` (60), plus per-stat overrides
  (`cpuRefreshSeconds`, `gpuRefreshSeconds`, `fileioRefreshSeconds`,
  `ramRefreshSeconds`, `batteryRefreshSeconds`) and battery tints
  (`batteryAlarmPct` 20, `batteryMildPct` 60).
- **Theme-cohesive colors:** CPU tint maps to semantic roles
  `foreground` / `accent` / `urgent` from `colors.toml`, so it adapts to any theme.
- **Pure logic stays in Model.js** as node-testable functions (e.g.
  `scrollWindow`, `parseCpuOutput`, `topProcRows`); keep parsing/business logic
  out of Panel.qml where possible.

## Boundaries

- **Out of scope:** Omarchy core development, migrations, `omarchy dev` workflows.
- **Security:** `cpu.sh` runs inside the long-lived `omarchy-shell` process; keep
  it to `/proc` reads. Review before trusting any third-party code added here.