#!/usr/bin/env python3
"""Write a USB stick folder that installs catalog plugins on an MPC/Force with no SSH, using MPC OS's own USB-script prompt.

  python3 tools/usb_stick/make_stick.py --firmware <update.img | MPC executable> --out <folder> [--install plugin-manager,...]
                                         [--ssh-key <path to a .pub file>]

Copy the folder's contents to the root of a FAT32/exFAT USB stick (hidden files too), insert it, confirm the prompt on the device.
--firmware is the user's own Akai update image (or the usr/bin/MPC from it): its salt is read here and never stored in this repo.
--ssh-key, if given, also enables SSH for that public key (tools/usb_stick/enable_ssh.sh: persistently where root is writable,
on demand until the next reboot on a verity rootfs). The private key never goes near this tool.
Background and limits: docs/USB_STICK.md.
"""
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import saltscan  # noqa: E402

PROMPT = ("MPC PLUGIN INSTALLER\n\nThis installs the plugins listed in install.txt "
          "(the plugin manager by default) and restarts MPC.\n\nHave you saved your project?")


def autorun_check(autorun, files, salt):
    """What the stock reader recomputes: sha256 of autorun.json, open.sh, then each listed file in order, then the salt."""
    data = b"".join((autorun / n).read_bytes() for n in ["autorun.json", "open.sh"] + files)
    return hashlib.sha256(data + salt).hexdigest().encode()


def build(out, salt, store, install, ssh_key=None):
    out = Path(out)
    if out.exists():
        raise FileExistsError(f"{out} already exists")
    autorun = out / "autorun"
    runtime = autorun / "runtime"
    runtime.mkdir(parents=True)
    shutil.copyfile(HERE / "open.sh", autorun / "open.sh")
    shutil.copyfile(HERE / "run.sh", runtime / "run.sh")
    shutil.copyfile(store, runtime / "mpc-store.sh")
    if ssh_key:
        shutil.copyfile(HERE / "enable_ssh.sh", runtime / "enable_ssh.sh")
        shutil.copyfile(ssh_key, runtime / "authorized_key.pub")
    files = sorted(str(p.relative_to(autorun)) for p in runtime.rglob("*") if p.is_file())
    manifest = {"value0": {"files": files, "scripts": [{
        "path": "open.sh", "askQuestion": True, "message": PROMPT,
        "yesButtonText": "Install", "noButtonText": "Cancel"}]}}
    (autorun / "autorun.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (autorun / "autorun.check").write_bytes(autorun_check(autorun, files, salt))
    ids = [i for i in (install or ["plugin-manager"])]
    (out / "install.txt").write_text("# one catalog plugin id per line; edit before inserting the stick\n" + "\n".join(ids) + "\n")
    ssh_note = ("\nSSH is also enabled for the public key you gave: persistently if the device's root can be made writable, "
                "otherwise (a verity rootfs) until the next reboot -- reinsert the stick to redo it.\n") if ssh_key else ""
    (out / "README-USB.txt").write_text(
        "Copy everything in this folder (hidden files too) to the root of a USB stick, insert it into the MPC/Force, and confirm\n"
        "the prompt. Needs internet on the device. The result is written to mpc-install-result.txt on the stick, and a copy of\n"
        "MPC.settings to MPC.settings.backup. Save your project first: MPC restarts.\n" + ssh_note)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--firmware", required=True, help="the user's Akai update image, or the MPC executable")
    ap.add_argument("--out", required=True)
    ap.add_argument("--install", default="plugin-manager", help="comma-separated catalog ids")
    ap.add_argument("--store", default=str(HERE.parent / "mpc-store.sh"))
    ap.add_argument("--ssh-key", help="a public key file (e.g. ~/.ssh/id_ed25519.pub) to also enable SSH for")
    a = ap.parse_args(argv)
    try:
        salt, hits = saltscan.find_salt(a.firmware)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    ids = [i.strip() for i in a.install.split(",") if i.strip()]
    build(a.out, salt, a.store, ids, a.ssh_key)
    print(f"Wrote {a.out} (salt found {len(hits)}x in {a.firmware}). Copy its contents, hidden files included, to the stick's root.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
