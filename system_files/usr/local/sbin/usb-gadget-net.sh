#!/bin/bash
# Bring up a USB RNDIS/ECM network gadget so the tablet is reachable over the
# USB-C cable (no display needed). Device side: 192.168.42.15/24.
# Host side: set the new adapter to 192.168.42.1/24 (see README).
set -e

G=/sys/kernel/config/usb_gadget/sheng

modprobe libcomposite 2>/dev/null || true

if [ -d "$G" ]; then
    echo "" > "$G/UDC" 2>/dev/null || true
    rm -rf "$G"
fi

mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
mkdir -p "$G/strings/0x409"
echo sheng0001           > "$G/strings/0x409/serialnumber"
echo Deepin              > "$G/strings/0x409/manufacturer"
echo "Xiaomi Pad 6S Pro" > "$G/strings/0x409/product"
mkdir -p "$G/configs/c.1/strings/0x409"
echo usbnet > "$G/configs/c.1/strings/0x409/configuration"

# Prefer RNDIS (Windows has a built-in driver); fall back to ECM (Linux/macOS).
if modprobe usb_f_rndis 2>/dev/null && mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
    ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/"
    echo "usb-gadget-net: using rndis"
else
    modprobe usb_f_ecm 2>/dev/null || true
    mkdir -p "$G/functions/ecm.usb0"
    ln -s "$G/functions/ecm.usb0" "$G/configs/c.1/"
    echo "usb-gadget-net: using ecm"
fi

UDC="$(ls /sys/class/udc 2>/dev/null | head -1)"
if [ -z "$UDC" ]; then
    echo "usb-gadget-net: no UDC available" >&2
    exit 1
fi
echo "$UDC" > "$G/UDC"

NETDEV=""
for _ in $(seq 1 10); do
    NETDEV="$(ls /sys/class/net 2>/dev/null | grep -E '^usb[0-9]' | head -1)"
    [ -n "$NETDEV" ] && break
    sleep 1
done
NETDEV="${NETDEV:-usb0}"

ip addr flush dev "$NETDEV" 2>/dev/null || true
ip addr add 192.168.42.15/24 dev "$NETDEV"
ip link set "$NETDEV" up
echo "usb-gadget-net: $NETDEV up at 192.168.42.15/24"
