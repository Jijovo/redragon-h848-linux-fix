#!/usr/bin/env bash
# =============================================================================
#  READ THIS SCRIPT BEFORE RUNNING IT.
#
#  This fixes audio for the Redragon H848 / XiiSound USB id 040b:0897 on Linux
#  by (1) pinning the device's broken hardware volume at maximum, (2) saving
#  that state with alsactl, and (3) telling WirePlumber to use software volume
#  only.
#
#  It needs root for exactly two steps:
#      sudo alsactl store
#      sudo install ... /etc/wireplumber/wireplumber.conf.d/
#  Everything else runs as your user.
#
#  Do NOT run this as `curl ... | bash`.
#  Do NOT run it with sudo (only the two commands above use sudo).
#
#  Reversible with ./uninstall.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="$REPO_DIR/configs/52-h848-soft-mixer.conf"

USER_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
USER_CONF="$USER_CONF_DIR/52-h848-soft-mixer.conf"
SYS_CONF="/etc/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf"

ASSUME_YES=0
case "${1:-}" in
  --yes|-y) ASSUME_YES=1 ;;
  "") ;;
  *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not as root/sudo"

for c in amixer pactl systemctl lsusb; do
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done

[ -f "$CONF_SRC" ] || die "missing config: $CONF_SRC"

if ! lsusb -d 040b:0897 >/dev/null 2>&1; then
  die "Redragon H848 (USB 040b:0897) not found.
Connect the 2.4 GHz dongle or the USB cable, wait a second, then retry."
fi

CARD_ID="$(awk '/H848/{
    if (match($0, /\[[^]]+\]/)) {
      s = substr($0, RSTART + 1, RLENGTH - 2)
      gsub(/[[:space:]]/, "", s)
      print s
      exit
    }
  }' /proc/asound/cards)"

[ -n "$CARD_ID" ] || die "could not find the H848 ALSA card in /proc/asound/cards"
say "Card id: $CARD_ID"

if ! amixer -c "$CARD_ID" scontrols 2>/dev/null | grep -q "'PCM',0"; then
  die "controls 'PCM,0'/'PCM,1' not found on card '$CARD_ID'.
Run: amixer -c '$CARD_ID' scontrols
This guide targets the H848/Fuxi mixer layout; adapt the control names if yours differs."
fi

# --- explain + confirm -------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
  say ""
  say "This will:"
  say "  1. set 'PCM',0 and 'PCM',1 to 100% and unmute them on card '$CARD_ID'"
  say "  2. run: sudo alsactl store"
  say "  3. install: $USER_CONF"
  say "  4. install: $SYS_CONF   (sudo; needed for the login greeter)"
  say "  5. run: systemctl --user restart wireplumber"
  say ""
  printf 'Continue? [y/N] '
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

# --- 1. pin hardware ---------------------------------------------------------
say ""
say "==> pinning hardware mixer at maximum"
amixer -c "$CARD_ID" sset 'PCM',0 100% unmute >/dev/null
amixer -c "$CARD_ID" sset 'PCM',1 100% unmute >/dev/null
amixer -c "$CARD_ID" contents \
  | grep -A3 "name='PCM Playback Volume'" \
  | grep 'values=' || true

# --- 2. persist --------------------------------------------------------------
say "==> saving ALSA state (sudo)"
sudo alsactl store

# --- 3. install rules --------------------------------------------------------
say "==> installing WirePlumber rule"
mkdir -p "$USER_CONF_DIR"
install -m 644 "$CONF_SRC" "$USER_CONF"
say "    $USER_CONF"
sudo install -Dm644 "$CONF_SRC" "$SYS_CONF"
say "    $SYS_CONF"

# --- 4. reload ---------------------------------------------------------------
say "==> restarting WirePlumber"
systemctl --user restart wireplumber
sleep 1

# --- summary -----------------------------------------------------------------
say ""
say "==> current sink"
pactl list sinks 2>/dev/null \
  | awk '/Name: alsa_output.usb-XiiSound/{f=1} f{print} f&&/^$/{exit}' \
  | grep -E 'Name:|Mute:|Volume:|Base Volume:|Flags:' || true

say ""
say "Expected: 'Base Volume: 100% / 0.00 dB' and no HW_VOLUME_CTRL."
say "Run ./verify.sh to check, and run this script again in the other"
say "connection mode (dongle <-> USB cable) to save both card ids."
