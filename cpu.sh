#!/bin/bash
# obi.stats CPU sampler.
#
# Reads /proc/stat twice, a configurable window apart, and prints tab-separated
# lines the panel parses:
#
#   total\t<percent>                  aggregate CPU (0..100*ncores, single-core %)
#   core\t<index>\t<percent>          per-core usage (0..100)
#
# Everything is pure /proc + awk: no mpstat/sar/htop dependency.
#
# NOTE: the per-process "top CPU" rows no longer come from this script. They are
# produced by the consolidated procs.sh sampler, which reads every process once
# (stat + io + status) and serves the CPU, RAM, disk and battery dropdown tables
# from a single /proc pass. Keeping this file down to /proc/stat only means the
# always-on bar poll does not rescan the whole process tree every tick.
#
# Usage: cpu.sh [window-seconds]      (default 1.0)

WINDOW="${1:-1.0}"

# --- sample #1 -------------------------------------------------------------
stat1=$(cat /proc/stat)
sleep "$WINDOW"
# --- sample #2 -------------------------------------------------------------
stat2=$(cat /proc/stat)

# --- aggregate + per-core  -------------------------------------------------
awk -v s1="$stat1" -v s2="$stat2" '
function parse(line, arr,   f, i, n, total, idle, name) {
  n = split(line, f, " ")
  name = f[1]
  total = 0; idle = 0
  for (i = 2; i <= n; i++) total += f[i]
  if (n >= 6) idle = f[5] + f[6]
  else if (n >= 5) idle = f[5]
  arr[name "_b"] = total - idle
  arr[name "_i"] = idle
}
function pct(b1, i1, b2, i2) {
  dB = b2 - b1; dI = i2 - i1; dT = dB + dI
  return dT <= 0 ? 0 : 100.0 * (1 - dI / dT)
}
BEGIN {
  split(s1, a1, "\n"); split(s2, a2, "\n")
  for (i = 1; i <= length(a1); i++) if (a1[i] ~ /^cpu/) parse(a1[i], l1)
  for (i = 1; i <= length(a2); i++) if (a2[i] ~ /^cpu/) parse(a2[i], l2)
  printf "total\t%.1f\n", pct(l1["cpu_b"], l1["cpu_i"], l2["cpu_b"], l2["cpu_i"])
  for (k in l1) {
    if (k !~ /_b$/) continue
    name = k; sub(/_b$/, "", name)
    if (name == "cpu") continue
    if ((name "_b") in l2)
      printf "core\t%s\t%.1f\n", name, pct(l1[k], l1[name "_i"], l2[name "_b"], l2[name "_i"])
  }
}
'