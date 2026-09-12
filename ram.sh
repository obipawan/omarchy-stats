#!/bin/bash
# obi.stats RAM + swap sampler.
#
# Pure /proc reads (no free/vmstat/free_total dependency). One pass over
# /proc/meminfo for the aggregate numbers, printed tab-separated for the panel:
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
#
# `used` is the classic "used" that keeps the USER line coherent with the
# bar/gauge/history pressure figure; `system` is the reclaimable cache. Both
# work out to `used + system + free == total`.
#
# NOTE: the "top memory processes" table is no longer produced here. It comes
# from the consolidated procs.sh sampler, so this always-on bar poll only reads
# the two small aggregate files instead of every /proc/<pid>/status every tick.
#
# Usage: ram.sh [top-n]      (kept for CLI compatibility; per-process rows now
#                             come from procs.sh and this arg is ignored)

TOP_N="${1:-12}"                      # retained for backward-compatible calls

# --- aggregate (single /proc/meminfo pass) --------------------------------
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