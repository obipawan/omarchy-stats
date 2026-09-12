#!/bin/bash
# obi.stats disk + I/O sampler.
#
# One sampler drives both the bar item (free/used space) and the dropdown
# (aggregate read/write history + top processes by I/O), so a single poll tick
# keeps them consistent:
#
#   mount\t<path>              filesystem being monitored (default /)
#   fsTotal\t<bytes>           total size of the mount
#   fsFree\t<bytes>            available (free) space
#   fsUsed\t<bytes>            used space
#   fsUsePct\t<percent>        used percentage (0..100) from df
#   read\t<KB/s>               aggregate disk read rate (whole disks)
#   write\t<KB/s>              aggregate disk write rate
#   proc\t<pid>\t<readKB/s>\t<writeKB/s>\t<comm>   top by read+write, desc
#
# Data sources (no iotop/iostat/pidstat dependency, all /proc + df):
#   - df         for space
#   - /proc/diskstats for aggregate throughput (whole disks, minor 0)
#   - /proc/<pid>/io    for per-process read/write bytes
#
# Usage: disk.sh [window-seconds] [mount]
#   window-seconds  sample window for rate computation (default 0.5)
#   mount           filesystem to monitor for space (default /)

WINDOW="${1:-0.5}"
MOUNT="${2:-/}"
# Rows of per-process I/O to resolve names for (the panel keeps fewer).
DISK_TOP_N="${DISK_TOP_N:-12}"

# --- disk space -----------------------------------------------------------
# df -PB1 prints: Filesystem 1-bytes Used Available Capacity Mounted on
df_line=$(df -PB1 "$MOUNT" 2>/dev/null | tail -1)
if [ -n "$df_line" ]; then
  df_total=$(echo "$df_line" | awk '{print $2}')
  df_used=$(echo "$df_line" | awk '{print $3}')
  df_avail=$(echo "$df_line" | awk '{print $4}')
  df_pct=$(echo "$df_line" | awk '{print $5}' | tr -d '%')
fi
[ -n "${df_total:-}" ] || df_total=0
[ -n "${df_used:-}" ] || df_used=0
[ -n "${df_avail:-}" ] || df_avail=0
[ -n "${df_pct:-}" ] || df_pct=-1
# printf (not echo) so the \t is a real tab separator for the panel.
printf "mount\t%s\n" "$MOUNT"
printf "fsTotal\t%s\n" "$df_total"
printf "fsFree\t%s\n" "$df_avail"
printf "fsUsed\t%s\n" "$df_used"
printf "fsUsePct\t%s\n" "$df_pct"

# --- aggregate throughput (whole disks: minor == 0) -----------------------
# /proc/diskstats fields: major minor name reads _ sectors-read _ writes _
# sectors-written ...; summing sector counters over whole disks avoids
# double-counting their partitions.
snapshot_diskstats() {
  awk '$2 == 0 { r += $6; w += $10 } END { printf "%d %d", r, w }' /proc/diskstats 2>/dev/null
}

# --- per-process byte counters -------------------------------------------
# Read every /proc/<pid>/io file in a single awk pass. We list the files via a
# shell glob and read each with `getline < file` rather than passing them as
# awk arguments: a process that exits mid-scan makes one io file vanish, which
# would make plain `awk file1 file2 ...` abort fatally partway through. getline
# returns -1 on a missing file and we just move on, so a dying process can't
# truncate the scan. Each io file's pid comes from its path; the cumulative
# read_bytes / write_bytes (minus cancelled writes) land on it.
snapshot_io() {
  awk '
  BEGIN {
    cmd = "printf '\''%s\\n'\'' /proc/[0-9]*/io"
    while ((cmd | getline f) > 0) {
      pid = f; sub(/\/io$/, "", pid); sub(/^.*\//, "", pid)
      rb = 0; wb = 0; cw = 0
      while ((getline line < f) > 0) {
        if (line ~ /^read_bytes:/)        { n = split(line, a, " "); rb = a[2] }
        else if (line ~ /^write_bytes:/)  { n = split(line, a, " "); wb = a[2] }
        else if (line ~ /^cancelled_write_bytes:/) { n = split(line, a, " "); if (a[2] < 0) cw = -a[2]; else cw = a[2] }
      }
      close(f)
      print pid, rb - cw, wb
    }
    close(cmd)
  }'
}

# --- sample #1 ------------------------------------------------------------
ds1=$(snapshot_diskstats)
io1=$(snapshot_io)
sleep "$WINDOW"
# --- sample #2 ------------------------------------------------------------
ds2=$(snapshot_diskstats)
io2=$(snapshot_io)

r1=${ds1% *}; w1=${ds1#* }
r2=${ds2% *}; w2=${ds2#* }

# Sectors (512B) -> KiB: sectors * 512 / 1024 = sectors * 0.5; then / window.
awk -v r1="$r1" -v r2="$r2" -v w1="$w1" -v w2="$w2" -v win="$WINDOW" '
BEGIN {
  dr = r2 - r1; if (dr < 0) dr = 0
  dw = w2 - w1; if (dw < 0) dw = 0
  printf "read\t%.1f\nwrite\t%.1f\n", dr * 0.5 / win, dw * 0.5 / win
}
'

# --- per-process rates (sorted by read+write, desc) ----------------------
awk -v p1="$io1" -v p2="$io2" -v win="$WINDOW" -v nmax="$DISK_TOP_N" '
BEGIN {
  split(p1, a1, "\n"); split(p2, a2, "\n")
  for (i = 1; i <= length(a1); i++) {
    if (a1[i] == "") continue
    n = split(a1[i], f, " ")
    if (n < 3) continue
    r1[f[1]] = f[2]; w1[f[1]] = f[3]
  }
  rows = 0
  for (i = 1; i <= length(a2); i++) {
    if (a2[i] == "") continue
    n = split(a2[i], f, " ")
    if (n < 3) continue
    pid = f[1]
    if (!(pid in r1)) continue           # process ended between samples
    dr = f[2] - r1[pid]; if (dr < 0) dr = 0
    dw = f[3] - w1[pid]; if (dw < 0) dw = 0
    r = dr / 1024 / win                  # bytes -> KiB / sec
    w = dw / 1024 / win
    if (r < 0.05 && w < 0.05) continue   # skip idle processes
    rows++
    out[rows,1] = pid; out[rows,2] = r; out[rows,3] = w; out[rows,4] = i
  }
  # insertion sort by (read+write) descending
  for (i = 1; i <= rows; i++)
    for (j = i + 1; j <= rows; j++)
      if (out[j,2] + out[j,3] > out[i,2] + out[i,3]) {
        for (k = 1; k <= 4; k++) { t = out[i,k]; out[i,k] = out[j,k]; out[j,k] = t }
      }
  # Resolve names only for the rows the panel is likely to keep (top nmax).
  for (i = 1; i <= rows; i++) {
    if (i > nmax) break
    call = "cat /proc/" out[i,1] "/comm 2>/dev/null"
    comm = "?"
    if ((call | getline comm) > 0) { }
    close(call)
    printf "proc\t%s\t%.1f\t%.1f\t%s\n", out[i,1], out[i,2], out[i,3], comm
  }
}
'
