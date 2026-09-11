#!/bin/bash
# SM8550 (sheng) speaker bring-up.
#
# Deepin's PipeWire/WirePlumber does not apply this card's ALSA UCM (it only
# exposes generic profiles and leaves the cs35l43 speaker amps OFF), so apply
# the UCM "HiFi" verb (sets the mixer routing) and switch the six cs35l43 amps
# on. Run once after the audio stack has settled.
set -u

# wait for the sound card
for _ in $(seq 1 30); do
    [ -e /proc/asound/card0/id ] && break
    sleep 1
done
# let pipewire / wireplumber finish probing the card
sleep 5

CARD=0
alsaucm -c "hw:${CARD}" set _verb HiFi 2>/dev/null || true
for a in TLH TLL TRL BLH BLL BRL; do
    amixer -c "$CARD" sset "$a AMP Enable" on >/dev/null 2>&1 || true
done
