#!/bin/bash
# obi.stats battery / power sampler.
#
# /sys + /proc reads (no acpi/btop dependency). Reads the ACPI power-supply tree
# in /sys/class/power_supply, discovers the battery (BAT*) and the AC adapter
# (AC*/ADP*), and computes charge level, voltage, current, power, health, cycles,
# temperature. When the upower daemon is reachable, it prefers upower's filtered
# Percentage (energy-based, matching what omarchy shows) and TimeToFull/TimeToEmpty
# (far more stable than a single instantaneous /sys power sample) — falling back to
# our own /sys estimates otherwise. Everything comes back tab-separated:
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
#
# NOTE: the "top processes" (drain proxy listing) is no longer produced here. It
# is the top-CPU list from the consolidated procs.sh sampler — Linux exposes no
# per-process power meter, so CPU is the honest drain proxy. Dropping the per-CPU
# scan means this always-on poll only reads the small /sys + upower values every
# tick instead of rescanning the whole process tree.
#
# Usage: battery.sh [window-seconds] [top-n]
#   (window/top-n retained for backward-compatible calls; per-process rows now
#    come from procs.sh and these args are ignored)

WINDOW="${1:-0.5}"   # kept for CLI compatibility (unused)
TOP_N="${2:-8}"      # kept for CLI compatibility (unused)
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

# --- override time/percentage estimates with upower ----------------
# Our simple /sys maths uses instantaneous samples. upower filters/smooths its
# values over a history window, so:
#   - timeToFull/timeToEmpty (seconds) are far more stable than voltage*current;
#   - Percentage is its own energy-based %, matching what omarchy shows.
# Prefer upower's values when the daemon is reachable; fall back to our own /sys
# estimates otherwise. Last-write-wins in the panel parser, so re-emitting these
# lines after the awk block overrides the raw values.
# NOTE: upower's device path is a DBus object path (/org/freedesktop/UPower/
# devices/battery_<NAME>), NOT a filesystem glob under /org/... — derive it from
# the /sys battery name we already discovered.
if command -v busctl >/dev/null 2>&1 && [ -n "$BAT" ]; then
  bat_name=$(basename "$BAT")
  upower_dev="/org/freedesktop/UPower/devices/battery_${bat_name}"
  up_ttf=$(busctl --no-pager get-property org.freedesktop.UPower "$upower_dev" org.freedesktop.UPower.Device TimeToFull   2>/dev/null | awk '{print $2}')
  up_tte=$(busctl --no-pager get-property org.freedesktop.UPower "$upower_dev" org.freedesktop.UPower.Device TimeToEmpty  2>/dev/null | awk '{print $2}')
  up_pct=$(busctl --no-pager get-property org.freedesktop.UPower "$upower_dev" org.freedesktop.UPower.Device Percentage    2>/dev/null | awk '{print $2}')
  # Values are 0 when not in that state; only print when upower reports a real one.
  if [ "${up_ttf:-0}" -gt 0 ] 2>/dev/null; then printf "timeToFull\t%.0f\n" "$up_ttf"; fi
  if [ "${up_tte:-0}" -gt 0 ] 2>/dev/null; then printf "timeToEmpty\t%.0f\n" "$up_tte"; fi
  # Percentage is a 0..100 fraction; only override when it parsed as a sane value.
  if [ -n "${up_pct:-}" ] && awk -v p="$up_pct" 'BEGIN{ exit !(p>=0 && p<=100) }'; then
    printf "pct\t%.0f\n" "$up_pct"
  fi
fi