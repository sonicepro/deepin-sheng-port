/*
 * interposer.c — make the DDE polkit password dialog movable (sheng port).
 *
 * Background
 * ----------
 * On X11, dde-polkit-agent's AuthDialog::initUI() does:
 *
 *     setWindowFlags(windowFlags() | Qt::WindowStaysOnTopHint | Qt::Tool);
 *     setWindowFlag(Qt::BypassWindowManagerHint, true);
 *
 * Qt::BypassWindowManagerHint maps to override-redirect on X11: the window
 * bypasses the window manager entirely. Upstream added it to fix a
 * multi-monitor placement bug, but on the single-screen sheng tablet the only
 * effect is that the dialog is never managed by the WM, so the user cannot
 * move it (DDE moves windows through the WM's system-move request).
 *
 * What this does
 * --------------
 * LD_PRELOAD-ed into the dde-polkit-agent process, this tiny interposer
 * interposes QWidget::setWindowFlag(Qt::WindowType, bool) and drops the
 * Qt::BypassWindowManagerHint bit. The dialog then becomes an ordinary
 * WM-managed window that can be dragged. Only that single flag is touched:
 * Qt::Popup / Qt::ToolTip (combo boxes, tooltips) go override-redirect via
 * their window *type*, not this flag, so they are unaffected.
 *
 * Build
 * -----
 *     gcc -shared -fPIC -O2 -fno-stack-protector \
 *         -o libpolkitmove.so interposer.c -ldl
 * (compiled and installed by sheng-deepin-rootfs_build.sh)
 */
#include <dlfcn.h>

/* Qt::BypassWindowManagerHint == 0x00000400 (Qt 5 and Qt 6) */
#define QT_BYPASS_WINDOW_MANAGER_HINT 0x400

typedef void (*set_window_flag_fn)(void *self, int type, int on);

/* file scope => no C++ thread-safe-static guard, no libstdc++ dependency */
static set_window_flag_fn real_set_window_flag = 0;

/* QWidget::setWindowFlag(Qt::WindowType, bool) — Itanium C++ mangled name.
 * bool is passed as a 1-byte value in the low bits of the register, so an int
 * declaration is ABI-compatible here. */
void _ZN7QWidget13setWindowFlagEN2Qt10WindowTypeEb(void *self, int type, int on)
{
    if (!real_set_window_flag)
        real_set_window_flag = (set_window_flag_fn)dlsym(
            RTLD_NEXT, "_ZN7QWidget13setWindowFlagEN2Qt10WindowTypeEb");

    if (type == QT_BYPASS_WINDOW_MANAGER_HINT)
        on = 0;

    if (real_set_window_flag)
        real_set_window_flag(self, type, on);
}
