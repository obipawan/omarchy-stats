# obi.stats

A system-stats monitoring widget for the [Omarchy](https://omarchy.org/) status bar
(Hyprland). It adds a row of clickable bar items for **CPU**, **GPU**, **Disk**,
**RAM**, **Battery** and **Network**; each opens a dropdown with live values.

## Features (current)

- **CPU** — fully wired end to end:
  - Aggregate usage with theme-aware color tinting (thresholds configurable).
  - Per-core usage bars.
  - A real **scrolling history graph** (one live sample per column, newest pinned
    right, old values pushed left; window length configurable).
  - **Top processes** table (name · PID · %cpu) with fixed column alignment.
  - A two-line `cpu / NN%` text in the bar instead of an icon.
- **GPU** — vendor-agnostic monitor for Intel / NVIDIA / AMD:
  - Live usage headline, per-engine bars, memory used/total, temperature.
  - The same scrolling **usage history graph** as CPU, plus **top GPU processes**
    (by memory when the driver reports them).
  - A two-line `gpu / NN%` text in the bar.
  - **Auto setup guidance**: if the tool for your GPU isn't installed, the panel
    tells you exactly what to install and how to verify — no config hunting.
- Disk, RAM, Battery, Network — bar items present; dropdowns are placeholders
  for now (next steps).

## Install

From a terminal:

```bash
omarchy plugin add <your-github>/omarchy-stats.git --enable
```

Omarchy clones the repo, validates `manifest.json`, and installs it under
`~/.config/omarchy/plugins/obi.stats/`. Then place it in a bar section:

```bash
omarchy bar put obi.stats --section center
```

> Permissions: the sampler scripts (`cpu.sh`, `gpu.sh`) must be executable. Git
> preserves the executable bit set in this repo.

### Manual / from source

Copy the repository contents into `~/.config/omarchy/plugins/obi.stats/`
(`chmod +x cpu.sh gpu.sh`), then `omarchy restart shell`.

## Configuration

Per-widget settings are stored in the bar layout entry in `~/.config/omarchy/shell.json`
and writable via `omarchy bar set`:

```bash
omarchy bar set obi.stats refreshSeconds  2        # CPU sample period
omarchy bar set obi.stats historyMinutes 60        # history graph window
omarchy bar set obi.stats topProcesses    8        # rows in the process table
omarchy bar set obi.stats calmLimit       30       # usage color tier: below = calm
omarchy bar set obi.stats mildLimit       60       # usage color tier: at/above = alarm
```

| Setting | Default | Effect |
|---------|---------|--------|
| `refreshSeconds` | 2 (we use 1) | CPU sampling cadence |
| `historyMinutes` | 60 | how long the moving graph window spans |
| `topProcesses` | 8 | how many heavy processes to list |
| `calmLimit` / `mildLimit` | 30 / 60 | usage-coloring thresholds |
| `topProcesses` | 8 | process-table row count |

The CPU `%` color maps to three **semantic theme roles** so it stays cohesive
across every Omarchy theme: `< calmLimit` → `foreground`, `calmLimit..mildLimit`
→ `accent`, `>= mildLimit` → `urgent`.

## Architecture

```
manifest.json   plugin manifest (id obi.stats, kind bar-widget)
Panel.qml       bar-widget + dropdown UI host (QML)
Model.js        pure, node-testable data/logic helpers
cpu.sh          /proc-based CPU sampler (aggregate, per-core, per-process)
gpu.sh          vendor-agnostic GPU sampler (Intel/NVIDIA/AMD) + --doctor
```

- `Panel.qml` is the bar-widget entry point *and* the dropdown host — one widget
  paints the six stat buttons and pops up a `KeyboardPanel`, mirroring how
  `omarchy.network` works.
- `cpu.sh` reads `/proc/stat` + `/proc/<pid>/stat` twice (a configurable window
  apart) and prints tab-separated `total` / `core` / `proc` lines. No
  `mpstat`/`sar`/`htop` dependency.
- `gpu.sh` detects the GPU (Intel / NVIDIA / AMD) and hands off to the matching
  helper — `intel_gpu_top`, `nvidia-smi` or `rocm-smi`/`radeontop` — printing a
  shared `vendor` / `model` / `status` / `total` / `temp` / `mem*` / `engine` /
  `proc` schema. `gpu.sh --doctor` prints step-by-step setup for the detected
  GPU. Run `omarchy-shell obi.stats openGpu` to see the panel's setup guidance
  when the tool is missing.
- `Model.js` parses the sampler output and implements the scrolling history
  window and process-table caps as pure functions (test with `node`).

### Why `obi.stats` and not `omarchy.stats`

Omarchy reserves the `omarchy.*` namespace for its own bundled plugins; user
plugins must use the `<username>.` prefix (or another namespace). The id also
matches the install directory, which keeps `cpu.sh` discoverable.

## Notes

- The history graph is a true **sliding window**: each refresh drops the oldest
  sample on the left and appends the newest on the right.
- On near-monochrome themes the usage-color tiers are intentionally subtle
  (theme `foreground`/`accent`/`urgent` are close together).

## License

MIT — see [LICENSE](LICENSE).