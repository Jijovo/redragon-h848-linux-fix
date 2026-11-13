# Redragon H848 / XiiSound `040b:0897` — Linux audio fix

> [!WARNING]
> **AI disclosure.** This repository — diagnosis, scripts, and documentation —
> was produced with the help of an AI coding assistant (DeepSeek V4.1 Flash via
> OpenCode), working from live diagnostics on a physical machine. The fix was
> verified on the hardware listed below, but everything here is provided
> **as-is, without warranty**. Review the scripts and confirm the result on
> your own system before relying on it.

Fixes the broken USB audio on Redragon H848 (and Fuxi-family) headsets on Linux:

- Silent below 100 % volume
- At ~100 % only one ear works
- The dead ear can flip between boots
- Bluetooth is unaffected (it never touches the broken path)

> [!CAUTION]
> **Read the script before you run it.**
>
> `install.sh` modifies your audio configuration and needs `sudo` for two steps.
> **Do not** pipe it into a shell (`curl … | bash`). Clone or download the
> repo, open `install.sh`, read every line, then run it.
>
> This is a **hardware-firmware workaround**, not a driver fix. It is fully
> reversible with `uninstall.sh`, but you should know what it does first.

Tested on **CachyOS (Arch)** — PipeWire 1.6.11, WirePlumber 0.5.19, kernel
7.3.4 — on an HP Victus 15 (ALC245). Any distro using PipeWire + WirePlumber
should behave the same.

---

## Quick start

```bash
git clone git@github.com:Jijovo/redragon-h848-linux-fix.git
cd redragon-h848-linux-fix
less install.sh          # <-- read it first
./install.sh
./verify.sh
```

Run it once with the **dongle** connected and once with the **USB cable**
connected (the two modes save state under different card IDs).

---

## What is actually broken

The dongle and the USB cable both enumerate as USB audio class device
`040b:0897` (Weltrend / XiiSound), driver `snd-usb-audio`.

Its firmware is buggy:

1. It advertises a **bogus hardware volume range of 0.00 dB → 0.39 dB**
   (a real control spans tens of dB).
2. It exposes a stereo `PCM,0` and a hidden mono master `PCM,1`.
3. **Any volume-register write below maximum silences one channel.** The
   channel that dies can change.

PipeWire maps the slider through dB, so:

```
slider < 100 %  →  target dB below the device's 0.00 dB minimum
                →  clamped to register 0
                →  silence / one ear only
slider = 100 %  →  register ~100 → one channel happens to survive
```

Bluetooth is unaffected because it uses AVRCP / a digital path, not this USB
hardware mixer.

