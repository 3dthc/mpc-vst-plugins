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
[ "$OS" != macos ] || export CAIRO_PREFIX="${CAIRO_PREFIX:-$HOME/cairo-macos}"
mkdir -p "$OUT/shots"
LOG="$OUT/host-test.txt"
if [ "$OS" = macos ]; then
  "$MV/tools/test_vst3.sh" "$CFG" --shots "$OUT/shots" 2>&1 | tee "$LOG" || true
else
  "$MV/tools/test_vst3.sh" "$CFG" 2>&1 | tee "$LOG" || true
fi
# Blocking: the bundle must load and restore a device project (its VST2 chunk). Other host-test findings are shown, since
# some ports have known ones that don't touch the desktop build (a page selector left out of the state on purpose, say).
grep -q '^class: ' "$LOG" || { echo "::error::the VST3 did not load in the host test" >&2; exit 1; }
grep -q '^state: a VST2 chunk' "$LOG" || { echo "::error::the VST3 state test did not run" >&2; exit 1; }
grep -q '^FAIL: setState' "$LOG" && { echo "::error::setState refused a saved state" >&2; exit 1; }
grep -q '^all passed' "$LOG" || echo "::warning::the desktop VST3 host test reported: $(grep '^FAIL' "$LOG" | head -3 | tr '\n' ' ')"
! grep -q 'silent after a note' "$LOG" || echo "::warning::silent after a note: check the engine's data reached the bundle (desktop_data)"
B="$ROOT/$PORT/build/vst3/$NAME.vst3"
[ -d "$B" ] || { echo "no bundle at $B" >&2; exit 1; }
STAGE="$(mktemp -d)"
cp -R "$B" "$STAGE/"
if [ "$OS" = macos ]; then
  cat > "$STAGE/README.txt" <<TXT
$NAME $VERSION, VST3 for macOS (Apple Silicon and Intel, macOS 10.13 or later)

Install: copy $NAME.vst3 into /Library/Audio/Plug-Ins/VST3 (all users) or ~/Library/Audio/Plug-Ins/VST3 (just you),
then rescan plugins in MPC Desktop (Preferences > Plugins) or your DAW.

The plugin is not notarized. If macOS says it "can't be opened" or the host skips it, run once in Terminal:
  xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/VST3/$NAME.vst3
(or the /Library path, with sudo).

It is the same instrument as the MPC VST2: a project saved on the MPC opens with it in MPC Desktop
(controller mode) with the same sound, and a project saved with it opens on the MPC.
TXT
else
  cat > "$STAGE/README.txt" <<TXT
$NAME $VERSION, VST3 for Windows (64-bit)

Install: copy the $NAME.vst3 folder into C:\\Program Files\\Common Files\\VST3, then rescan plugins in MPC Desktop or
your DAW. No editor window yet on Windows: the host shows the plugin's parameters.

It is the same instrument as the MPC VST2: a project saved on the MPC opens with it in MPC Desktop with the same sound.
TXT
fi
ZIP="$OUT/$NAME-${VERSION:-dev}-$OS-vst3.zip"
ZIP="${ZIP// /-}"
rm -f "$ZIP"
if [ "$OS" = macos ]; then
  (cd "$STAGE" && ditto -c -k --sequesterRsrc . "$ZIP")   # ditto keeps the bundle's signature intact
else
  (cd "$STAGE" && zip -qr "$ZIP" .)
fi
rm -rf "$STAGE"
echo "zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
