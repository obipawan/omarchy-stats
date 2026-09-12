#!/bin/bash
# obi.stats combined sampler — one invocation emits all six always-on stats.
#
# Runs each stat's sampling in a PARALLEL background subshell and emits the
# results section-marked so the panel takes them apart with one pass:
#
#       ___cpu___\n...cpu lines...\n___gpu___\n...\n___net___\n...
#
# Section markers look like `___stat___` and never appear in sampler data.
# Running the windowed samplers concurrently (instead of sequentially) keeps
# the per-tick wall time near the longest single window rather than their sum,
# so a single shared refresh cadence holds cleanly.
#
# This script only ORCHESTRATES the existing, individually-tested samplers:
# cpu.sh / net.sh / ram.sh / disk.sh / battery.sh / gpu.sh. It duplicates no
# sampling logic. The on-demand per-process tables still come from procs.sh.
#
# Usage: sample.sh [window-seconds] [do-net-proc]
#   do-net-proc  1 to include the net per-socket/`ss` sampling (panel sets it
#                while the network dropdown is open); 0 otherwise (default).
W="${1:-0.6}"
DO_NET="${2:-0}"
SDIR="$(cd "$(dirname "$0")" && pwd)"

D=$(mktemp -d) || exit 1

# Each stat samples in parallel; their sleeps overlap so tick ≈ max(window).
( "$SDIR/cpu.sh"      "$W"           2>/dev/null ) > "$D/cpu" &
( "$SDIR/gpu.sh"                            ) > "$D/gpu" &
( "$SDIR/disk.sh"     "$W" /         2>/dev/null ) > "$D/disk" &
( "$SDIR/ram.sh"      "$W"           2>/dev/null ) > "$D/ram" &
( "$SDIR/battery.sh"  "$W"           2>/dev/null ) > "$D/battery" &
( NET_DO_PROC="$DO_NET" "$SDIR/net.sh" "$W" 10  2>/dev/null ) > "$D/net" &
wait

printf '___cpu___\n';    cat "$D/cpu"
printf '___gpu___\n';    cat "$D/gpu"
printf '___disk___\n';   cat "$D/disk"
printf '___ram___\n';    cat "$D/ram"
printf '___battery___\n';cat "$D/battery"
printf '___net___\n';    cat "$D/net"

rm -rf "$D"