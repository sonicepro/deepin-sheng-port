/*
 * interposer.c — make dde-daemon see a Mains/AC supply on sheng (SM8550).
 *
 * Background
 * ----------
 * DDE shows the battery as "charging" forever even when running on battery.
 * dde-daemon's power1 module (system/power1/manager.go) derives OnBattery only
 * from a power_supply device whose sysfs `type` is exactly "mains"
 * (dde-api/powersupply.IsMains). The sheng kernel exposes only USB/Wireless
 * line-power (qcom-battmgr-usb, qcom-battmgr-wls, ucsi-source-psy) — there is
 * no Mains device, so m.ac stays nil, the one writer of OnBattery
 * (refreshAC()) never runs, and the field keeps its Go zero value `false`.
 * sysfs/UPower are correct (battery "Discharging", UPower OnBattery=true); the
 * gap is dde-daemon's narrow "mains-only" definition.
 *
 * What this does
 * --------------
 * LD_PRELOAD-ed into dde-system-daemon, this interposer hooks two libgudev C
 * functions (which dde calls through cgo, so they are interposable):
 *   - g_udev_device_get_sysfs_attr(dev, "type")  -> "mains" for the USB port,
 *     so powersupply.IsMains() accepts it as the AC adapter;
 *   - g_udev_device_get_property_as_boolean(dev, "POWER_SUPPLY_ONLINE") for that
 *     device -> whether the battery is actually charging (read from the real
 *     battery status), so refreshAC() computes a correct OnBattery.
 *
 * Build
 * -----
 *     gcc -shared -fPIC -O2 -fno-stack-protector -o libdde-power-ac.so interposer.c -ldl
 * (compiled and installed by sheng-deepin-rootfs_build.sh)
 */
#include <dlfcn.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

/* The USB line-power port to present as the "AC" supply (kernel device name). */
#define TARGET_DEV "qcom-battmgr-usb"
/* Real battery status file; ground truth for plugged/unplugged. */
#define BAT_STATUS "/sys/class/power_supply/qcom-battmgr-bat/status"

typedef const char *(*get_sysfs_attr_fn)(void *, const char *);
typedef const char *(*get_sysfs_path_fn)(void *);
typedef int (*get_prop_bool_fn)(void *, const char *);

static get_sysfs_attr_fn real_get_sysfs_attr = 0;
static get_sysfs_path_fn real_get_sysfs_path = 0;
static get_prop_bool_fn real_get_prop_bool = 0;

static int battery_charging(void)
{
    char buf[32];
    int fd = open(BAT_STATUS, O_RDONLY);
    if (fd < 0)
        return 0;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return 0;
    buf[n] = '\0';
    return strncmp(buf, "Charging", 8) == 0 || strncmp(buf, "Full", 4) == 0;
}

static int is_target(void *dev)
{
    if (!real_get_sysfs_path)
        return 0;
    const char *p = real_get_sysfs_path(dev);
    return p && strstr(p, TARGET_DEV) != 0;
}

/* powersupply.IsMains() -> dev.GetSysfsAttr("type") */
const char *g_udev_device_get_sysfs_attr(void *dev, const char *name)
{
    if (!real_get_sysfs_attr)
        real_get_sysfs_attr = (get_sysfs_attr_fn)dlsym(RTLD_NEXT, "g_udev_device_get_sysfs_attr");
    if (!real_get_sysfs_path)
        real_get_sysfs_path = (get_sysfs_path_fn)dlsym(RTLD_NEXT, "g_udev_device_get_sysfs_path");

    if (name && strcmp(name, "type") == 0 && is_target(dev))
        return "mains";
    return real_get_sysfs_attr ? real_get_sysfs_attr(dev, name) : 0;
}

/* refreshAC() -> ac.GetPropertyAsBoolean("POWER_SUPPLY_ONLINE") */
int g_udev_device_get_property_as_boolean(void *dev, const char *name)
{
    if (!real_get_prop_bool)
        real_get_prop_bool = (get_prop_bool_fn)dlsym(RTLD_NEXT, "g_udev_device_get_property_as_boolean");
    if (!real_get_sysfs_path)
        real_get_sysfs_path = (get_sysfs_path_fn)dlsym(RTLD_NEXT, "g_udev_device_get_sysfs_path");

    if (name && strcmp(name, "POWER_SUPPLY_ONLINE") == 0 && is_target(dev))
        return battery_charging() || (real_get_prop_bool ? real_get_prop_bool(dev, name) : 0);
    return real_get_prop_bool ? real_get_prop_bool(dev, name) : 0;
}
