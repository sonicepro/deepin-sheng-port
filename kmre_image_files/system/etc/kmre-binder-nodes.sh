#!/system/bin/sh
# Container-side setup the kmre Android image needs on sheng (mainline kernel, no
# binderfs-uevent, and the daemon's device list is incomplete):
#  - /dev/binder etc: mount binderfs and symlink (only opens via the binderfs mount).
#  - /dev/mapper/control: vold needs device-mapper; the daemon doesn't pass it.
LOG=/data/kmre-binder-nodes.log
echo "run $(date 2>/dev/null) dev_mounted=$([ -d /dev/binderfs ] && echo yes || echo no)" >> $LOG

# --- binder ---
if [ -e /binderfs/binder ]; then
    # host binderfs bind-mounted in (via the docker wrapper) -> share the host's binder domain
    BD=/binderfs
else
    mkdir -p /dev/binderfs
    mountpoint -q /dev/binderfs || mount -t binder binderfs /dev/binderfs 2>>$LOG
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>>$LOG
    BD=/dev/binderfs
fi
ln -sf $BD/binder /dev/binder
ln -sf $BD/hwbinder /dev/hwbinder
ln -sf $BD/vndbinder /dev/vndbinder

# --- device-mapper control (vold) ---
mkdir -p /dev/mapper
[ -e /dev/mapper/control ] || mknod /dev/mapper/control c 10 236
chmod 666 /dev/mapper/control

# --- /dev/block (vold opendir's it; ueventd doesn't create it here) ---
mkdir -p /dev/block

# --- 32-bit dex2oat shim (AArch64-only SoC cannot run dex2oat32) ---
for b in dex2oat32 dex2oatd32; do
    t=/apex/com.android.art/bin/$b
    s=/apex/com.android.art/bin/${b%32}64
    if [ -e "$t" ] && [ -e "$s" ]; then
        mount --bind "$s" "$t" 2>>$LOG && echo "shimmed $b -> ${b%32}64" >> $LOG
    fi
done

# --- 32-bit app_process shim (AArch64-only SoC cannot run app_process32). Without this
#     the secondary zygote Exec-format-errors every 5s and its `onrestart restart zygote`
#     keeps killing the primary zygote before it can fork system_server. ---
if [ -e /system/bin/app_process32 ] && [ -e /system/bin/app_process64 ]; then
    mount --bind /system/bin/app_process64 /system/bin/app_process32 2>>$LOG \
        && echo "shimmed app_process32 -> app_process64" >> $LOG
fi

# --- device-encrypted user dir. vold is disabled in the container (no dm), so nothing
#     creates /data/user_de/0. installd needs it for every app's DE data, otherwise
#     system_server dies in PackageManager (SettingsProvider "Directory ... doesn't exist"). ---
mkdir -p /data/user_de/0
chown 1000:1000 /data/user_de/0 2>>$LOG
chmod 771 /data/user_de/0 2>>$LOG

# --- DRM render node. Android init remounts /dev as its own tmpfs, which hides the
#     daemon's `--device /dev/dri`. Mesa (freedreno) then fails "Failed to open any DRM
#     device" -> eglInitialize fails -> surfaceflinger aborts (and its onrestart loops the boot). ---
mkdir -p /dev/dri
[ -e /dev/dri/card0 ]     || mknod /dev/dri/card0     c 226 0
[ -e /dev/dri/renderD128 ] || mknod /dev/dri/renderD128 c 226 128
chmod 755 /dev/dri 2>>$LOG
chmod 666 /dev/dri/card0 /dev/dri/renderD128 2>>$LOG

ls -la /dev/binder /dev/hwbinder /dev/vndbinder /dev/mapper/control >> $LOG 2>&1
ls -la /dev/dri >> $LOG 2>&1
