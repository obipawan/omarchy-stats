#!/bin/bash
# obi.stats RAM + swap sampler.
#
# Pure /proc reads (no free/vmstat/free_total dependency). One pass over
# /proc/meminfo for the aggregate numbers and one pass over /proc/<pid>/status
# for every process's resident set, printed tab-separated for the panel:
#
#   total\t<KiB>          physical RAM installed (MemTotal)
#   free\t<KiB>           truly free pages (MemFree)
#   available\t<KiB>      memory available to new apps (MemAvailable)
#   used\t<KiB>           apps + kernel private = total - free - buffers - cached
#   system\t<KiB>         page cache + buffers (reclaimable system memory)
#   buffers\t<KiB>        MemBuffers
#   cached\t<KiB>         MemCached
#   shared\t<KiB>         shared / tmpfs memory (MemShmem)
#   swapTotal\t<KiB>      total swap
#   swapUsed\t<KiB>       swapTotal - swapFree
#   swapCached\t<KiB>     swap pages read but still in memory (SwapCached)
#   psiSome10\t<percent>  PSI memory pressure, 'some' over the last 10s
#   psiFull10\t<percent>  PSI memory pressure, 'full' over the last 10s
#   proc\t<pid>\t<rssKiB>\t<name>   top processes by resident set, desc
#
# `used` is the classic "used" that keeps the USER line coherent with the
# bar/gauge/history pressure figure; `system` is the reclaimable cache. Both
# work out to `used + system + free == total`. A process's Rss and Name are
# read from the same /proc/<pid>/status file in a single awk pass.
#
# Usage: ram.sh [top-n]      (top-N rows of per-process RSS; default 12)

TOP_N="${1:-12}"
if [ "$TOP_N" -lt 1 ] 2>/dev/null; then TOP_N=12; fi

# --- aggregate (single /proc/meminfo pass) --------------------------------
# Field names have a trailing ':', $2 is the KiB value.
awk '
/^MemTotal:/      { t = $2 }
/^MemFree:/       { f = $2 }
/^MemAvailable:/  { a = $2 }
/^Buffers:/       { b = $2 }
/^Cached:/        { c = $2 }
/^Shmem:/         { sh = $2 }
/^SwapTotal:/     { st = $2 }
/^SwapFree:/      { sf = $2 }
/^SwapCached:/    { sc = $2 }
END {
  cached = c + b                 # page cache + buffer pool
  used = t - f - cached          # apps + kernel-private (excludes cache)
  if (used < 0) used = 0
  printf "total\t%d\n", t
  printf "free\t%d\n", f
  printf "available\t%d\n", a
  printf "used\t%d\n", used
  printf "system\t%d\n", cached
  printf "buffers\t%d\n", b
  printf "cached\t%d\n", c
  printf "shared\t%d\n", sh
  printf "swapTotal\t%d\n", st
  printf "swapUsed\t%d\n", st - sf
  printf "swapCached\t%d\n", sc
}
' /proc/meminfo

# --- PSI memory pressure ---------------------------------------------------
# Pressure Stall Information: the share of the recent window processes spent
# stalled on memory. World-readable on stock kernels; a missing/unreadable file
# (e.g. a kernel without CONFIG_PSI) is not fatal — nothing is emitted.
if [ -r /proc/pressure/memory ]; then
  awk '
    /^some/ { split($3, a, "="); printf "psiSome10\t%s\n", a[2] }
    /^full/ { split($3, b, "="); printf "psiFull10\t%s\n", b[2] }
  ' /proc/pressure/memory
fi

# --- per-process RSS -------------------------------------------------------
# Read every /proc/<pid>/status in a single awk pass, grabbing the VmRSS (the
# resident set, KiB) and Name fields. We enumerate files via a shell glob and
# read each with `getline < file` so a process that exits mid-scan can't abort
# the whole pass (plain `awk file1 file2 ...` would die on a vanish). The pid
# comes from the path; dying processes just drop out. VmRSS values are
# space-padded (e.g. "   7004 kB"), which awk's default field split absorbs.
awk -v nmax="$TOP_N" '
BEGIN {
  cmd = "printf '\''%s\\n'\'' /proc/[0-9]*/status"
  while ((cmd | getline file) > 0) {
    pid = file; sub(/\/status$/, "", pid); sub(/^.*\//, "", pid)
    rss = 0; name = ""
    while ((getline line < file) > 0) {
      if (line ~ /^VmRSS:/)     { n = split(line, a, " "); if (a[2] ~ /^[0-9]+$/) rss = a[2] }
      else if (line ~ /^Name:/) { n = split(line, a, " "); name = a[2] }
    }
    close(file)
    if (rss > 0) { rows++; out[rows,1] = pid; out[rows,2] = rss; out[rows,3] = name }
  }
  close(cmd)
  # insertion sort by Rss descending
  for (i = 1; i <= rows; i++)
    for (j = i + 1; j <= rows; j++)
      if (out[j,2] > out[i,2]) {
        for (k = 1; k <= 3; k++) { t = out[i,k]; out[i,k] = out[j,k]; out[j,k] = t }
      }
  n = rows < nmax ? rows : nmax
  for (i = 1; i <= n; i++)
    printf "proc\t%s\t%s\t%s\n", out[i,1], out[i,2], out[i,3]
}
'