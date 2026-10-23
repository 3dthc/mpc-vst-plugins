#!/bin/sh
# usb_stick/enable_ssh.sh <authorized_key.pub>: lets root in over SSH with that public key. Stock sshd_config already allows
# key-based root login and forbids empty/password auth (PermitRootLogin without-password or prohibit-password,
# PasswordAuthentication no, PermitEmptyPasswords no): nothing here weakens authentication, only adds a key.
#
# Two cases, detected the same way tools/release/addin/addin-lib.sh's resolve_dropin_root() does:
#  - A writable root (or one that can be remounted rw, as on Gen1/Force): installs the key into /root/.ssh/authorized_keys
#    and enables sshd at boot. Persistent across a reboot.
#  - A true read-only root (dm-verity, e.g. Gen2's Live III; remount refused outright, not just denied): the key goes on
#    tmpfs (/run/ssh/authorized_keys) and sshd is started directly, for this boot only. Re-run (e.g. by reinserting the
#    stick) after every reboot.
set -e
KEYFILE=$1
[ -f "$KEYFILE" ] || { echo "error: no public key file: $KEYFILE" >&2; exit 1; }
KEY=$(cat "$KEYFILE")
case "$KEY" in ssh-*) ;; *) echo "error: $KEYFILE does not look like an SSH public key" >&2; exit 1 ;; esac

was_ro=0
if awk '$2 == "/" && $4 ~ /(^|,)ro(,|$)/ { f = 1 } END { exit !f }' /proc/mounts; then was_ro=1; fi

if [ $was_ro = 0 ] || mount -o remount,rw / 2>/dev/null; then
    echo "root is writable: installing the key persistently"
    install -d -m 700 /root/.ssh
    grep -qxF "$KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    # enable sshd at boot (host keys are made on first boot by sshdgenkeys.service, already stock)
    for d in /lib/systemd/system /usr/lib/systemd/system; do
        [ -f "$d/sshd.service" ] && ln -sf "$d/sshd.service" /etc/systemd/system/multi-user.target.wants/sshd.service 2>/dev/null && break
    done
    systemctl daemon-reload 2>/dev/null || true
    systemctl start sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
    sync
    [ $was_ro = 0 ] || mount -o remount,ro / 2>/dev/null || echo "warning: / is still writable; it is read-only again after a reboot" >&2
    echo "done: the key is installed and sshd starts at boot"
else
    echo "root is read-only and could not be remounted (a verity rootfs): starting sshd on demand instead, until the next reboot"
    mkdir -p /var/run/sshd /run/sshd /run/ssh
    cp "$KEYFILE" /run/ssh/authorized_keys
    chmod 600 /run/ssh/authorized_keys
    HK=""
    for k in /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_rsa_key; do
        [ -f "$k" ] || continue
        case "$(stat -c %a "$k" 2>/dev/null)" in
            600|400|640|440) HK="$HK -h $k" ;;
        esac
    done
    if [ -z "$HK" ]; then
        ssh-keygen -q -t ed25519 -f /run/ssh/hostkey -N "" && HK="-h /run/ssh/hostkey"
    fi
    [ -f /run/ssh/sshd.pid ] && kill "$(cat /run/ssh/sshd.pid 2>/dev/null)" 2>/dev/null
    # shellcheck disable=SC2086
    /usr/sbin/sshd $HK \
        -o AuthorizedKeysFile=/run/ssh/authorized_keys \
        -o PermitRootLogin=prohibit-password \
        -o PubkeyAuthentication=yes \
        -o PasswordAuthentication=no \
        -o PermitEmptyPasswords=no \
        -o PidFile=/run/ssh/sshd.pid
    echo "done: sshd is running with that key, until the next reboot (re-run this, e.g. by reinserting the stick, after one)"
fi
