/* brainwrt-kdreset: resets /dev/tty0 to KD_TEXT mode.
 *
 * Any bundle that puts the console into KD_GRAPHICS mode (to stop fbcon
 * from drawing text over its framebuffer output -- a bundle that draws
 * straight to the framebuffer typically does this in its own display
 * init) can be torn
 * down via brainwrt-ct's cmd_down, which prefers writing to the
 * container's cgroup.kill when present. That sends an uncatchable
 * SIGKILL to every process in the cgroup, so no in-process SIGTERM
 * handler or exit-path cleanup ever runs -- the tty is left stuck in
 * KD_GRAPHICS forever, even though the process that set it is gone.
 *
 * This tiny helper is called unconditionally from cmd_down (host side,
 * not from inside any jail) after the cgroup is torn down, so the
 * console always comes back regardless of which bundle was running or
 * how its process was stopped. Setting KD_TEXT when the console is
 * already in KD_TEXT is a harmless no-op, so this is safe to run even
 * for bundles that never touched graphics mode.
 */
#include <fcntl.h>
#include <linux/kd.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdio.h>

#define TTY_DEVICE "/dev/tty0"

int main(void) {
    int fd = open(TTY_DEVICE, O_RDWR);
    if (fd < 0) {
        perror("open " TTY_DEVICE);
        return 1;
    }
    if (ioctl(fd, KDSETMODE, KD_TEXT) != 0) {
        perror("KDSETMODE KD_TEXT");
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
