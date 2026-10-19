# Install from a USB stick, no SSH (offline-built; Force probe 2026-10-13)

Status (2026-10-13): **works end to end on a Force (stock 3.9.1.2 with addins), one run; nothing else tested.** Stick made by `make_stick.py` from the stock Force 3.9.1 MPC, FAT32 stick: the stock prompt appeared, Install ran `open.sh` as root, `mpc-store.sh` downloaded `plugin-manager` 1.2.0 (hash-checked), stopped MPC, installed it, wrote the plugin-list entry (47 entries, `MPC.settings.bak-*` kept) and started MPC again; the whole run took 5 seconds and wrote `mpc-install-result.txt` and `MPC.settings.backup` to the stick. Then the user opened Plugin Manager on a track and reported it works (not examined further by us). The user then loaded Plugin Manager on a track and reported it works (user-reported). Not yet seen: other devices or firmware, a stick made from a Gen1 image, offline use. Not released and not in the installer app.

## How the route works

MPC OS 3.9.1 (Gen1 and Force) has a stock "USB script" reader. A stick with `autorun/autorun.json`, `autorun/autorun.check` and the
files the JSON lists makes MPC ask, then run `autorun/open.sh` as root (the journal shows `az01-script-runner` running it). It is not an
exploit, and not described in Akai's guide. Credit for finding it and working out the check: **Eurikon**
(<https://github.com/Eurikon/plugin-manager-usb>, MIT, tested on a Live II Retro, 3.9.1), whose own manager uses the same route.

`autorun.check` is `sha256(autorun.json + open.sh + each listed file in the listed order + salt)` as hex text. The salt is 37 bytes
kept XOR-obfuscated in the MPC executable (an 8-byte key, repeated), padded with zeros. The same salt value is in the stock Gen1 3.9.1
MPC, the stock Force 3.9.1 MPC and a Force at 3.9.1.2 (offline scan, 2026-10-13); only its position differs, and it appears twice.

## What is in this repo

- `tools/usb_stick/saltscan.py`: finds the salt by scanning a firmware file (a raw MPC executable, or an update image whose root
  filesystems are xz streams) instead of reading a fixed offset. A genuine salt is shorter than the 37-byte reserved field (zero
  padding); a candidate that fills the whole field with printable bytes is dropped as noise if a padded one is also found (needed on
  the Gen2 aarch64 rootfs, which has several such false positives — 2026-10-20). Refuses when there is no candidate or two different
  *padded* values.
- `tools/usb_stick/make_stick.py`: `--firmware <update.img | MPC> --out <folder> [--install id,id]`. Writes the stick folder.
- `tools/usb_stick/open.sh` + `run.sh`: on the device. `open.sh` copies the runtime to RAM and starts `run.sh` as a systemd unit;
  `run.sh` copies `MPC.settings` to the stick, then runs the bundled `mpc-store.sh -y install <ids>` (default `plugin-manager`; ids from
  `install.txt` on the stick) and writes `mpc-install-result.txt`. `mpc-store.sh` stops MPC once, starts it once, and starts it again on
  failure. It does not touch `LD_PRELOAD`, so addins keep working.
- `tools/test_usb_stick.py`, CI in `.github/workflows/usb-stick.yml`: made-up salt; the real one is never stored.

## Rules

- The salt is Akai-derived: it is read from the user's own firmware when the stick is made, and is never committed, logged or put in a
  release. Do not publish a ready-made stick.
- Anything on the stick that the check covers (`autorun.json`, `open.sh`, `runtime/*`) is fixed once the check is made; `install.txt`
  sits outside it on purpose, so the plugin list can be edited.
- The plugin manager is `plugin-manager` from the catalog (a VST app listing the catalog on the MPC screen).

## Not known yet

- Not run end to end on a device. First run: back up `MPC.settings`, save the session, ask before the restart.
- Needs internet on the device for the catalog. An offline stick (bundled zips) is not built.
- Gen2: the salt (identical value to Gen1/Force) is confirmed offline in the stock `MPC-3.9.1-Gen2-update.img`, and the autorun
  route itself is community-reported to work on a real Gen2 device (2026-10-20) — but no Gen2 run of this project's stick. Other
  MPC OS versions and Key/X/One: the salt scheme and the reader are still unchecked.
- Akai can change or close the route in an update. The scripts run as root; keep the stick's contents to what the catalog installs.
- Turning an update image into a stick takes about a minute on a laptop (the root filesystem is scanned).
