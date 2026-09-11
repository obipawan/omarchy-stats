#!/bin/bash
# obi.stats CPU sampler.
#
# Reads /proc/stat and /proc/<pid>/stat twice, a configurable window apart, and
# prints tab-separated lines the panel parses:
#
#   total\t<percent>                  aggregate CPU (0..100*ncores, single-core %)
#   core\t<index>\t<percent>          per-core usage (0..100)
#   proc\t<pid>\t<percent>\t<comm>    per-process usage (0..100*ncores), desc by %
#
# Everything is pure /proc + awk: no mpstat/sar/htop dependency.
#
# Performance: the process snapshot reads every /proc/<pid>/stat in a SINGLE
# `cat | awk` pass (not one awk per pid), and per-process names are resolved
# only for the few top rows. This keeps one run well under the refresh period
# so the panel's sample cadence stays at the configured refreshSeconds.
#
# Usage: cpu.sh [window-seconds]      (default 1.0)

WINDOW="${1:-1.0}"

# Snapshot /proc/<pid>/stat into "pid utime stime" lines. A single awk pass
# over the concatenated stat files; fields 14/15 come after splitting on the
# ") " that ends the parenthesised comm (whose space would shift every field).
snapshot_procs() {
  # shellcheck disable=SC2038  # stat filenames are benign (numeric pids)
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{
    split($0, a, ") ")
    n = split(a[2], b, " ")
    print $1, b[12], b[13]
  }'
}

# --- sample #1 -------------------------------------------------------------
stat1=$(cat /proc/stat)
procs1=$(snapshot_procs)
sleep "$WINDOW"
# --- sample #2 -------------------------------------------------------------
stat2=$(cat /proc/stat)
procs2=$(snapshot_procs)

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

# --- per-process (sorted by % descending) ---------------------------------
awk -v p1="$procs1" -v p2="$procs2" -v clk=100 -v win="$WINDOW" -v nmax="${TOP_PROC_NAME_LIMIT:-32}" '
BEGIN {
  split(p1, a1, "\n"); split(p2, a2, "\n")
  for (i = 1; i <= length(a1); i++) {
    if (a1[i] == "") continue
    n = split(a1[i], f, " ")
    if (n < 3) continue
    t1[f[1]] = f[2] + f[3]          # utime + stime, ticks
  }
  rows = 0
  for (i = 1; i <= length(a2); i++) {
    if (a2[i] == "") continue
    n = split(a2[i], f, " ")
    if (n < 3) continue
    pid = f[1]
    if (!(pid in t1)) continue
    dticks = (f[2] + f[3]) - t1[pid]
    if (dticks < 0) dticks = 0
    p = (100.0 * dticks) / (clk * win)   # % of one core over the window
    rows++
    out[rows,1] = pid; out[rows,2] = p; out[rows,3] = i
  }
  for (i = 1; i <= rows; i++)
    for (j = i + 1; j <= rows; j++)
      if (out[j,2] > out[i,2]) {
        for (k = 1; k <= 3; k++) { t = out[i,k]; out[i,k] = out[j,k]; out[j,k] = t }
      }
  # Resolve names only for the rows the panel is likely to keep (top nmax),
  # not all ~250 processes — a `cat /proc/<pid>/comm` per process is the
  # expensive part of the old version.
  for (i = 1; i <= rows; i++) {
    if (i > nmax) break
    call = "cat /proc/" out[i,1] "/comm 2>/dev/null"
    comm = "?"
    if ((call | getline comm) > 0) { }
    close(call)
    printf "proc\t%s\t%.1f\t%s\n", out[i,1], out[i,2], comm
  }
}
'