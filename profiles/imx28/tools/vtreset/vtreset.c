/* brainwrt-vtreset: switches the active VT.
 *
 * Any bundle that switches the physical keyboard/display over to a
 * dedicated VT (a full-screen TUI bundle typically activates
 * /dev/tty2 so its own console-takeover doesn't race the interactive
 * login shell on tty1 for keyboard input -- both /dev/console and
 * /dev/tty0 alias to "whichever VT is currently active", and the
 * pre-existing login/ash session on tty1 holds /dev/console open
 * without a controlling terminal at all, so it can't be dislodged by
 * TIOCSCTTY alone) can be torn down via brainwrt-ct's cmd_down, which
 * prefers writing to the container's cgroup.kill when present. That
 * sends an uncatchable SIGKILL to every process in the cgroup, so no
 * in-process cleanup (including switching the active VT back) ever
 * runs.
 *
 * With an explicit argument, this switches to that VT deterministically
 * -- cmd_down always calls `brainwrt-vtreset 1` explicitly (host side,
 * not from inside any jail) after the cgroup is torn down, so the
 * physical console always returns to tty1 (where procd's askconsole
 * login session lives) regardless of which bundle was running or how
 * its process was stopped, or what VT happens to be active at that
 * moment. Switching to tty1 when tty1 is already active is a harmless
 * no-op, so this is safe to run even for bundles that never touched VT
 * switching.
 *
 * With NO argument, this instead *toggles* between tty1 and tty2 based
 * on whichever is currently active (VT_GETSTATE) -- meant for a TUI
 * bundle to bind to a "suspend" key (switching away from tty2 when the
 * bundle has no real job-control supervisor to suspend to) and,
 * symmetrically, for the
 * shell on tty1 to switch back: the same no-argument command works
 * from either side without needing to remember which VT number to
 * pass. Any *other* currently-active VT toggles to tty1 (a safe
 * default rather than guessing).
 *
 * The device this opens to issue the ioctls (/dev/tty2, not /dev/tty0)
 * is deliberately chosen so this same binary works both from cmd_down
 * (bare host, every VT device is accessible) and from *inside* the
 * neovim bundle's own jail (where only /dev/tty2 is staged via
 * ct.devices -- /dev/tty0 is not, since only /dev/tty2 was ever added
 * to the manifest). VT_ACTIVATE/VT_WAITACTIVE/VT_GETSTATE are global
 * VT-subsystem operations, issuable via any currently-open VT device
 * fd regardless of which specific VT it refers to, so this works for
 * both callers.
 */
#include <fcntl.h>
#include <linux/vt.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

#define TTY_DEVICE "/dev/tty2"
#define VT_A 1
#define VT_B 2

static int toggle_target(int fd) {
    struct vt_stat state;
    if (ioctl(fd, VT_GETSTATE, &state) != 0) {
        perror("VT_GETSTATE");
        return -1;
    }
    return (state.v_active == VT_A) ? VT_B : VT_A;
}

int main(int argc, char *argv[]) {
    int fd = open(TTY_DEVICE, O_RDWR);
    if (fd < 0) {
        perror("open " TTY_DEVICE);
        return 1;
    }

    int target_vt;
    if (argc > 1) {
        target_vt = atoi(argv[1]);
        if (target_vt <= 0) {
            fprintf(stderr, "usage: %s [vt-number]\n", argv[0]);
            close(fd);
            return 1;
        }
    } else {
        target_vt = toggle_target(fd);
        if (target_vt < 0) {
            close(fd);
            return 1;
        }
    }

    if (ioctl(fd, VT_ACTIVATE, target_vt) != 0) {
        perror("VT_ACTIVATE");
        close(fd);
        return 1;
    }
    if (ioctl(fd, VT_WAITACTIVE, target_vt) != 0) {
        perror("VT_WAITACTIVE");
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
