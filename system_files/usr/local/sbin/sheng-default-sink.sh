#!/bin/sh
# Pin the default audio sink to the real speaker, and work around a boot race:
# WirePlumber can start before the sheng sound card is ready, in which case no
# real sink is created (only a "null-sink" fallback) -> silence. If the real
# sink is missing at session start, restart the PipeWire stack once so it
# re-opens the (now ready) card.
#
# Volume is intentionally NOT forced here: WirePlumber already persists the
# user's last volume/mute per node and restores it, so setting a value would
# clobber the user's setting on every login.
SINK=alsa_output.platform-sound.playback.0.0

for _ in $(seq 1 8); do
    pactl list short sinks 2>/dev/null | grep -q "$SINK" && break
    sleep 1
done

if ! pactl list short sinks 2>/dev/null | grep -q "$SINK"; then
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    for _ in $(seq 1 15); do
        pactl list short sinks 2>/dev/null | grep -q "$SINK" && break
        sleep 1
    done
fi

pactl set-default-sink "$SINK" 2>/dev/null || true
