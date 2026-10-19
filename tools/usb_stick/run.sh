#!/bin/sh
# usb_stick/run.sh <stick> <work>: installs the catalog plugins named in <stick>/install.txt (default: plugin-manager) with
# mpc-store.sh, which stops MPC once, starts it once, and starts it again if anything fails. Leaves <stick>/mpc-install-result.txt.
usb=$1; work=$2
log="$work/result.txt"
finish() {
    r=$?
    cp "$log" "$usb/mpc-install-result.txt" 2>/dev/null || true
    rm -rf "$work"
    exit "$r"
}
trap finish EXIT
exec > "$log" 2>&1
echo "MPC USB install: $(date '+%Y-%m-%d %H:%M:%S')"
if [ -z "${MPC_USB_TEST:-}" ]; then [ "$(id -u)" = 0 ] || { echo "error: not root"; exit 1; }; fi
ids=""
if [ -f "$usb/install.txt" ]; then
    ids=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$usb/install.txt" | grep -E '^[a-z0-9][a-z0-9._-]*$' | tr '\n' ' ')
fi
[ -n "$ids" ] || ids="plugin-manager"
echo "Installing: $ids"
settings="${MPC_SETTINGS:-$(ls /media/az01-internal/Settings/*/MPC.settings /data/Settings/*/MPC.settings 2>/dev/null | head -n 1)}"
if [ -f "$settings" ]; then
    cp "$settings" "$usb/MPC.settings.backup" 2>/dev/null && echo "MPC.settings copied to the stick (MPC.settings.backup)"
fi
# shellcheck disable=SC2086
sh "$work/mpc-store.sh" -y install $ids
rc=$?
if [ "$rc" -eq 0 ]; then echo "Done."; else echo "Install failed (status $rc); MPC was started again."; fi
exit "$rc"
