// OpenWrt の netifd 無線用「common」ヘルパーモジュールのスタブ（通常は
// `mac80211` パッケージが提供する /lib/netifd/wireless/common.uc）。
// このプロジェクトでは mac80211 をインストールしない。カーネルは対応する kmod
// vermagic を持たない独自の monolithic 6.1.70 ビルドで、wlan0 は
// /usr/sbin/brainwrt-wifi-connect から直接管理し、netifd の無線サブシステムを
// 完全に迂回する（同じ理由は /etc/init.d/wpad のスタブも参照）。
//
// wpa-supplicant-mini の wpa_supplicant.uc（/usr/share/hostap/wpa_supplicant.uc）
// にある ucode の control-interface 統合は、netifd 無線を使うかどうかに関係なく
// 起動時にこのモジュールを無条件 import する。そのためファイルがないと
// 毎回「Unable to resolve path for module 'common'」という無害だが騒がしい
// ログが出る。ucode は裸の `import ... from "common"` を import 元スクリプトと
// 同じディレクトリから解決するため、wpa_supplicant.uc の隣にこのファイルがあれば
// よい（実機上で `ucode` を直接実行して確認済み）。
//
// このプロジェクトでは、これらの関数は実際には呼ばれない。netifd が実際の
// AP/mesh 無線設定を動かすために通常発行する ubus RPC（config_set/start_pending）
// 経由でしか到達せず、この構成からその呼び出しを発行するものはない。
// import を成立させ、起動時のログを消すためだけに存在する。

function wdev_create(name, config) { return null; }
function wdev_set_mesh_params(ifname, config) { }
function wdev_remove(ifname) { }
function is_equal(a, b) { return a == b; }
function wdev_set_up(ifname, up) { }
function vlist_new(update_cb, no_delete) {
	return { update: function(values) { } };
}
function phy_open(name, radio) { return null; }

export { wdev_create, wdev_set_mesh_params, wdev_remove, is_equal, wdev_set_up, vlist_new, phy_open };
