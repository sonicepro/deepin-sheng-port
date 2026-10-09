/*
 * sheng-osk-gate.so — gate fcitx5's on-screen keyboard behind "a text field is
 * focused", and swallow the automatic pop.
 *
 * fcitx5 asks its UI to show the keyboard when a *text field* gains focus
 * (InputContext::showVirtualKeyboard) and to hide it when it loses focus
 * (InputContext::hideVirtualKeyboard). We track that as a flag:
 *   show  -> $XDG_RUNTIME_DIR/sheng-osk-textactive = 1   (and DO NOT pop)
 *   hide  -> $XDG_RUNTIME_DIR/sheng-osk-textactive = 0   (forward to real hide)
 *
 * The companion daemon (sheng-osk-tap.py) opens the keyboard only on a
 * DOUBLE-tap AND only when that flag is 1 — so a double-tap on a folder (no
 * text field focused -> flag 0) does nothing, while a double-tap on an input
 * does. The automatic pop is never shown.
 *
 * Verified: libFcitx5Core.so.5.1.19 exports both; called via @plt.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *rt_dir(void) {
    const char *rt = getenv("XDG_RUNTIME_DIR");
    return (rt && rt[0]) ? rt : "/tmp";
}

static void append_log(const char *msg) {
    char p[512];
    snprintf(p, sizeof p, "%s/sheng-osk-req.log", rt_dir());
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    char b[160];
    int n = snprintf(b, sizeof b, "%.3f %s\n",
                     (double)t.tv_sec + (double)t.tv_nsec / 1e9, msg);
    if (n > 0) { ssize_t r = write(fd, b, (size_t)n); (void)r; }
    close(fd);
}

static void set_flag(const char *v) {
    char p[512];
    snprintf(p, sizeof p, "%s/sheng-osk-textactive", rt_dir());
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t r = write(fd, v, strlen(v));
    (void)r;
    close(fd);
}

/* a text field asked for the keyboard -> mark text-active, DO NOT pop */
void _ZNK5fcitx20UserInterfaceManager19showVirtualKeyboardEv(void *self) {
    (void)self;
    set_flag("1\n");
    append_log("show -> text-active=1 (auto-pop suppressed)");
}

/* a text field lost focus -> clear text-active, and let the real hide run */
void _ZNK5fcitx20UserInterfaceManager19hideVirtualKeyboardEv(void *self) {
    set_flag("0\n");
    append_log("hide -> text-active=0");
    static void (*real)(void *) = 0;
    if (!real) {
        real = (void (*)(void *))
            dlsym(RTLD_NEXT, "_ZNK5fcitx20UserInterfaceManager19hideVirtualKeyboardEv");
    }
    if (real) real(self);
}
