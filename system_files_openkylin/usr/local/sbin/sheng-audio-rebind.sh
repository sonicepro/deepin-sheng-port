#!/bin/bash
# SM8550 (sheng) audio bring-up for openKylin.
#
# The snd-sc8280xp machine driver (DT platform device "sound") normally
# autoloads ~10 s into boot, BEFORE the ADSP audio subsystem is ready. The probe
# then fails hard:
#     q6apm-dai ...: Audio Start: Buffer Allocation failed rc = -22
#     snd-sc8280xp sound: probe with driver snd-sc8280xp failed with error -22
# which leaves the ADSP q6APM session wedged, so every later re-bind keeps
# failing and the system ends up with "no soundcards". On other boots the probe
# merely returns DEFER (the card binds a bit later) and audio works — that is
# the "audio works on some boots, not others" flakiness.
#
# Fix: blacklist the module (see /etc/modprobe.d/sheng-audio.conf) so it never
# probes early, and load it HERE, once, after the ADSP is up and the SoundWire
# codec has bound. This avoids the wedging early probe entirely; no unbind/bind
# re-probe (that path was already risky and is no longer needed).
set -u

# 1) The WCD938x codec core registers the codec DAIs the card needs; openKylin's
#    udev does not autoload it (snd-soc-wcd938x-sdw comes in as a dependency).
modprobe snd_soc_wcd938x 2>/dev/null || true

# 2) Wait for the ADSP remoteproc to reach "running".
for _ in $(seq 1 120); do
    [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = running ] && break
    sleep 1
done

# 3) Wait for the SoundWire codec to bind (card components depend on it).
for _ in $(seq 1 60); do
    [ -e /sys/bus/platform/devices/audio-codec/driver ] && break
    sleep 1
done

# 4) Stay past the early-boot window the kernel would have probed in, then let
#    the ADSP audio protection domain settle.
while [ "$(cut -d. -f1 /proc/uptime)" -lt 20 ]; do sleep 1; done
sleep 3

card_up() { grep -q Xiaomi /proc/asound/cards 2>/dev/null; }
card_up && exit 0

# 5) Load the machine driver (binds the DT "sound" device). Retry briefly in case
#    the ADSP needs a little longer on this boot.
for _ in $(seq 1 10); do
    modprobe snd_soc_sc8280xp 2>/dev/null || true
    sleep 2
    card_up && exit 0
done

echo "sheng-audio-rebind: soundcard still not up after retries" >&2
exit 1
