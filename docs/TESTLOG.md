# Test log — Redragon H848 `040b:0897` on Linux

Chronological record of the diagnosis and every test performed while building
this fix. Kept so the reasoning is auditable and so future regressions are easy
to compare against.

- **Date:** 2026-11-13
- **Distro:** CachyOS (Arch, rolling)
- **Kernel:** 7.3.4-1-cachyos
- **PipeWire:** 1:1.6.11-1
- **WirePlumber:** 0.5.19-1.1
- **alsa-ucm-conf:** 1.2.16.1-1
- **Machine:** HP Victus by HP Gaming Laptop 15-fb2xxx (ALC245 codec)
- **Display manager:** `plasmalogin` (KDE Plasma Login Manager)

---

## 1. Identify the device

```
$ lsusb | grep -i 040b
Bus 001 Device 006: ID 040b:0897 Weltrend Semiconductor H848 Wireless headset
```

The **same USB ID** appears for both modes, with different product strings:

| Mode | `lsusb` product string | ALSA card ID |
|---|---|---|
| 2.4 GHz dongle | `H848 Wireless headset` | `headset` |
| USB cable | `H848 USB Gaming Headset` | `Headset` |

Driver is `snd-usb-audio`; the card also exposes a HID interface (`usbhid`).

## 2. Reproduce and inspect (dongle)

```
$ cat /proc/asound/cards
 4 [headset        ]: USB-Audio - H848 Wireless headset
```

```
$ pactl list sinks | grep -A8 H848_Wireless
    Base Volume: 64562 /  99% / -0.39 dB
    Flags: HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME LATENCY
```

`Base Volume` maxing out at `-0.39 dB` is the first red flag: a real output
control should reach `0.00 dB` with tens of dB of range.

```
$ amixer -c 4 contents
numid=9, name='PCM Playback Volume'
  values=2,min=0,max=100
  : values=0,0
  | dBminmax-min=0.00dB,max=0.39dB
numid=10, name='PCM Playback Volume',index=1
  values=1,min=0,max=100
  : values=0
  | dBminmax-min=0.00dB,max=0.39dB
```

Findings:

- Two playback controls: stereo `PCM,0` and hidden mono master `PCM,1`.
- **0.39 dB total range** — the firmware volume implementation is bogus.
- Both were at `0` even though the sink slider was at 70 %.

## 3. Root cause

PipeWire converts the slider to dB. With a 0.00–0.39 dB device range, any
slider value below ~100 % maps below the device minimum and is clamped to
register `0` → silence. At 100 % the register lands near max; one channel
happens to survive, hence "right ear only".

The firmware also misbehaves on volume-register writes: a write below maximum
can kill a channel (the ear that dies varies). Matches the report in
<https://github.com/linuxmint/linuxmint/issues/822>.

## 4. Fix attempt 1 — node-level rule (FAILED)

Rule matched `node.name`:

```conf
monitor.alsa.rules = [
  { matches = [ { node.name = "~alsa_output.usb-XiiSound_Technology_Corporation_.*" } ]
    actions = { update-props = { api.alsa.soft-mixer = true } } }
]
```

Result: property appeared on the node (`pw-dump` confirmed
`api.alsa.soft-mixer = true`), **but** the sink still reported
`HW_VOLUME_CTRL`, and setting 20 % drove `PCM,0` to `0,0`.

Reason: `api.alsa.soft-mixer` is a **device** property and must be applied
before the ACP device/node is built.

## 5. Fix attempt 2 — device-level rule (WORKED)

```conf
monitor.alsa.rules = [
  { matches = [ { device.name = "~alsa_card.usb-XiiSound_Technology_Corporation_.*" } ]
    actions = { update-props = { api.alsa.soft-mixer = true } } }
]
```

After `systemctl --user restart wireplumber`:

```
Base Volume: 65536 / 100% / 0.00 dB
Flags: HARDWARE DECIBEL_VOLUME LATENCY      # HW_VOLUME_CTRL / HW_MUTE_CTRL gone
api.alsa.soft-mixer = true                  # on the device
```

## 6. Verify the slider no longer writes hardware

With `PCM,0 = 100,100` / `PCM,1 = 100`:

```
sweep: 15% -> 90% -> 30% -> 100% -> 45%
registers before: values=100,100 ; values=100
registers after:  values=100,100 ; values=100   ✅ untouched
```

## 7. Replug test (PASS)

Unplug dongle, wait, replug:

