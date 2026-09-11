#!/bin/bash
# SM8550 (sheng) audio bring-up workaround.
#
# On early boot the snd-sc8280xp card probes BEFORE the ADSP audio protection
# domain is ready, producing "qcom-apm gprsvc: CMD timeout for [...] opcode"
# and leaving no working playback. Once the ADSP is up, re-probe the sound card
# so the q6 APM / lpass clock state is re-initialized (documented workaround).
set -u

# Wait for the ADSP remoteproc to reach "running".
for _ in $(seq 1 90); do
    if [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = "running" ]; then
        break
    fi
    sleep 1
done
# Let the audio protection domain settle.
sleep 3

drv=/sys/bus/platform/drivers/snd-sc8280xp
if [ -e "$drv/sound" ]; then
    echo sound > "$drv/unbind" 2>/dev/null || true
    sleep 2
    echo sound > "$drv/bind" 2>/dev/null || true
fi
