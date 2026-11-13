#!/usr/bin/env bash
# Check whether the Redragon H848 / XiiSound 040b:0897 workaround is active.
# Read-only: changes nothing. Exit 0 = healthy, 1 = problem detected.
set -uo pipefail

ok=0
warn=0

say()  { printf '%s\n' "$*"; }
good() { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; warn=1; }
note() { printf '  [note] %s\n' "$*"; }

say "== device =="
if lsusb -d 040b:0897 >/dev/null 2>&1; then
  lsusb -d 040b:0897 | sed 's/^/  /'
else
  bad "040b:0897 not connected (plug in the dongle or USB cable)"
fi

CARD_ID="$(awk '/H848/{
    if (match($0, /\[[^]]+\]/)) {
      s = substr($0, RSTART + 1, RLENGTH - 2)
      gsub(/[[:space:]]/, "", s)
      print s
      exit
    }
  }' /proc/asound/cards)"

say ""
say "== alsa card =="
if [ -n "$CARD_ID" ]; then
  good "card id: $CARD_ID  (address by id, never by number)"
else
  bad "H848 card not found"
fi

say ""
say "== hardware volume (must be 100,100 / 100) =="
if [ -n "$CARD_ID" ]; then
  regs="$(amixer -c "$CARD_ID" contents 2>/dev/null \
    | grep -A3 "name='PCM Playback Volume'" \
    | grep 'values=' | tr -d ' ' | paste -sd' ')"
  say "  $regs"
  if printf '%s' "$regs" | grep -q 'values=100,100' \
     && printf '%s' "$regs" | grep -q 'values=100' ; then
    good "hardware pinned at maximum"
  else
    bad "hardware not at maximum -> run ./install.sh"
  fi
else
  bad "cannot read mixer without a card"
fi

say ""
say "== pipewire sink =="
if command -v pactl >/dev/null 2>&1; then
  sink="$(pactl list sinks 2>/dev/null \
    | awk '/Name: alsa_output.usb-XiiSound/{f=1} f{print} f&&/^$/{exit}')"
  if [ -n "$sink" ]; then
    printf '%s\n' "$sink" | grep -E 'Name:|Mute:|Volume:|Base Volume:|Flags:' | sed 's/^/  /'
    if printf '%s' "$sink" | grep -q 'Base Volume: 65536 / 100% / 0.00 dB'; then
      good "base volume is 100% / 0.00 dB"
    else
      bad "base volume is not 100% / 0.00 dB"
    fi
    if printf '%s' "$sink" | grep -q 'HW_VOLUME_CTRL'; then
      bad "HW_VOLUME_CTRL still present -> soft-mixer rule not active"
    else
      good "HW_VOLUME_CTRL absent (software volume)"
    fi
  else
    bad "no H848 sink in PipeWire"
  fi
else
  note "pactl not found"
fi

say ""
say "== wireplumber rules =="
USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf"
SYS_CONF="/etc/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf"
[ -f "$USER_CONF" ] && good "user rule:   $USER_CONF" || bad "user rule missing: $USER_CONF"
[ -f "$SYS_CONF" ]  && good "system rule: $SYS_CONF"  || bad "system rule missing: $SYS_CONF (needed for the login greeter)"

say ""
say "== saved alsactl state =="
if [ -r /var/lib/alsa/asound.state ]; then
  for k in headset Headset; do
    if grep -q "^state\.$k" /var/lib/alsa/asound.state; then
      good "state.$k present"
    else
      note "state.$k absent (only needed for the mode you have used)"
    fi
  done
else
  note "cannot read /var/lib/alsa/asound.state"
fi

say ""
if [ "$warn" -eq 0 ]; then
  say "Result: all good."
  exit 0
else
  say "Result: problems found (see [FAIL] above)."
  exit 1
fi
