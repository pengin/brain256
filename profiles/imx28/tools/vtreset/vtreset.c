/* brainwrt-vtreset: アクティブな VT を切り替える。
 *
 * 物理キーボード／ディスプレイを専用 VT へ切り替えるバンドルは、brainwrt-ct の
 * cmd_down で終了できる。全画面 TUI バンドルは、コンソールを占有して tty1 の
 * 対話ログインシェルとキーボード入力が競合しないよう、通常 /dev/tty2 をアクティブ
 * にする。/dev/console と /dev/tty0 は「現在アクティブな VT」
 * の別名であり、既存の tty1 の login/ash セッションは controlling terminal
 * なしに /dev/console を open しているため、TIOCSCTTY だけでは追い出せない。
 * cmd_down は cgroup.kill があればそこへの書き込みを優先し、cgroup 内の全
 * プロセスへ捕捉不能な SIGKILL を送るので、アクティブ VT を戻す終了処理も
 * 実行されない。
 *
 * 引数を明示すると、その VT へ決定的に切り替える。cmd_down は cgroup 破棄後、
 * jail 内ではなく host 側で常に `brainwrt-vtreset 1` を呼ぶため、どのバンドルを
 * どう停止した場合でも、物理コンソールは procd の askconsole
 * login セッションがある tty1 へ戻る。その時点で tty1 が既にアクティブでも
 * 無害な no-op なので、VT を切り替えていないバンドルに対しても安全に呼べる。
 *
 * 引数なしでは、VT_GETSTATE で現在の VT を確認して tty1 と tty2 を *toggle* する。
 * これは TUI バンドルの「suspend」キー（実際に suspend 先となる job control
 * supervisor がないときに tty2 から離れる）と、tty1 のシェルからの
 * 戻しを想定したもの。どちら側からも VT 番号を覚えずに同じコマンドを使える。
 * 現在の VT がそれ以外なら、推測せず安全側として tty1 へ切り替える。
 *
 * ioctl 用に開くデバイスを /dev/tty0 ではなく /dev/tty2 としているのは意図的で
 * ある。cmd_down（bare host、全 VT デバイスにアクセス可能）と neovim バンドル
 * 自身の jail（ct.devices で /dev/tty2 だけを渡す。manifest に追加したのが
 * /dev/tty2 だけなので /dev/tty0 はない）の両方で同じバイナリを使えるようにする
 * ためである。VT_ACTIVATE/VT_WAITACTIVE/VT_GETSTATE は VT サブシステム全体に
 * 対する操作で、どの VT を指す fd でも発行できるため、両方の呼び出し元で動く。
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
