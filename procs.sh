#!/bin/bash
# obi.stats consolidated per-process sampler.
#
# The four "top processes" tables (CPU %, RAM RSS, disk I/O, battery drain
# proxy = top CPU) all previously came from FOUR independent samplers that
# each scanned the whole /proc process tree on every poll tick. This single
# sampler reads each process ONCE per pass (stat + io + status) and emits one
# row per process carrying every metric the panel needs:
#
#   proc\t<pid>\t<cpu%>\t<readKB/s>\t<writeKB/s>\t<rssKiB>\t<comm>
#
#   cpu%        % of one core over the window (100 * dticks / (CLK_TCK * win))
#   readKB/s    bytes_read delta / 1024 / win   (cancelled writes are excluded)
#   writeKB/s   bytes_write delta / 1024 / win
#   rssKiB      current resident set size (VmRSS, KiB)
#   comm        process name from /proc/<pid>/status (Name)
#
# One row per process; the panel ranks per metric to serve each dropdown. Pure
# /proc reads + awk, no mpstat/iotop/htop dependency. Because it is only needed
# for the dropdown tables, the panel runs it on-demand (while a relevant
# dropdown is open) rather than on every tick.
#
# Usage: procs.sh [window-seconds]       (default 0.5)

WINDOW="${1:-0.5}"

# Windowed snapshot: read stat + io + status for every pid once, print
#   pid utime stime read_bytes cancelled_write_bytes write_bytes rssKiB name
snapshot() {
  awk '
  BEGIN {
    cmd = "printf '\''%s\\n'\'' /proc/[0-9]*"
    while ((cmd | getline d) > 0) {
      pid = d; sub(/^.*\//, "", pid)
      u = 0; s = 0; rd = 0; wr = 0; cw = 0; rss = 0; comm = ""
      # --- stat: the parenthesised field is the process comm (TASK_COMM_LEN,
      #     same as /proc/<pid>/comm, matching cpu/disk/battery tables). Its
      #     comm may contain spaces, so split on ") " first; then b[12]=orig
      #     field 14 (utime), b[13]=orig 15 (stime).
      f = d "/stat"
      if ((getline l < f) >= 0) {
        n = split(l, a, ") ")
        if (n >= 2) {
          comm = a[1]; sub(/^[0-9]+ \(/, "", comm)
          m = split(a[2], b, " "); if (m >= 13) { u = b[12] + 0; s = b[13] + 0 }
        }
      }
      close(f)
      # --- io (single pass over the file for all three counters) ---
      f = d "/io"
      while ((getline l < f) > 0) {
        if (l ~ /^read_bytes:/)                { split(l, x, " "); rd = x[2] }
        else if (l ~ /^write_bytes:/)          { split(l, x, " "); wr = x[2] }
        else if (l ~ /^cancelled_write_bytes:/){ split(l, x, " "); cw = x[2] < 0 ? -x[2] : x[2] }
      }
      close(f)
      # --- status: VmRSS (KiB) ---
      f = d "/status"
      while ((getline l < f) > 0) {
        if (l ~ /^VmRSS:/) { split(l, x, " "); rss = x[2] + 0 }
      }
      close(f)
      print pid, u, s, rd, cw, wr, rss, comm
    }
    close(cmd)
  }'
}

# --- sample #1 -------------------------------------------------------------
p1=$(snapshot)
sleep "$WINDOW"
# --- sample #2 -------------------------------------------------------------
p2=$(snapshot)

# Delta + rank everything. writeKB/s uses (write_bytes - cancelled_write_bytes).
awk -v p1="$p1" -v p2="$p2" -v win="$WINDOW" -v clk=100 '
BEGIN {
  split(p1, a1, "\n"); split(p2, a2, "\n")
  for (i = 1; i <= length(a1); i++) {
    if (a1[i] == "") continue
    n = split(a1[i], f, " ")
    if (n < 3) continue
    t1[f[1]]   = f[2] + f[3]            # utime + stime (ticks)
    r1[f[1]]   = f[4]                   # read_bytes
    w1[f[1]]   = f[6] - f[5]            # write_bytes - cancelled
  }
  # p2 already has the live rss/name; carry them through.
  for (i = 1; i <= length(a2); i++) {
    if (a2[i] == "") continue
    n = split(a2[i], f, " ")
    if (n < 3) continue
    pid = f[1]
    if (!(pid in t1)) continue          # process appeared between samples
    dticks = (f[2] + f[3]) - t1[pid]; if (dticks < 0) dticks = 0
    dr = f[4] - r1[pid]; if (dr < 0) dr = 0
    dw = (f[6] - f[5]) - w1[pid]; if (dw < 0) dw = 0
    cpu = (100.0 * dticks) / (clk * win)
    rd  = dr / 1024 / win
    wr  = dw / 1024 / win
    # Emit for every pid so the panel can rank CPU / RAM / I/O independently.
    printf "proc\t%s\t%.1f\t%.1f\t%.1f\t%s\t%s\n", pid, cpu, rd, wr, f[7], f[8]
  }
}'