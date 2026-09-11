#!/bin/bash
# obi.stats GPU tool installer — runs INSIDE the user's terminal, launched by
# the "Install & verify" button in the GPU setup card.
#
# It installs the detected GPU's monitoring tool through the system package
# manager (the sudo prompt appears in this terminal), then runs gpu.sh --doctor
# to confirm, and holds the terminal open so the user can read the result.
#
# This script is the helper behind the panel button; gpu.sh --doctor remains
# the manual/verification path. It is meant to be human-in-the-loop: it never
# runs by itself as root, and every step is visible in the terminal.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- resolve vendor + package ------------------------------------------
vendor=$("$DIR/gpu.sh" --vendor 2>/dev/null)
case "$vendor" in
  intel)  PKG="intel-gpu-tools" ;;
  nvidia) PKG="nvidia-utils"    ;;
  amd)    PKG="rocm-smi-lib"    ;;
  *)     PKG="" ;;
esac

if [ -z "$PKG" ]; then
  echo "Could not determine a monitoring tool for the detected GPU."
  echo "Run \`$DIR/gpu.sh --doctor\` for guidance."
  read -rp "Press Enter to close..." _
  exit 1
fi

model=$("$DIR/gpu.sh" 2>/dev/null | awk -F'\t' '$1=="model"{print $2}' | head -1)
echo "Your GPU: ${model:-Unknown}"
echo "Vendor:   ${vendor:-unknown}"
echo "Package:  $PKG"
echo
echo "Installing $PKG (you may be prompted for your password) ..."

# Prefer the Omarchy package wrapper; fall back to a plain pacman for other
# Arch-based systems. Either way the install runs in THIS terminal so the
# password prompt is visible here.
if command -v omarchy-pkg-add >/dev/null 2>&1; then
  omarchy-pkg-add "$PKG"
  rc=$?
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --noconfirm "$PKG"
  rc=$?
else
  echo "No supported package manager found (omarchy-pkg-add / pacman)."
  echo "Please install $PKG manually, then re-open the GPU panel."
  rc=1
fi

echo
if [ "$rc" -eq 0 ]; then
  echo "Installed. Verifying with the GPU doctor:"
  echo
  "$DIR/gpu.sh" --doctor
else
  echo "Install did not complete cleanly (exit $rc)."
  echo "Re-run \`$DIR/gpu.sh --doctor\` after installing $PKG."
fi

echo
read -rp "Press Enter to close this terminal..." _
exit $rc