#!/bin/sh
# Host: mount binderfs (so the container can bind-mount the SAME binder domain) and
# make the nodes world-accessible. (Container services run as non-root uids.)
mkdir -p /dev/binderfs
mountpoint -q /dev/binderfs || mount -t binder binderfs /dev/binderfs
chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null
ln -sf /dev/binderfs/binder /dev/binder
ln -sf /dev/binderfs/hwbinder /dev/hwbinder
ln -sf /dev/binderfs/vndbinder /dev/vndbinder
