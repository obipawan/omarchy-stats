#!/bin/bash
# obi.stats GPU sampler — vendor-agnostic.
#
# Detects the GPU and hands off to the matching backend. Unlike cpu.sh there
# is no /proc equivalent for GPU utilization, so each backend shells out to a
# helper utility when one is installed. It emits the same tab-separated line
# schema whatever the vendor, so the panel's parser never needs to know the
# GPU brand:
#
#   vendor\t<name>                 intel | nvidia | amd | unknown
#   model\t<string>                human-readable device name (from lspci)
#   status\t<tag>                  ok | no-tool | no-gpu | error
#   total\t<0..100|-]              aggregate utilization of primary engine
#   temp\t<celcius|->
#   memUsed\t<MiB|->
#   memTotal\t<MiB|->
#   engine\t<name>\t<percent>      per-engine utilization (repeats)
#   proc\t<pid>\t<memMiB>\t<comm>  top GPU processes by memory (best-effort)
#
# The trailing fields (temp/mem/engine/proc) depend on what the backend
# exposes; `-` means "not available" and the panel skips that block.
#
#   vendor line is emitted FIRST so the panel can show setup guidance.
#   model    line is the lspci description (always present).
#   status   ok       -> a backend produced at least a total
#            no-tool  -> GPU detected but its helper utility is not installed
#            no-gpu   -> no GPU found at all
#            error    -> backend ran but returned nothing usable
#
# Usage:
#   gpu.sh                    one-shot sample (best-effort, no windowing)
#   gpu.sh --doctor           print step-by-step setup instructions for the
#                             detected GPU and exit
#   gpu.sh --vendor           print just the vendor tag and exit
#
# The backend utilities only run when installed; absence is reported through
# `status` so the shell never errors.

# Where the tool binary should sit per vendor (best-known names; override with
# INTEL_GPU_TOOL / NVIDIA_SMI / ROCM_SMI env vars if a distro renames them).
INTEL_GPU_TOOL="${INTEL_GPU_TOOL:-intel_gpu_top}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
ROCM_SMI="${ROCM_SMI:-rocm-smi}"
RADEONTOP="${RADEONTOP:-radeontop}"

# ---- vendor detection ----------------------------------------------------
# Prefer the DRM /sys device vendor IDs (fast, no lspci), fall back to lspci
# string matching which is more forgiving of badly-labelled devices.
vendor_from_sys() {
  local v
  for dir in /sys/class/drm/card[0-9]*/device; do
    [ -e "$dir/vendor" ] || continue
    v=$(cat "$dir/vendor" 2>/dev/null)
    case "$v" in
      0x10de) echo nvidia; return ;;
      0x1002|0x1022) echo amd; return ;;
      0x8086) echo intel; return ;;
    esac
  done
  echo unknown
}

vendor_from_lspci() {
  local line v
  line=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' | head -1)
  v=$(echo "$line" | grep -ioE 'nvidia|amd|ati|radeon|advanced micro|intel' | head -1 | tr '[:upper:]' '[:lower:]')
  case "$v" in
    nvidia) echo nvidia ;;
    amd|ati|radeon) echo amd ;;
    intel) echo intel ;;
    *) echo unknown ;;
  esac
}

detect_vendor() {
  local sys lsp
  sys=$(vendor_from_sys)
  lsp=$(vendor_from_lspci)
  if [ "$sys" = "unknown" ]; then
    echo "$lsp"
  else
    echo "$sys"
  fi
}

# Full model string from lspci (e.g. "Intel Corporation Broadwell-U GT3 [Iris
# Graphics 6100] (rev 09)"), or "Unknown" when lspci is absent. Strips the slot
# prefix, trailing [hex] vendor id and (rev) suffix.
model_from_lspci() {
  local line
  line=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' | head -1)
  [ -z "$line" ] && { echo Unknown; return; }
  # drop leading slot/type, e.g. "00:02.0 VGA compatible controller: "
  line=$(echo "$line" | sed -E 's/^[0-9a-fA-F:.]*[[:space:]]+[^:]*:?[[:space:]]*//')
  # drop trailing " [1234:abcd]" vendor-id and " (rev NN)"
  line=$(echo "$line" | sed -E 's/[[:space:]]+\[[0-9a-fA-F:]{6,}\]//; s/[[:space:]]+\(rev.*$//')
  echo "${line:-Unknown}" | sed 's/[[:space:]]*$//'
}

