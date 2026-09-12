#!/bin/bash
# obi.stats network sampler.
#
# One sampler drives the bar item (current down/up KB/s), the dropdown graph
# (the same rates over time), the aggregate totals (lifetime down/up), the
# connection detail block (iface / type / MAC / SSID / local+public IP /
# gateway / internet state / ping) and the top processes by network.
#
# Emits (tab-separated):
#   iface\t<name>                 active route interface ("" when offline)
#   type\twifi|ethernet|unknown
#   mac\t<mac-address>
#   ssid\t<ssid>                  wifi only, absent for ethernet
#   ip\t<local-ipv4>              prefsrc of the default route
#   gateway\t<gateway-ip>
#   connected\t1|0                link has a default route
#   online\t1|0                   internet reachable (cached probe)
#   pingMs\t<float>               internet ping latency (cached probe)
#   publicIp\t<ip>                public IP (cached probe)
#   down\t<KB/s>                  aggregate download rate (all traffic)
#   up\t<KB/s>                    aggregate upload rate
#   totalDown\t<bytes>            lifetime received (iface, since boot)
#   totalUp\t<bytes>              lifetime sent
#   proc\t<pid>\t<upKB/s>\t<downKB/s>\t<comm>   top by up+down, desc
#
# Data sources (no nethogs/iftop/bmon dep, rootless — the shell runs as the
# user):
#   - /proc/net/dev      aggregate rates + cumulative totals (whole iface)
#   - ip route get       active interface / gateway / local source IP
#   - /sys/class/net     MAC + wireless indicator
#   - iw dev link        SSID (wifi)
#   - ss -tinp           per-socket bytes_sent/bytes_received + owning PID
#                        (netlink diag is readable for the calling user's own
#                        sockets, no root), deltad over the window
#   - ping + curl        internet reachability / latency (ping, every tick) and
#                        public IP (curl, throttled to the probe cadence)
#
# PER-PROCESS LIMITATION (documented): ss exposes cumulative /proc<->remote
# byte counters only for TCP sockets; UDP/QUIC traffic (e.g. some streaming)
# is captured in the aggregate down/up but cannot be attributed to a process
# here without root, so the per-process table is a TCP-only view.
#
# Usage: net.sh [window-seconds] [probe-every-seconds]
#   window-seconds       rate sample window (default 0.5)
#   probe-every-seconds  min seconds between public-IP HTTP probes (default 10);
#                        ping/online run every tick regardless

WINDOW="${1:-0.5}"
PROBE_EVERY="${2:-10}"
NET_TOP_N="${NET_TOP_N:-12}"
PROBE_HOST="${NET_PROBE_HOST:-1.1.1.1}"

# --- active route -----------------------------------------------------------
# The reverse-path test works even while offline (it just resolves via the
# routing table), so it pinpoints the default iface/gateway/src without any
# actual traffic. Empty -> no default route (disconnected).
route=$(ip route get "$PROBE_HOST" 2>/dev/null)
iface=""; gw=""; src=""
if [ -n "$route" ]; then
  f=($route)
  for ((i=0;i<${#f[@]};i++)); do
    case "${f[$i]}" in
      dev) iface="${f[$((i+1))]}" ;;
      via) gw="${f[$((i+1))]}" ;;
      src) src="${f[$((i+1))]}" ;;
    esac
  done
fi

printf "iface\t%s\n" "$iface"

# --- interface facts ---------------------------------------------------------
if [ -n "$iface" ]; then
  ntype="ethernet"
  [ -d "/sys/class/net/$iface/wireless" ] && ntype="wifi"
  printf "type\t%s\n" "$ntype"
  if [ -r "/sys/class/net/$iface/address" ]; then
    printf "mac\t%s\n" "$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
  fi
  if [ "$ntype" = "wifi" ] && command -v iw >/dev/null 2>&1; then
    link=$(iw dev "$iface" link 2>/dev/null)
    if [ -n "$link" ]; then
      ssid=$(awk '/SSID:/ { sub(/.*SSID: /, ""); print; exit }' <<<"$link")
      [ -n "$ssid" ] && printf "ssid\t%s\n" "$ssid"
    fi
  fi
  printf "gateway\t%s\n" "$gw"
fi
[ -n "$src" ] && printf "ip\t%s\n" "$src"
[ -n "$iface" ] && printf "connected\t1\n" || printf "connected\t0\n"

#--- throttled internet probe (ping latency + online + public IP) ----------
# The shell calls net.sh once per networkRefreshSeconds. The ICMP ping
# (online state + latency) runs EVERY tick — cheap (~ms online, -W1) — so
# internet up/down and ping follow the refresh config. The public IP needs an
# external HTTP round-trip, so it stays throttled to PROBE_EVERY
# (networkProbeSeconds) and is cached between refreshes.
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/obi-stats-net-probe"
PROBE_FILE="$RUNTIME"
now=$(date +%s)

# Ping every tick. LC_ALL=C so the `time=` token parses under any locale.
ms=$(LC_ALL=C ping -n -c 1 -W 1 "$PROBE_HOST" 2>/dev/null \
       | awk -F'time[=<]' '/time[=<]/{ split($2,a," "); print a[1]; exit }')
if [ -n "$ms" ]; then
  probe_online=1
  probe_ping="$ms"
else
  probe_online=0
  probe_ping=""
fi

