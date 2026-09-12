#!/bin/bash
# obi.stats battery / power sampler.
#
# Pure /sys + /proc reads (no upower/acpi/btop dependency). Reads the ACPI
# power-supply tree in /sys/class/power_supply, discovers the battery (BAT*) and
# the AC adapter (AC*/ADP*), and computes charge level, voltage, current, power,
# health, cycles, temperature and time-to-full/empty. It also samples per-process
# CPU usage (the dominant battery drain) so the panel can list the top consumers.
# Everything the panel needs comes back tab-separated:
#
#   present\t<0|1>               a battery exists
#   state\t<charging|discharging|full|not-charging|unknown>
#   ac\t<0|1>                    AC adapter is plugged in
#   pct\t<percent>               charge level (0..100)
#   voltage\t<volts>             current terminal voltage
#   current\t<milliamps>         signed: +charging / -discharging (0 when full)
#   power\t<watts>               signed: +charging / -discharging
#   energy\t<Wh>                 energy remaining
#   energyFull\t<Wh>             energy at full charge
#   energyFullDesign\t<Wh>       design (factory) full energy
#   health\t<percent>            energyFull / energyFullDesign * 100
#   cycles\t<count>              charge cycles
#   temp\t<celcius>              battery temperature, when exposed
#   timeToFull\t<seconds>        seconds until full (0 when not charging)
#   timeToEmpty\t<seconds>       seconds until empty (0 when not discharging)
#   model\t<string>              battery model name (optional)
#   proc\t<pid>\t<pct>\t<comm>   top CPU processes (drain proxy), desc
#
# Data sources:
#   - /sys/class/power_supply/BAT*/* for the battery itself
#   - /sys/class/power_supply/{AC*,ADP*}/online for AC presence
#   - /sys/class/power_supply/<bat>/power if present, else voltage*current
#   - /proc/stat + /proc/<pid>/stat (windowed) for top CPU consumers
#
# Usage: battery.sh [window-seconds] [top-n]
#   window-seconds  sample window for the process-rate computation (default 0.5)
#   top-n           rows of per-process CPU to print (default 8)

WINDOW="${1:-0.5}"
TOP_N="${2:-8}"
[ "$TOP_N" -lt 1 ] 2>/dev/null && TOP_N=8

