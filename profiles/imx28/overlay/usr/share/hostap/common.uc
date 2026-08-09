// Stub for OpenWrt's netifd wireless "common" helper module (normally
// /lib/netifd/wireless/common.uc, shipped by the `mac80211` package).
// This project never installs mac80211 -- the kernel is a custom
// monolithic 6.1.70 build with no matching kmod vermagic, and wlan0 is
// managed directly via /usr/sbin/brainwrt-wifi-connect, bypassing
// netifd's wireless subsystem entirely (see the /etc/init.d/wpad stub
// for the same rationale).
//
// wpa_supplicant's own ucode control-interface integration
// (/usr/share/hostap/wpa_supplicant.uc, from wpa-supplicant-mini)
// unconditionally imports this module at startup regardless of whether
// netifd-driven wireless is actually used, producing a harmless but
// noisy "Unable to resolve path for module 'common'" log line every
// time wpa_supplicant starts. ucode resolves a bare `import ... from
// "common"` relative to the importing script's own directory, so this
// file only needs to exist alongside wpa_supplicant.uc to satisfy it
// (verified with `ucode` directly on-device).
//
// None of these functions are ever actually called in this project:
// they're only reached via the ubus RPCs (config_set/start_pending)
// that netifd would normally issue to drive real AP/mesh radio setup,
// and nothing here issues those calls. They exist purely to satisfy
// the import and silence the startup message.

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
