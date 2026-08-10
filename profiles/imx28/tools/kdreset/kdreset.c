/* brainwrt-kdreset: /dev/tty0 を KD_TEXT モードへ戻す。
 *
 * コンソールを KD_GRAPHICS モードにするバンドルは、brainwrt-ct の cmd_down で
 * 終了できる（フレームバッファへ直接描画するバンドルは、fbcon が文字を重ねない
 * よう表示初期化で設定することが多い）。cmd_down は cgroup.kill が
 * あればそれへの書き込みを優先する。これは cgroup 内の全プロセスへ捕捉不能な
 * SIGKILL を送るため、プロセス内の SIGTERM ハンドラや終了処理は実行されず、
 * 設定したプロセスが消えても tty が KD_GRAPHICS のまま残ってしまう。
 *
 * この小さなヘルパーは cgroup の破棄後、jail 内ではなく host 側で cmd_down から
 * 無条件に呼ばれる。そのため、どのバンドルをどう停止した場合でも
 * コンソールが戻る。既に KD_TEXT のコンソールへ KD_TEXT を設定しても無害な
 * no-op なので、graphics mode に触れていないバンドルに対しても安全に呼べる。
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