# --- discover battery + AC --------------------------------------------------
BAT=""
for d in /sys/class/power_supply/BAT*; do
  [ -d "$d" ] || continue
  [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
  BAT="$d"; break
done

AC=""
for d in /sys/class/power_supply/{AC,ADP,CAMP}*; do
  [ -f "$d/online" ] || continue
  AC="$d"; break
done

[ -n "$BAT" ] || { printf "present\t0\nstate\tunknown\nac\t0\npct\t-1\n"; exit 0; }

# --- raw ACPI values --------------------------------------------------------
rd() { cat "$BAT/$1" 2>/dev/null; }          # raw int (may be empty)
rdf() { awk 'BEGIN{getline < ARGV[1] > 0; print}' "$BAT/$1"; }  # raw float (handles "charge" style)

charge_now=$(rd charge_now);    charge_full=$(rd charge_full)
charge_design=$(rd charge_full_design)
energy_now=$(rd energy_now);    energy_full=$(rd energy_full)
energy_design=$(rd energy_full_design)
voltage=$(rd voltage_now);      current_raw=$(rd current_now)
power_raw=$(rd power)
temp_raw=$(rd temp); [ -n "$temp_raw" ] || temp_raw=$(rd temperature)
[ -n "$temp_raw" ] || temp_raw=$(rd temperature_now)
cycles=$(rd cycle_count)
model=$(rd model_name 2>/dev/null)

ac=0
[ -n "$AC" ] && [ "$(cat "$AC/online" 2>/dev/null)" = "1" ] && ac=1

status=$(rd status)   # Charging | Discharging | Full | Not charging | Unknown

# --- compute everything in one awk pass ------------------------------------
awk -v cn="${charge_now:-0}" -v cf="${charge_full:-0}" -v cd="${charge_design:-0}" \
    -v en="${energy_now:-0}" -v ef="${energy_full:-0}" -v ed="${energy_design:-0}" \
    -v v="${voltage:-0}" -v cur="${current_raw:-0}" -v pw="${power_raw:-0}" \
    -v tr="${temp_raw:-0}" -v cy="${cycles:-0}" -v st="$status" -v acd="$ac" \
    -v model="$model" '
function fmt(v){ if (v=="") return "-1"; return v }
BEGIN {
  # Prefer energy fields (Wh, µWh from the kernel); fall back to charge (µAh)
  # * voltage (µV). µAh * µV = (1e-6 Ah)*(1e-6 V) => 1e-12 Wh.
  has_energy = (ef > 0 && en > 0)
  if (has_energy) { e_rem = en / 1e6; e_full = ef / 1e6; e_des = ed > 0 ? ed / 1e6 : ef / 1e6 }
  else if (cf > 0 && cn > 0) {
    e_rem = cn * v / 1e12; e_full = cf * v / 1e12
    e_des = cd > 0 ? cd * v / 1e12 : e_full
    has_energy = 1
  } else {
    e_rem = 0; e_full = e_des = 1; has_energy = 0
  }

  pct = -1
  if (has_energy && e_full > 0) pct = 100 * e_rem / e_full
  else if (cn > 0 && cf > 0)    pct = 100 * cn / cf
  if (pct > 100) pct = 100; if (pct < 0) pct = 0

  # Power: explicit `power` if the kernel exposes it (voltage*current), else
  # derive from voltage (V) * current (µA) -> W.
  if (pw > 0) power = pw / 1e6
  else power = (v / 1e6) * (cur / 1e6)

  # Voltage in volts, current in milliamps (signed for display convenience).
  volt = v / 1e6; curmA = cur / 1000

  health = (e_des > 0 && e_full > 0) ? 100 * e_full / e_des : -1
  temp = tr > 0 ? (tr >= 1000 ? tr / 100 : tr / 10) : -1   # some report 0.1°C, some °C

  state = "unknown"
  s = toupper(st)
  if (s ~ /^CHARG/) state = "charging"
  else if (s ~ /^DISCH/) state = "discharging"
  else if (s ~ /^FULL/) state = "full"
  else if (s ~ /NOT/) state = "not-charging"

  # Time to full/empty from remaining V·Ah and power W.
  absP = power < 0 ? -power : power
  ttf = 0; tte = 0
  if (state == "charging" && absP > 0) {
    ttf = (e_full - e_rem) / absP * 3600        # seconds
    if (ttf < 0) ttf = 0
  } else if (state == "discharging" && absP > 0) {
    tte = e_rem / absP * 3600
  }

  printf "present\t1\n"
  printf "state\t%s\n", state
  printf "ac\t%d\n", acd
  printf "pct\t%.0f\n", pct
  printf "voltage\t%.2f\n", volt
  printf "current\t%.0f\n", curmA
  printf "power\t%.2f\n", power
  printf "energy\t%.2f\n", e_rem
  printf "energyFull\t%.2f\n", e_full
  printf "energyFullDesign\t%.2f\n", e_des
  printf "health\t%.1f\n", health
  printf "cycles\t%.0f\n", cy
  printf "temp\t%.1f\n", temp
  printf "timeToFull\t%.0f\n", ttf
  printf "timeToEmpty\t%.0f\n", tte
  printf "model\t%s\n", model
}
'

# --- top CPU consumers (drain proxy) ----------------------------------------
# CPU activity is the dominant battery drain on this class of device and is the
# only honest per-process figure Linux exposes (there is no per-process power
# meter in /proc). Reuse the same two-pass /proc/<pid>/stat sampling as cpu.sh.
snapshot_procs() {
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{
    split($0, a, ") ")
    n = split(a[2], b, " ")
    print $1, b[12], b[13]
  }'
}

p1=$(snapshot_procs)
sleep "$WINDOW"
p2=$(snapshot_procs)

awk -v p1="$p1" -v p2="$p2" -v clk=100 -v win="$WINDOW" -v nmax="$TOP_N" '
BEGIN {
  split(p1, a1, "\n"); split(p2, a2, "\n")
  for (i = 1; i <= length(a1); i++) {
    if (a1[i] == "") continue
    n = split(a1[i], f, " ")
    if (n < 3) continue
    t1[f[1]] = f[2] + f[3]
  }
  rows = 0
  for (i = 1; i <= length(a2); i++) {
    if (a2[i] == "") continue
    n = split(a2[i], f, " ")
    if (n < 3) continue
    pid = f[1]; if (!(pid in t1)) continue
    d = (f[2] + f[3]) - t1[pid]; if (d < 0) d = 0
    rows++; out[rows,1] = pid; out[rows,2] = (100.0 * d) / (clk * win)
  }
  for (i = 1; i <= rows; i++)
    for (j = i + 1; j <= rows; j++)
      if (out[j,2] > out[i,2])
        for (k = 1; k <= 2; k++) { t = out[i,k]; out[i,k] = out[j,k]; out[j,k] = t }
  for (i = 1; i <= rows; i++) {
    if (i > nmax) break
    call = "cat /proc/" out[i,1] "/comm 2>/dev/null"
    comm = "?"; if ((call | getline comm) > 0) { } close(call)
    printf "proc\t%s\t%.1f\t%s\n", out[i,1], out[i,2], comm
  }
}'