# ---- backends ------------------------------------------------------------
# Each backend prints lines (no vendor/status — those are emitted by the
# driver). Returns 0 if it produced a `total`, non-zero otherwise.

backend_nvidia() {
  command -v "$NVIDIA_SMI" >/dev/null 2>&1 || return 1
  local out
  out=$("$NVIDIA_SMI" --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  [ -z "$out" ] && return 1
  # utilization, temp, memUsed, memTotal (comma-separated CSV)
  local u t mu mt
  u=$(echo "$out" | cut -d, -f1 | tr -d ' ')
  t=$(echo "$out" | cut -d, -f2 | tr -d ' ')
  mu=$(echo "$out" | cut -d, -f3 | tr -d ' ')
  mt=$(echo "$out" | cut -d, -f4 | tr -d ' ')
  echo "total	${u:-0}"
  [ -n "${t//[^0-9]/}" ] && echo "temp	$t"
  [ -n "${mu//[^0-9]/}" ] && [ -n "${mt//[^0-9]/}" ] && { echo "memUsed	$mu"; echo "memTotal	$mt"; }
  echo "engine	GPU	${u:-0}"
  # top GPU processes by memory, best-effort
  "$NVIDIA_SMI" --query-compute-apps=pid,used_gpu_memory,process_name --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r pid mem name; do
    pid=$(echo "$pid" | tr -d ' '); mem=$(echo "$mem" | tr -d ' ')
    echo "proc	$pid	$mem	${name:-gpu}"
  done
  return 0
}

# intel_gpu_top -J emits a JSON object per refresh continuously; we capture
# the FIRST object with a bounded timeout so a poll never hangs the shell.
backend_intel() {
  command -v "$INTEL_GPU_TOOL" >/dev/null 2>&1 || return 1
  local json busy
  json=$(timeout 1 "$INTEL_GPU_TOOL" -J 2>/dev/null || true)
  [ -z "$json" ] && return 1
  # Aggregate utilization: the "busy"/"Gfx" percentage under the global stats.
  # Recognised keys across igt-gpu-tools 2.x: "busy", "Gfx", "GLOBAL".
  busy=$(printf '%s' "$json" | awk 'match($0, /"busy"[[:space:]]*:[[:space:]]*[0-9.]+/) { s=substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", s); print s; exit }')
  [ -n "$busy" ] || return 1
  echo "total	$busy"
  echo "engine	GFX	$busy"
  # Memory + temperature keys, when present. Grep the whole captured blob; each
  # "key": value pair sits on one line so -oE extracts them line by line.
  printf '%s\n' "$json" | grep -oE '"(used|usedVMem|total|temperature)"[[:space:]]*:[[:space:]]*[0-9.]+' |
    awk -F'[":]' '{ v=$NF; gsub(/[[:space:]]/, "", v); if ($2=="used") print "memUsed	" v; else if ($2=="usedVMem") print "memUsed	" v; else if ($2=="total") print "memTotal	" v; else if ($2=="temperature") print "temp	" v }'
  return 0
}

backend_amd() {
  # rocm-smi is the primary; radeontop (per-block busy %) is the fallback.
  if command -v "$ROCM_SMI" >/dev/null 2>&1; then
    local u
    u=$("$ROCM_SMI" --showuse 2>/dev/null | grep -iEo '[0-9.]+%' | head -1 | tr -d '%')
    [ -n "$u" ] || return 1
    echo "total	${u:-0}"
    echo "engine	GPU	${u:-0}"
    local t mu mt
    t=$("$ROCM_SMI" --showtemp 2>/dev/null | grep -iEo '[0-9.]+' | head -1)
    [ -n "$t" ] && echo "temp	$t"
    mu=$("$ROCM_SMI" --showmeminfo vram 2>/dev/null | grep -iEo '[0-9.]+' | head -1)
    mt=$("$ROCM_SMI" --showmeminfo vram 2>/dev/null | grep -iEo '[0-9.]+' | tail -1)
    [ -n "$mu" ] && echo "memUsed	$mu"
    [ -n "$mt" ] && echo "memTotal	$mt"
    return 0
  fi
  if command -v "$RADEONTOP" >/dev/null 2>&1; then
    # radeontop -l 1 -d - counts a frame; parse the comma-separated block %.
    local line
    line=$("$RADEONTOP" -l 1 -d - 2>/dev/null | tail -1)
    [ -z "$line" ] && return 1
    local total
    total=$(echo "$line" | grep -oE '[0-9.]+%' | head -1 | tr -d '%')
    [ -n "$total" ] || return 1
    echo "total	${total}"
    echo "engine	GPU	${total}"
    return 0
  fi
  return 1
}

# ---- doctor (setup guidance) --------------------------------------------
print_doctor() {
  local vendor="${1:-unknown}"
  echo "GPU: $(model_from_lspci || echo Unknown)"
  echo "vendor: $vendor"
  echo
  case "$vendor" in
    intel)
      echo "Detected an Intel GPU. The plugin uses '${INTEL_GPU_TOOL} -J' to read"
      echo "per-engine utilization and memory."
      echo
      if command -v "$INTEL_GPU_TOOL" >/dev/null 2>&1; then
        echo "  Tool present: $(command -v "$INTEL_GPU_TOOL")  ✓ ready"
      else
        echo "  Missing tool: ${INTEL_GPU_TOOL}"
        echo "  Install (Arch):  sudo pacman -S intel-gpu-tools"
        echo "  Verify:          ${INTEL_GPU_TOOL} -J   (Ctrl-C to stop)"
      fi
      ;;
    nvidia)
      echo "Detected an NVIDIA GPU. The plugin reads ${NVIDIA_SMI}."
      echo
      if command -v "$NVIDIA_SMI" >/dev/null 2>&1; then
        echo "  Tool present: $(command -v "$NVIDIA_SMI")"
        if "$NVIDIA_SMI" >/dev/null 2>&1; then
          echo "  Driver: running ✓ ready"
        else
          echo "  Driver: NOT running — nvidia-smi cannot talk to the kernel driver."
          echo "  Install/load the NVIDIA driver (e.g. sudo pacman -S nvidia-driver)"
          echo "  then reboot. Verify: ${NVIDIA_SMI} --query-gpu=name"
        fi
      else
        echo "  Missing tool: ${NVIDIA_SMI}"
        echo "  Install (Arch):  sudo pacman -S nvidia-utils"
        echo "  Verify:          ${NVIDIA_SMI} --query-gpu=name"
      fi
      ;;
    amd)
      echo "Detected an AMD GPU."
      if command -v "$ROCM_SMI" >/dev/null 2>&1; then
        echo "  Tool present: $(command -v "$ROCM_SMI")  ✓ ready"
      elif command -v "$RADEONTOP" >/dev/null 2>&1; then
        echo "  Tool present (radeontop fallback): $(command -v "$RADEONTOP")  ✓ ready"
      else
        echo "  Missing tool: ${ROCM_SMI} (or radeontop fallback)"
        echo "  Install (Arch):  sudo pacman -S rocm-smi-lib   (or: sudo pacman -S radeontop)"
        echo "  Verify:          ${ROCM_SMI} --showuse"
      fi
      ;;
    *)
      echo "Could not identify the GPU vendor. The plugin supports Intel, NVIDIA"
      echo "and AMD. Install the matching tool from the list above and re-run"
      echo "this doctor to confirm."
      ;;
  esac
}

# ---- driver -------------------------------------------------------------
vendor=$(detect_vendor)

if [ "$1" = "--doctor" ]; then
  print_doctor "$vendor"
  exit 0
fi
if [ "$1" = "--vendor" ]; then
  echo "$vendor"
  exit 0
fi

echo "vendor	$vendor"
echo "model	$(model_from_lspci || echo Unknown)"

case "$vendor" in
  nvidia)
    if backend_nvidia; then echo "status	ok"; else echo "status	$(command -v "$NVIDIA_SMI" >/dev/null 2>&1 && echo error || echo no-tool)"; fi
    ;;
  intel)
    if backend_intel; then echo "status	ok"; else echo "status	$(command -v "$INTEL_GPU_TOOL" >/dev/null 2>&1 && echo error || echo no-tool)"; fi
    ;;
  amd)
    if backend_amd; then echo "status	ok"; else echo "status	no-tool"; fi
    ;;
  *)
    echo "status	no-gpu"
    ;;
esac