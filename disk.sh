#!/bin/bash
# obi.stats disk + I/O sampler.
#
# One sampler drives both the bar item (free/used space) and the dropdown's
# aggregate read/write history, keeping them consistent:
#
#   mount\t<path>              filesystem being monitored (default /)
#   fsTotal\t<bytes>           total size of the mount
#   fsFree\t<bytes>            available (free) space
#   fsUsed\t<bytes>            used space
#   fsUsePct\t<percent>        used percentage (0..100) from df
#   read\t<KB/s>               aggregate disk read rate (whole disks)
#   write\t<KB/s>              aggregate disk write rate
#
# Data sources (no iotop/iostat/pidstat dependency, all /proc + df):
#   - df         for space
#   - /proc/diskstats for aggregate throughput (whole disks, minor 0)
#
# NOTE: the "top I/O processes" table is no longer produced here. It comes from
# the consolidated procs.sh sampler, so this always-on poll reads only the tiny
# /proc/diskstats counter (not every /proc/<pid>/io file) each tick.
#
# Usage: disk.sh [window-seconds] [mount]
#   window-seconds  sample window for rate computation (default 0.5)
#   mount           filesystem to monitor for space (default /)

WINDOW="${1:-0.5}"
MOUNT="${2:-/}"

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

# --- sample #1 ------------------------------------------------------------
ds1=$(snapshot_diskstats)
sleep "$WINDOW"
# --- sample #2 ------------------------------------------------------------
ds2=$(snapshot_diskstats)

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