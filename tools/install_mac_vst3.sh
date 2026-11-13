#!/bin/bash
# Install or unblock MPC desktop VST3s and Audio Units on a Mac, without the "can't be verified / free of malware" block.
#
# macOS blocks a plugin that was downloaded in a browser (it gets a "quarantine" flag) and isn't notarized by Apple.
# A file fetched with curl gets no such flag, and this script also clears it from any copy you already downloaded.
#
#   Unblock what is already installed (and any .vst3 or .zip in ~/Downloads):
#     curl -fsSL https://raw.githubusercontent.com/3dthc/mpc-vst-plugins/desktop-vst3-openmpc/tools/install_mac_vst3.sh | bash
#   Download and install the latest published VST3 of every plugin (or name some: ... | bash -s -- Fretty Sonix):
#     curl -fsSL https://raw.githubusercontent.com/3dthc/mpc-vst-plugins/desktop-vst3-openmpc/tools/install_mac_vst3.sh | bash -s -- --all
#
# Installs into ~/Library/Audio/Plug-Ins/VST3 and .../Components (no password needed). Rescan plugins afterwards.
set -euo pipefail
DEST="$HOME/Library/Audio/Plug-Ins/VST3"
CDEST="$HOME/Library/Audio/Plug-Ins/Components"
REPOS="3dthc/OB-XD-MPC 3dthc/Odin2-MPC 3dthc/Sonix 3dthc/Tropix 3dthc/OxZygen 3dthc/fretty-mpc 3dthc/Tuney-MPC 3dthc/Shapey-MPC 3dthc/Nova-Editor"
mkdir -p "$DEST" "$CDEST"

unblock() {   # clear the quarantine flag and re-sign ad hoc (Apple Silicon needs a valid signature)
  local b="$1"
  xattr -dr com.apple.quarantine "$b" 2>/dev/null || true
  codesign --force --sign - "$b" >/dev/null 2>&1 || true
  echo "  ready: $(basename "$b")"
}

install_zip() {   # a <Name>-<version>-macos-vst3.zip: unpack, replace the old copy, unblock
  local zip="$1" tmp
  tmp="$(mktemp -d)"
  xattr -d com.apple.quarantine "$zip" 2>/dev/null || true
  ditto -x -k "$zip" "$tmp"
  for b in "$tmp"/*.vst3; do
    [ -d "$b" ] || continue
    rm -rf "$DEST/$(basename "$b")"
    ditto "$b" "$DEST/$(basename "$b")"
    unblock "$DEST/$(basename "$b")"
  done
  for b in "$tmp"/*.component; do   # the Audio Unit, for Logic Pro and GarageBand
    [ -d "$b" ] || continue
    rm -rf "$CDEST/$(basename "$b")"
    ditto "$b" "$CDEST/$(basename "$b")"
    unblock "$CDEST/$(basename "$b")"
  done
  killall -9 AudioComponentRegistrar 2>/dev/null || true
  rm -rf "$tmp"
}

if [ "${1:-}" = "" ]; then
  echo "Unblocking installed plugins in $DEST and /Library/Audio/Plug-Ins/VST3:"
  for b in "$DEST"/*.vst3 /Library/Audio/Plug-Ins/VST3/*.vst3 "$CDEST"/*.component; do
    [ -d "$b" ] || continue
    if [ -w "$b" ]; then unblock "$b"; else echo "  $(basename "$b") is in /Library: run with sudo, or move it to $DEST"; fi
  done
  shopt -s nullglob
  for z in "$HOME"/Downloads/*-macos-vst3.zip "$HOME"/Downloads/*-macos-au.zip; do echo "Installing $(basename "$z"):"; install_zip "$z"; done
  echo "Done. Rescan plugins in MPC Desktop, or restart Logic Pro (it checks new Audio Units on launch)."
  exit 0
fi

WANT=""
[ "$1" = --all ] || WANT=" $* "
for repo in $REPOS; do
  json="$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=20")" || { echo "  $repo: can't reach GitHub"; continue; }
  # the newest published release of each plugin in the repo that has a macOS VST3 zip
  urls="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
seen = set()
for r in json.load(sys.stdin):
    if r.get("draft"): continue
    for a in r.get("assets", []):
        n = a["name"]
        if n.endswith("-macos-vst3.zip") or n.endswith("-macos-au.zip"):
            plug = n.rsplit("-", 3)[0]
            if (plug, n[-8:]) not in seen:
                seen.add((plug, n[-8:])); print(plug + " " + a["browser_download_url"])
')"
  [ -n "$urls" ] || continue
  while read -r plug url; do
    [ -z "$WANT" ] || case "$WANT" in *" $plug "*|*" ${plug//-/ } "*) ;; *) continue ;; esac
    echo "Installing $plug:"
    z="$(mktemp -d)/$plug.zip"
    curl -fsSL -o "$z" "$url"
    install_zip "$z"
  done <<< "$urls"
done
echo "Done. Rescan plugins in MPC Desktop, or restart Logic Pro (it checks new Audio Units on launch)."
