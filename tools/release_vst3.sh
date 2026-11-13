#!/usr/bin/env bash
# Build, test and zip a port's desktop VST3 for a release (.github/workflows/vst-release.yml, "desktop" job):
#   tools/release_vst3.sh macos|windows <port>/vst.json <skin root> <out dir>
# <skin root> holds the built skin folder ("<vendor> - VST - <name>/", from build_port.sh); macOS draws it as the editor.
# DATA (env): the engine's data folder (MODULE_SUBDIR), relative to the current folder, copied into the bundle.
# VERSION (env): the release version, used in the zip's name. macOS needs CAIRO_PREFIX or ~/cairo-macos for the editor.
# Output: <out>/<Name>-<version>-<os>-vst3.zip (the bundle and a README), and <out>/shots/page<N>.png on macOS (the editor's
# pages as drawn by the bundle, for a person to look at before publishing).
set -euo pipefail
OS="$1"; CFG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; SKINROOT="$3"; OUT="$(mkdir -p "$4" && cd "$4" && pwd)"
MV="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(python3 "$MV/tools/gen_vst.py" "$CFG" --shell)"
python3 - "$CFG" <<'PY' || { echo "::warning::vst.json has no VST3_REPLACES_VST2 define: device projects will not find this VST3" >&2; }
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])).get("defines", {}).get("VST3_REPLACES_VST2") else 1)
PY
skins=("$SKINROOT"/*/)
[ -d "${skins[0]}" ] && export VST3_SKIN="${skins[0]%/}"
if [ -n "${DATA:-}" ]; then
  [ -d "$DATA" ] || { echo "data folder $DATA not found (from $(pwd))" >&2; exit 1; }
  VST3_DATA="$(cd "$DATA" && pwd)"; export VST3_DATA
fi
export VST3_TARGET="$OS"
export CAIRO_PREFIX="${CAIRO_PREFIX:-$HOME/cairo-$OS}"   # the editor's static cairo (tools/build_cairo_<os>.sh)
mkdir -p "$OUT/shots"
LOG="$OUT/host-test.txt"
"$MV/tools/test_vst3.sh" "$CFG" --shots "$OUT/shots" 2>&1 | tee "$LOG" || true
# Blocking: the bundle must load and restore a device project (its VST2 chunk). Other host-test findings are shown, since
# some ports have known ones that don't touch the desktop build (a page selector left out of the state on purpose, say).
grep -q '^class: ' "$LOG" || { echo "::error::the VST3 did not load in the host test" >&2; exit 1; }
grep -q '^state: a VST2 chunk' "$LOG" || { echo "::error::the VST3 state test did not run" >&2; exit 1; }
grep -q '^FAIL: setState' "$LOG" && { echo "::error::setState refused a saved state" >&2; exit 1; }
! grep -qi 'samples missing\|data missing\|not found' "$LOG" || { echo "::error::the plugin did not find its data in the packaged layout" >&2; exit 1; }
grep -q '^all passed' "$LOG" || echo "::warning::the desktop VST3 host test reported: $(grep '^FAIL' "$LOG" | head -3 | tr '\n' ' ')"
! grep -q 'silent after a note' "$LOG" || echo "::warning::silent after a note: check the engine's data reached the bundle (desktop_data)"
B="$ROOT/$PORT/build/vst3/$NAME.vst3"
[ "$OS" != windows ] || B="$ROOT/$PORT/build/vst3/windows"   # single file + its folder (build_vst3.sh)
[ -d "$B" ] || { echo "no bundle at $B" >&2; exit 1; }
if [ -n "${VST3_DATA:-}" ]; then   # every data file made it into the bundle (a port that generates its data at build time)
  want=$(find "$VST3_DATA" -type f | wc -l)
  sub="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("defines", {}).get("MODULE_SUBDIR", "").strip("\""))' "$CFG")"
  got=$(find "$B" -type d -name "$sub" -exec find {} -type f \; | wc -l)
  [ "$OS" != windows ] || got=$(sed -n 's/^embedded: \([0-9]*\) files.*/\1/p' "$LOG" | tail -1)   # packed inside the .vst3
  got=${got:-0}
  echo "data: $got of $want files in the bundle"
  [ "$got" -ge "$want" ] && [ "$want" -gt 1 ] || { echo "::error::the bundle is missing engine data ($got of $want files)" >&2; exit 1; }
fi
STAGE="$(mktemp -d)"
if [ "$OS" = windows ]; then cp -R "$B"/. "$STAGE/"; else cp -R "$B" "$STAGE/"; fi
COMP="$ROOT/$PORT/build/vst3/$NAME.component"
if [ "$OS" = macos ]; then   # the Audio Unit (Logic Pro, GarageBand) goes in the same zip, checked by Apple's auval first
  [ -d "$COMP" ] || { echo "::error::no Audio Unit at $COMP" >&2; exit 1; }
  CD="$HOME/Library/Audio/Plug-Ins/Components"
  mkdir -p "$CD"; rm -rf "$CD/$NAME.component"; cp -R "$COMP" "$CD/"
  killall -9 AudioComponentRegistrar 2>/dev/null || true
  sleep 2
  read -r T S M < <(/usr/bin/python3 -c '
import plistlib,sys; c=plistlib.load(open(sys.argv[1],"rb"))["AudioComponents"][0]; print(c["type"],c["subtype"],c["manufacturer"])' "$COMP/Contents/Info.plist")
  auval -a | grep -F "$T $S $M" || echo "::warning::auval -a does not list $T $S $M yet"
  if auval -strict -v "$T" "$S" "$M" > "$OUT/auval-$NAME.log" 2>&1; then echo "auval: PASS ($T $S $M)"
  else tail -40 "$OUT/auval-$NAME.log"; echo "::error::auval failed for $NAME ($T $S $M)" >&2; exit 1; fi
  cp -R "$COMP" "$STAGE/"
fi
if [ "$OS" = macos ]; then
  cat > "$STAGE/README.txt" <<TXT
$NAME $VERSION, VST3 and Audio Unit for macOS (Apple Silicon and Intel, macOS 10.13 or later)

Install: copy $NAME.vst3 into ~/Library/Audio/Plug-Ins/VST3 (MPC Desktop and VST3 hosts) and $NAME.component into
~/Library/Audio/Plug-Ins/Components (Logic Pro, GarageBand), then rescan plugins.

It is the same instrument as the MPC VST2: a project saved on the MPC opens with it in MPC Desktop
(controller mode) with the same sound, and a project saved with it opens on the MPC.
TXT
else
  cat > "$STAGE/README.txt" <<TXT
$NAME $VERSION, VST3 for Windows (64-bit)

Install: copy $NAME.vst3 (one file, its skin and sounds inside) into C:\\Program Files\\Common Files\\VST3, then rescan
plugins in MPC Desktop or your DAW. If an earlier version left a $NAME.vst3 folder or a $NAME folder there, delete them.
On first load it unpacks its skin and sounds into %LOCALAPPDATA%\\MPC VST3\\$NAME (once per version).
The plugin window shows the same skin as on the MPC.

It is the same instrument as the MPC VST2: a project saved on the MPC opens with it in MPC Desktop with the same sound.
TXT
fi
ZIP="$OUT/$NAME-${VERSION:-dev}-$OS-vst3.zip"
ZIP="${ZIP// /-}"
rm -f "$ZIP"
NOTARIZED=""
if [ "$OS" = macos ] && [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then   # Developer ID + notarization: opens without a prompt
  codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" "$STAGE/$NAME.vst3" "$STAGE/$NAME.component"
  codesign --verify --strict --verbose=2 "$STAGE/$NAME.vst3" "$STAGE/$NAME.component"
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    N="$(mktemp -d)/notarize.zip"
    (cd "$STAGE" && ditto -c -k . "$N")
    xcrun notarytool submit "$N" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$STAGE/$NAME.vst3"; xcrun stapler staple "$STAGE/$NAME.component"
    spctl --assess --type install -vv "$STAGE/$NAME.vst3" || true
    NOTARIZED=1
    echo "notarized: $NAME.vst3"
  else
    echo "::warning::signed with $MACOS_SIGN_IDENTITY but not notarized (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD missing)"
  fi
fi
if [ "$OS" = macos ] && [ -z "$NOTARIZED" ]; then   # say how to get past Gatekeeper in the README
  cat >> "$STAGE/README.txt" <<TXT

If macOS says the plugin "can't be opened" or "can't be verified" (it isn't notarized by Apple), install it with this
Terminal command instead. It installs every plugin's latest Mac VST3 and clears the block:
  curl -fsSL https://raw.githubusercontent.com/3dthc/mpc-vst-plugins/desktop-vst3/tools/install_mac_vst3.sh | bash -s -- --all
Or, for a copy you already downloaded and installed, just:
  curl -fsSL https://raw.githubusercontent.com/3dthc/mpc-vst-plugins/desktop-vst3/tools/install_mac_vst3.sh | bash
TXT
fi
if [ "$OS" = macos ]; then
  (cd "$STAGE" && ditto -c -k --sequesterRsrc . "$ZIP")   # ditto keeps the bundle's signature intact
else
  (cd "$STAGE" && zip -qr "$ZIP" .)
fi
rm -rf "$STAGE"
echo "zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
