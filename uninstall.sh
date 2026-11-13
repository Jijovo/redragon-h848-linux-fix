#!/usr/bin/env bash
# =============================================================================
#  READ THIS SCRIPT BEFORE RUNNING IT.
#
#  Removes the Redragon H848 / XiiSound 040b:0897 soft-mixer workaround:
#    - deletes the per-user WirePlumber rule
#    - deletes the system-wide WirePlumber rule (sudo)
#    - restarts WirePlumber
#
#  The saved /var/lib/alsa/asound.state keeps the hardware at maximum. That is
#  harmless; replug the headset to let the firmware reset to its defaults.
# =============================================================================
set -euo pipefail

USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf"
SYS_CONF="/etc/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf"

say() { printf '%s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }

say "==> removing WirePlumber rules"
if [ -f "$USER_CONF" ]; then
  rm -f "$USER_CONF"
  say "    removed $USER_CONF"
else
  say "    $USER_CONF not present"
fi

if [ -f "$SYS_CONF" ]; then
  sudo rm -f "$SYS_CONF"
  say "    removed $SYS_CONF"
else
  say "    $SYS_CONF not present"
fi

say "==> restarting WirePlumber"
systemctl --user restart wireplumber

say ""
say "Removed. Replug the headset to return the hardware to firmware defaults."
say "Hardware volume may stay at maximum until then — harmless."