```
PCM,0 = 100,100      ✅ restored automatically by alsa-restore
PCM,1 = 100          ✅
Base Volume 100%     ✅
HW_VOLUME_CTRL       ✅ absent
```

## 8. Persist hardware state

```
amixer -c headset sset 'PCM',0 100% unmute
amixer -c headset sset 'PCM',1 100% unmute
sudo alsactl store
```

State saved under the **card id**, confirmed in `/var/lib/alsa/asound.state`:

```
state.headset {
    control.9  PCM Playback Volume        value.0 100  value.1 100
    control.10 PCM Playback Volume index1 value 100
}
```

## 9. USB cable mode — case-sensitive card id

Switched to the USB cable. No audio at all, even at 100 %.

```
0 [Headset]  USB-Audio - H848 USB Gaming Headset     # capital H
```

The saved state was `state.headset` (lowercase). `alsactl` is case-sensitive,
so nothing was restored and the registers sat at `0,0` / `0`.

Fixed by pinning and storing once more:

```
amixer -c Headset sset 'PCM',0 100% unmute
amixer -c Headset sset 'PCM',1 100% unmute
sudo alsactl store
```

### Does `alsactl store` keep the other mode's entry?

Tested with a scratch state file (no root needed):

```
$ cp /var/lib/alsa/asound.state /tmp/store-test.state
$ echo 'state.fakecard { ... }' >> /tmp/store-test.state
$ alsactl -f /tmp/store-test.state store
$ grep '^state\.' /tmp/store-test.state
state.NVidia { ... }
state.headset { ... }
state.fakecard { ... }
state.Headset { ... }        # added, fakecard preserved
```

**Yes** — absent cards' entries are preserved. One store per mode is enough.

Final state file contains both:

```
state.headset  → PCM 100,100
state.Headset  → PCM 100,100
```

## 10. Reboot test — REGRESSION (one ear dead)

After reboot on the dongle:

```
PCM,0 = 0,0        ❌
PCM,1 = 100        ✅
sink Base Volume 100% / HW_VOLUME_CTRL absent
```

The state file was correct (`100,100`), so something rewrote `PCM,0` **after**
the restore.

Isolation tests:

- Restarting WirePlumber with `alsactl monitor` running → **no writes to hw:0**.
- Playing a sound → registers unchanged.
- Shutdown-time `alsactl store` → saved `100,100` (good).

## 11. Found the greeter

Boot journal:

```
10:17:34  New session 'c1' of user 'plasmalogin' class greeter
10:17:35  systemd[1176]: Started PipeWire Multimedia Service     <-- greeter
10:17:42  New session '2' of user '<user>'
10:17:43  systemd[1475]: Started PipeWire Multimedia Service     <-- user
```

**The login manager starts PipeWire/WirePlumber as the `plasmalogin` greeter
user before login.** That instance reads the greeter's `$HOME`, never sees the
per-user rule in `~/.config`, and writes the broken hardware volume once per
boot. The user session then inherits `PCM,0 = 0,0`.

This also explains: **replug works, reboot fails.**

## 12. Final fix — system-wide rule

Installed the same rule in both places:

```
~/.config/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf
/etc/wireplumber/wireplumber.conf.d/52-h848-soft-mixer.conf   # sudo
```

`/etc/wireplumber` is in WirePlumber 0.5's config search path
(`$XDG_CONFIG_HOME`, `/etc`, `/usr/share`), so it applies to every user,
greeter included.

## 13. Final verification after reboot (PASS)

| Check | Result |
|---|---|
| `/etc/.../52-h848-soft-mixer.conf` | installed |
| `PCM,0` after boot | `100,100` |
| `PCM,1` | `100` |
| sink `Base Volume` | `100% / 0.00 dB` |
| `HW_VOLUME_CTRL` | absent |
| volume sweep | registers untouched |
| `state.headset` / `state.Headset` | both `100,100` |
| dongle audio | stereo at any volume |
| USB-cable audio | stereo at any volume |
| microphone | working |

## 14. Gotchas recorded for future maintainers

- Card **number** changes between boots (`card 4` → `card 0`). Address by id.
- Card **id is case-sensitive**: `headset` (dongle) vs `Headset` (cable).
- `api.alsa.soft-mixer` must match `device.name`, not `node.name`.
- Per-user `/etc`-less configs break after reboot because of the greeter.
- `alsactl store` preserves entries for absent cards.
- Package updates do not touch `~/.config` or `/etc`; `/usr/share` is replaced.