# Public IP: reuse the cached value; refresh when online and the cache is
# older than PROBE_EVERY seconds. Short -m so a dead endpoint can't stall the
# tick; on failure the last known value is kept.
probe_pub=""
latest=0
[ -r "$PROBE_FILE" ] && latest=$(stat -c %Y "$PROBE_FILE" 2>/dev/null || echo 0)
if [ -r "$PROBE_FILE" ]; then
  probe_pub=$(awk -F'\t' '$1=="publicIp"{print $2}' "$PROBE_FILE" 2>/dev/null)
fi
if [ "$probe_online" = "1" ] && [ "$latest" -le $((now - PROBE_EVERY)) ] && command -v curl >/dev/null 2>&1; then
  pub=$(curl -s -m 2 https://api.ipify.org 2>/dev/null)
  case "$pub" in
    [0-9.]*) ;;
    *) pub=$(curl -s -m 2 https://ifconfig.me 2>/dev/null) ;;
  esac
  # sanity: a plausible IPv4 address, else treat as unreachable
  case "$pub" in
    ''|*[!0-9.]*|*.*.*.*.*) pub="" ;;
  esac
  if [ -n "$pub" ]; then
    probe_pub="$pub"
    mkdir -p "$(dirname "$PROBE_FILE")" 2>/dev/null
    printf "publicIp\t%s\n" "$probe_pub" > "$PROBE_FILE"
  fi
fi

# When there's no active interface, the probe can't reasonably report an
# internet state or public IP (a stale cache from a previous link shouldn't
# linger), so force them empty before printing once.
if [ -z "$iface" ]; then probe_online=0; probe_ping=""; probe_pub=""; fi

printf "online\t%s\n" "$probe_online"
printf "pingMs\t%s\n" "$probe_ping"
printf "publicIp\t%s\n" "$probe_pub"

[ -z "$iface" ] && exit 0   # offline: nothing more to sample

# --- aggregate throughput + cumulative totals (whole iface) -----------------
# /proc/net/dev line format: iface: bytes packets errs drop fifo frame compressed
# multicast | tx-bytes(10) ...
read_dev() {
  awk -v i="$iface" '$1 == i":" { print $2, $10 }' /proc/net/dev 2>/dev/null
}
d1=$(read_dev)
s1=$(ss -Htinp 2>/dev/null)
sleep "$WINDOW"
d2=$(read_dev)
s2=$(ss -Htinp 2>/dev/null)

r1=${d1% *}; t1=${d1#* }
r2=${d2% *}; t2=${d2#* }
[ -n "$r1" ] || r1=0; [ -n "$t1" ] || t1=0
[ -n "$r2" ] || r2=0; [ -n "$t2" ] || t2=0

awk -v r1="$r1" -v r2="$r2" -v t1="$t1" -v t2="$t2" -v win="$WINDOW" '
BEGIN {
  dr = r2 - r1; if (dr < 0) dr = 0
  du = t2 - t1; if (du < 0) du = 0
  printf "down\t%.1f\nup\t%.1f\ntotalDown\t%s\ntotalUp\t%s\n",
         dr / 1024 / win, du / 1024 / win, r2, t2
}'

# --- per-process rates via ss -tinp (TCP sockets, deltad over window) ------
# ss -tinp emits, per socket: a summary line (with `pid=N` in users:(...)) then
# an indented info line carrying bytes_sent / bytes_received. Map each info
# line back to the pid of its summary, then delta across the two samples.
ss_snapshot() {
  awk '
    /^[[:space:]]/ {
      if ($0 ~ /bytes_sent/ && pid != "") {
        s = $0; sub(/.*bytes_sent:/, "", s); sub(/ .*/, "", s)
        r = $0; sub(/.*bytes_received:/, "", r); sub(/ .*/, "", r)
        print pid, s, r
      }
      next
    }
    {
      pid = ""
      if ($0 ~ /pid=[0-9]+/) { p = $0; sub(/.*pid=/, "", p); sub(/[),].*/, "", p); pid = p }
    }'
}
p1=$(printf '%s' "$s1" | ss_snapshot)
p2=$(printf '%s' "$s2" | ss_snapshot)

awk -v p1="$p1" -v p2="$p2" -v win="$WINDOW" -v nmax="$NET_TOP_N" '
BEGIN {
  n1 = split(p1, a1, "\n"); n2 = split(p2, a2, "\n")
  for (i = 1; i <= n1; i++) {
    if (a1[i] == "") continue
    n = split(a1[i], f, " ")
    if (n < 3) continue
    s1[f[1]] = f[2]; r1[f[1]] = f[3]
  }
  rows = 0
  for (i = 1; i <= n2; i++) {
    if (a2[i] == "") continue
    n = split(a2[i], f, " ")
    if (n < 3) continue
    pid = f[1]
    if (!(pid in s1)) continue          # socket appeared between samples
    ds = f[2] - s1[pid]; if (ds < 0) ds = 0
    dr = f[3] - r1[pid]; if (dr < 0) dr = 0
    u = ds / 1024 / win                 # bytes -> KiB / sec
    d = dr / 1024 / win
    if (u < 0.05 && d < 0.05) continue  # skip idle sockets
    rows++
    out[rows,1] = pid; out[rows,2] = u; out[rows,3] = d; out[rows,4] = i
  }
  # insertion sort by (up + down) descending
  for (i = 1; i <= rows; i++)
    for (j = i + 1; j <= rows; j++)
      if (out[j,2] + out[j,3] > out[i,2] + out[i,3]) {
        for (k = 1; k <= 4; k++) { t = out[i,k]; out[i,k] = out[j,k]; out[j,k] = t }
      }
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