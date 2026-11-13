# Redragon H848 / XiiSound `040b:0897` — Linux audio fix

> [!WARNING]
> **AI disclosure.** This repository — diagnosis, scripts, and documentation —
> was produced with the help of an AI coding assistant (DeepSeek V4.1 Flash via
> OpenCode), working from live diagnostics on a physical machine. The fix was
> verified on the hardware listed below, but everything here is provided
> **as-is, without warranty**. Review the scripts and confirm the result on
> your own system before relying on it.

Fixes the broken USB audio on Redragon H848 headsets on Linux:

- Silent below 100 % volume
- At ~100 % only one ear works
- The dead ear can flip between boots
- Bluetooth is unaffected (it never touches the broken path)

Other headsets that share USB ID `040b:0897` — and devices with a similar
volume-mapping bug — are covered in
[Using this on other headphones](#using-this-on-other-headphones).

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

## Using this on other headphones

**Scope:** everything in this repository was verified only on the Redragon H848
(dongle and USB cable). The rest of this section is guidance for deciding
whether the same approach applies to other hardware, and how to adapt it
manually. No other model has been tested here.

### Does this problem apply to my device?

The signature is a **volume-mapping bug in the device firmware**, not a broken
headset. It is plausible if most of these are true:

- It connects over **USB** (dongle or cable). Bluetooth and 3.5 mm are different
  paths and are not affected by anything in this repo.
- Moving the volume slider has a **discontinuity**: below some threshold there
  is silence or only one channel, while Windows behaves normally.
- `pactl list sinks` shows an implausible `Base Volume` — e.g. a maximum of
  `-0.39 dB` instead of `0.00 dB`, or a range of only a fraction of a dB.
- `amixer -c <card> contents` shows a `dBminmax` range of a few tenths of a dB
  across the whole 0–100 register range.
- Moving the PipeWire slider **writes the hardware registers**. That is the
  mechanism that breaks: those writes cannot express anything below maximum.

Run these three checks before changing anything:

```bash
cat /proc/asound/cards                              # note the [card-id] in brackets
CARD=<card-id>                                      # e.g. headset, FuxiH3
pactl list sinks | grep -B4 -A6 'Base Volume:'      # wrong/very narrow max dB?
amixer -c "$CARD" contents | grep -B3 -A3 dBminmax  # tiny range?
```

Then wiggle the slider and watch the registers:

```bash
amixer -c "$CARD" contents | grep -A3 'Playback Volume'
pactl set-sink-volume @DEFAULT_SINK@ 30%
amixer -c "$CARD" contents | grep -A3 'Playback Volume'   # did it change?
```

If the registers move when the slider moves, and low values produce silence,
the `soft-mixer` part of this fix is the relevant piece. If they do **not**
move, the bug is elsewhere (see
[Where this will not help](#where-this-will-not-help)).

### Do the install and uninstall scripts work for other headphones?

**No — on purpose.** The scripts are deliberately narrow and fail closed rather
than silently doing something wrong on hardware that was never tested:

| Script | Works on another headset? | Why |
|---|---|---|
| `install.sh` | **No** — refuses to run | It hard-codes the device in four places: the `lsusb -d 040b:0897` presence check, the `awk '/H848/'` card-ID lookup, the `'PCM',0` control check, and the `XiiSound_Technology_Corporation_` match in the rule. On a different card it exits with an error rather than guessing. |
| `verify.sh` | **No** — reports false failures | It looks for `040b:0897`, a card ID containing `H848`, a sink named `alsa_output.usb-XiiSound…`, and the exact string `Base Volume: 65536 / 100% / 0.00 dB`. A perfectly working other device would still show `[FAIL]`. |
| `uninstall.sh` | **Yes, if you install your adapted rule under the same filename** | It only deletes two fixed paths (`…/52-h848-soft-mixer.conf` in `~/.config` and `/etc`) and restarts WirePlumber. It never touches `asound.state`, so any hardware volume pinned at maximum stays pinned until the device is replugged. |
| `configs/52-h848-soft-mixer.conf` | **No** — matches nothing else | The rule matches `device.name` with the glob `~alsa_card.usb-XiiSound_Technology_Corporation_.*`. |

That is also why the script cannot simply be "made generic": the correct
control names, card ID and device name differ per model, and claiming support
for hardware that was never tested would be worse than refusing.

### The same USB ID on other models

`040b:0897` (Weltrend / XiiSound) is shared by several headsets that report the
same 0.00–0.39 dB volume range and the same dual `PCM,0` / `PCM,1` layout:

| Device | ALSA card ID | Notes |
|---|---|---|
| Redragon H848 (2.4 GHz dongle) | `headset` | tested here |
| Redragon H848 (USB cable) | `Headset` | tested here |
| Redragon H510-PRO / Zeus Pro | `headset` / `Headset` | same layout, same range |
| Havit Fuxi-H3 | `FuxiH3` | control numbers may be `numid=9` / `numid=10` |
| Havit Fuxi-H7SE | `FuxiH7SE` | same diagnosis reported |

They are **not** identical: the card ID changes, and on some firmware `PCM,1` is
a **switch only** (no volume), so `sset 'PCM',1 100%` fails and `sset 'PCM',1 on`
is the correct form. The approach transfers; the literal commands do not.

### Adapting the fix manually

Only proceed if the checks above matched. Work in this order — each step is
reversible, and step 7 is the one that catches the reboot regression.

**0. Back up first**

```bash
CARD=<your card id>
sudo cp /var/lib/alsa/asound.state ~/asound.state.before
amixer -c "$CARD" contents > ~/amixer.before.txt
```

**1. Find the card ID and PipeWire device name**

```bash
cat /proc/asound/cards
pactl list cards | grep -E 'Name:|alsa.card_name|device.description'
```

The `Name:` line is the `device.name` you need in the rule (e.g.
`alsa_card.usb-…`). Never use the card *number* — it changes between boots.

**2. List the controls and confirm the bogus range**

```bash
amixer -c "$CARD" scontrols
amixer -c "$CARD" contents | grep -B2 -A4 dBminmax
```

Note the control names (`Master`, `PCM`, `Headphone`, `Speaker`, …), their
indices, and whether each is a volume or a switch. This repo's fix assumes
`PCM,0` (stereo) plus `PCM,1` (mono master); yours may differ or may have only
one control.

**3. Pin the hardware at maximum**

```bash
amixer -c "$CARD" sset 'PCM',0 100% unmute      # adjust the name
amixer -c "$CARD" sset 'PCM',1 100% unmute      # volume form
amixer -c "$CARD" sset 'PCM',1 on               # switch-only form
```

Use `sget` to confirm the result, and keep the physical volume low while
testing — sound can return at full volume.

**4. Persist it**

```bash
sudo alsactl store
```

ALSA keys this state by **card ID**, case-sensitively, so the same headset in
two connection modes can need two runs. `alsactl store` **preserves entries for
cards that are currently absent**, so storing once per mode is enough.

**5. Install a rule matching *your* device**

```conf
# ~/.config/wireplumber/wireplumber.conf.d/52-soft-mixer.conf
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.usb-Your_Device.*" }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  }
]
```

Get the pattern from `pactl list cards`. Matching on `device.vendor.id` /
`device.product.id` is an alternative that survives product-string changes, but
verify it lands with `pw-dump` before relying on it. Install the file in **both**
locations — the system-wide copy is what covers the login greeter, for the same
reason as in [Why a per-user config alone fails](#why-a-per-user-config-alone-fails):

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
install -m644 52-soft-mixer.conf ~/.config/wireplumber/wireplumber.conf.d/
sudo install -Dm644 52-soft-mixer.conf /etc/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

Two more documented properties can be tried if `soft-mixer` alone is not enough:
`api.alsa.ignore-dB = true` (driver reports wrong dB values) and
`api.alsa.disable-mixer-path = true` (jack-based mixer paths misbehave). Note
that `api.alsa.enable-hw-volume` appears in some third-party configs but is not
in the official PipeWire property list — check before copying it.

**6. Verify generically**

```bash
pactl list sinks | grep -B6 -A6 'Base Volume:'
amixer -c "$CARD" contents | grep -A3 'Playback Volume'
pactl set-sink-volume @DEFAULT_SINK@ 20%
amixer -c "$CARD" contents | grep -A3 'Playback Volume'
```

Make sure the headset is the default sink first (`wpctl status`). Success looks
like: `HW_VOLUME_CTRL` is gone from `Flags:`, the slider still changes loudness,
and the hardware registers **do not change** while the slider moves. On this
device `Base Volume` also becomes `100% / 0.00 dB`; on other hardware that value
may stay odd even when the fix works, so judge by the registers.

**7. Reboot and re-test**

A per-user-only installation can look fine until the next boot, when the
display manager's own PipeWire instance rewrites the registers. If it regresses
after reboot but works after replug, the `/etc` rule is missing or not matching.

**8. Rolling back a manual adaptation**

```bash
sudo cp ~/asound.state.before /var/lib/alsa/asound.state
sudo alsactl restore
rm -f ~/.config/wireplumber/wireplumber.conf.d/52-soft-mixer.conf
sudo rm -f /etc/wireplumber/wireplumber.conf.d/52-soft-mixer.conf
systemctl --user restart wireplumber
```

Replug the device afterwards so the firmware returns to its own defaults.

### Where this will not help

- **Vendor-HID volume** (e.g. SteelSeries Arctis on some models): there is no
  USB Audio Class volume control to disable, so `soft-mixer` has nothing to act
  on.
- **Sticky/fake `GET_CUR` firmware** (e.g. Logitech PRO X 2 `046d:0af7`): the
  `soft-mixer` properties do apply, yet PipeWire still writes the mixer; it
  needs a kernel quirk (`mixer_get_cur_broken`) instead. Disabling the quirk
  makes the device beep on every volume step.
- **Devices with no hardware volume control at all**: nothing to pin, nothing to
  bypass.
- **Genuine kernel/driver regressions**: one Razer soundbar was fixed by
  `soft-mixer` on one stack and not on another kernel branch, where only a
  downgrade worked. Treat this as a workaround for firmware behaviour, not a
  universal cure.
- **Bluetooth and analog connections**: unrelated audio paths.
- **Audio that is silent for a different reason** (wrong profile, muted switch
  at the ALSA level, suspended device): the checks in
  [Does this problem apply to my device?](#does-this-problem-apply-to-my-device)
  will not match; see the generic USB-audio troubleshooting instead.

### Reports on other hardware

Same class of bug, same remedy, different devices:

- [Jabra Evolve3 65 on Linux](https://schnouki.net/post/2026/jabra-evolve3-65-on-linux)
  — abrupt silence below ~10 %, fixed with one `soft-mixer` rule.
- [Razer Leviathan V2 X (CachyOS forum)](https://discuss.cachyos.org/t/razer-leviathan-v2-x-audio-cuts-off-muted-completely-below-34-volume-after-updating-to-kernel-7-1-x/31906)
  — silent below ~34 %, fixed with `soft-mixer` plus pinning the bar at 100 %.
- [USB headset mutes below 25 % (Arch BBS)](https://bbs.archlinux.org/viewtopic.php?pid=2247677)
  — same diagnosis and fix on unrelated hardware.
- [Havit Fuxi-H3 on Fedora 44](https://discussion.fedoraproject.org/t/havit-fuxi-h3-fix-for-silent-audio-and-right-channel-dropouts-on-fedora-44/205348)
  — same `040b:0897` dongle family.
- [linuxmint/linuxmint#822](https://github.com/linuxmint/linuxmint/issues/822)
  — H848/Fuxi-H7SE diagnosis, including the proposal for a kernel quirk.

If you get this working on another model, a report with the card ID,
`device.name`, control names, distro/audio-stack versions and before/after
`amixer` values is welcome — scrub serial numbers and MAC addresses first.

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