Confirmed previously in [linuxmint/linuxmint#822](https://github.com/linuxmint/linuxmint/issues/822)
(same USB ID).

## The fix (three layers)

| Layer | What | Why |
|---|---|---|
| 1 | Pin `PCM,0 = 100,100`, `PCM,1 = 100`, unmuted | keep the hardware at max |
| 2 | `sudo alsactl store` | re-applied on boot **and** replug by `alsa-restore` |
| 3 | `api.alsa.soft-mixer = true` in WirePlumber | slider becomes software-only; registers are never written again |

Layer 3 must be installed **system-wide** (`/etc/wireplumber/…`) *and* per-user
(`~/.config/wireplumber/…`). The system-wide copy is not optional — see
[Why a per-user config alone fails](#why-a-per-user-config-alone-fails).

## Install

### Option A — script

```bash
./install.sh
```

It will show you the changes and ask for confirmation, then:

1. set `PCM,0` / `PCM,1` to 100 % and unmute
2. `sudo alsactl store`
3. install the WirePlumber rule in `~/.config` and `/etc`
4. restart WirePlumber

Use `--yes` to skip the prompt (not recommended for a first run).

### Option B — manual

```bash
# 1. find the card id (it changes between boots; never use the number)
CARD=$(awk '/H848/{match($0,/\[[^]]+\]/); s=substr($0,RSTART+1,RLENGTH-2); gsub(/[[:space:]]/,"",s); print s; exit}' /proc/asound/cards)
echo "$CARD"

# 2. pin the mixer
amixer -c "$CARD" sset 'PCM',0 100% unmute
amixer -c "$CARD" sset 'PCM',1 100% unmute

# 3. persist
sudo alsactl store

# 4. install the rule (same file, two locations)
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
install -m644 configs/52-h848-soft-mixer.conf \
  ~/.config/wireplumber/wireplumber.conf.d/
sudo install -Dm644 configs/52-h848-soft-mixer.conf \
  /etc/wireplumber/wireplumber.conf.d/

# 5. reload
systemctl --user restart wireplumber
```

## Verify

```bash
./verify.sh
```

or manually:

```bash
pactl list sinks | grep -A8 H848        # Base Volume: 100% / 0.00 dB, no HW_VOLUME_CTRL
amixer -c "$CARD" contents | grep -A3 "PCM Playback Volume"   # -> 100,100 and 100
```

Expected sink flags after the fix: `HARDWARE DECIBEL_VOLUME LATENCY`
(`HW_VOLUME_CTRL` and `HW_MUTE_CTRL` are gone).

Then move the slider around — the `amixer` values must stay `100,100`.

## Both connection modes

ALSA saves state **by card ID**, and the two modes differ only in case:

| Mode | USB product string | ALSA card ID | state key |
|---|---|---|---|
| 2.4 GHz dongle | `H848 Wireless headset` | `headset` | `state.headset` |
| USB cable | `H848 USB Gaming Headset` | `Headset` | `state.Headset` |

So run the installer once in each mode. `alsactl store` **preserves the entry
for the mode that is currently unplugged**, so you only need to do it once per
mode. Never delete either entry.

## Why a per-user config alone fails

A per-user-only installation can appear to work until the first reboot, after
which one channel may go silent again.

The login manager — `plasmalogin` (KDE Plasma Login Manager), SDDM, GDM, etc.
— starts its own PipeWire/WirePlumber **as the greeter user, before login**.
That instance has a different `$HOME`, never sees the `~/.config` rule, and
writes the broken hardware volume once per boot. The user session then inherits
the damaged registers.

That is why the rule is also installed in `/etc/wireplumber/wireplumber.conf.d/`,
which applies to every user including the greeter.

If replug works but reboot does not, this is the reason.

## Undo

```bash
./uninstall.sh
```

It removes both WirePlumber rules and restarts WirePlumber. The saved
`asound.state` keeps the hardware at maximum, which is harmless; replug the
headset to return it to firmware defaults.

For a full manual rollback, restore `/var/lib/alsa/asound.state` from a backup
made before installing.

## Troubleshooting

- **Card number changes between boots.** Always address it by ID:
  `amixer -c headset` / `amixer -c Headset`, never `amixer -c 4`.
- **One ear dead after reboot, replug fixes it** → the greeter rule is missing
  (`/etc/wireplumber/wireplumber.conf.d/`). See above.
- **Installed on a distro without `/etc/wireplumber`** → create it; WirePlumber
  0.5 reads `$XDG_CONFIG_HOME/wireplumber`, `/etc/wireplumber`, and
  `/usr/share/wireplumber`.
- **Not using WirePlumber** (plain PulseAudio, PipeWire + media-session) → the
  `soft-mixer` rule won't apply. You'll need the equivalent mechanism for your
  sound server, or keep the hardware pinned and use ALSA softvol.
- **Verify the mixer control names first.** This fix assumes `PCM,0` and
  `PCM,1`. Run `amixer -c "$CARD" scontrols` to confirm before adapting.
- **Windows dual-boot**: disable Windows Fast Startup — it can leave the USB
  controller in a weird state and is a common source of audio weirdness.

## Repo layout

```
.
├── install.sh                       # apply the fix (read before running!)
├── uninstall.sh                     # remove it
├── verify.sh                        # check the current state
├── configs/
│   └── 52-h848-soft-mixer.conf      # the WirePlumber rule
├── docs/
│   └── TESTLOG.md                   # full log of what was tested and why
└── README.md
```

## References

- [linuxmint/linuxmint#822 — USB headset `040b:0897` plays one channel](https://github.com/linuxmint/linuxmint/issues/822)
- PipeWire ALSA properties: `api.alsa.soft-mixer`
- WirePlumber ALSA configuration docs
