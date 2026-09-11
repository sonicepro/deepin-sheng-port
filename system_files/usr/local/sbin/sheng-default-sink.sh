#!/bin/sh
# Pin the default audio sink to the real speaker. pipewire-pulse / wireplumber
# can leave a fallback "null-sink" as the default when the card isn't ready yet,
# which silences output. Runs at session start (after pipewire is up).
for _ in $(seq 1 20); do
    pactl list short sinks 2>/dev/null | grep -q 'platform-sound.playback.0.0' && break
    sleep 1
done
pactl set-default-sink alsa_output.platform-sound.playback.0.0 2>/dev/null || true
pactl set-sink-volume @DEFAULT_SINK@ 80% 2>/dev/null || true
pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
