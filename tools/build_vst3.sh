#!/usr/bin/env bash
# Build a port as a VST3 plugin for a desktop DAW on this machine (Linux x86_64), from the same vst.json as the MPC build:
#   tools/build_vst3.sh path/to/vst.json [--install]
# Output: <vst.json folder>/build/vst3/<name>.vst3 (wrapper/vst3_wrap.c around the port's engine); --install copies it to
# ~/.vst3. Local use only: MPC OS loads VST2, so build_port.sh stays the device build. Uses the host gcc/g++ (no Docker).
# VST3_SAN=1 (tools/test_vst3.sh) builds with ASan/UBSan into build/vst3-san instead, unstripped.
# Every source is compiled with -DMPC_DESKTOP=1, so a port can leave out what only makes sense on a device (drawing on MPC's
# screen, say). A MODULE_SUBDIR port gets that folder, empty, next to the .so in the bundle (where the engine looks for its data:
# DrumGizmo's kits); --install keeps the files already in the installed bundle's folder.
# The editor (wrapper/vst3_editor.c: the MPC skin in the plugin window) is built in when the port's skin has been built
# (build_port.sh writes <vst.json folder>/build/skin/<vendor> - VST - <name>/, or set VST3_SKIN to a skin folder) and cairo,
# FreeType and X11 are installed (pkg-config); otherwise the plugin has no editor and a DAW shows its generic one.
# VST3_TARGET=windows cross-builds a 64-bit Windows bundle (<name>.vst3/Contents/x86_64-win/<name>.vst3) with mingw-w64
# (x86_64-w64-mingw32-gcc/g++); the engine, winpthreads and the C++ runtime are linked in statically, so the DLL stands alone.
# No editor yet on Windows (a DAW shows its generic parameter view); --install is not supported there (copy the bundle to
# %CommonProgramFiles%\VST3).
# VST3_TARGET=macos (run on a Mac, Xcode command line tools) builds a universal bundle (Apple Silicon and Intel,
# macOS 10.13+): <name>.vst3/Contents/MacOS/<name>, Info.plist, engine data (MODULE_SUBDIR) in Contents/Resources, ad-hoc
# signed. The editor (vst3_editor_mac.m, an NSView) is built in when the skin is built and CAIRO_PREFIX points at a static,
# universal cairo + pixman + FreeType + libpng + zlib (tools/build_cairo_macos.sh makes one); otherwise no editor.
# --install copies it to ~/Library/Audio/Plug-Ins/VST3.
# VST3_DATA=<folder>: copied into the bundle's data folder (MODULE_SUBDIR), so a release bundle carries its samples/banks.
set -euo pipefail
MV="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
eval "$(python3 "$MV/tools/gen_vst.py" "$CFG" --shell)"
python3 "$MV/tools/gen_vst.py" "$CFG" --params-h
ADAPTER_SRC=""
[ -n "$ADAPTER" ] && ADAPTER_SRC="$MV/adapters/$ADAPTER/${ADAPTER}_engine.c"
CC=gcc; CXX=g++; STRIP=strip; PIC="-fPIC -fvisibility=hidden"
MAC=""
read -r VENDOR UID4 VERSION < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("vendor","mpc")).replace(" ","_"), d.get("uid","none"), int(d.get("version",1000)))' "$CFG")
if [ "${VST3_TARGET:-}" = macos ]; then
  [ "$(uname -s)" = Darwin ] || { echo "VST3_TARGET=macos builds on a Mac (or a macOS GitHub runner)" >&2; exit 1; }
  MAC=1; ARCH=MacOS
  MACFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=10.13"
  CC="clang $MACFLAGS"; CXX="clang++ $MACFLAGS"; STRIP="strip -x"; PIC="-fPIC -fvisibility=hidden"
  LIBS="${LIBS//-ldl/}"; LIBS="${LIBS//-lrt/}"
elif [ "${VST3_TARGET:-}" = windows ]; then
  T=x86_64-w64-mingw32
  command -v $T-gcc >/dev/null || { echo "VST3_TARGET=windows needs mingw-w64 ($T-gcc)" >&2; exit 1; }
  [ "${2:-}" != --install ] || { echo "--install is for Linux; copy the bundle to %CommonProgramFiles%\\VST3" >&2; exit 1; }
  CC=$T-gcc; CXX=$T-g++; STRIP=$T-strip; PIC=""; ARCH=x86_64-win
  PIC="-include $MV/wrapper/win_compat.h"
else
  case "$(uname -m)" in
    x86_64) ARCH=x86_64-linux ;;
    aarch64) ARCH=aarch64-linux ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
fi
SKIN=""
[ -z "${VST3_SKIN:-}" ] || SKIN="$(cd "$VST3_SKIN" && pwd)"
cd "$ROOT"
OUTDIR="$PORT/build/vst3"
OPT="-O2 -g0 $PIC -Wall -Wextra -Wno-unused-parameter -DMPC_DESKTOP=1"
LDSAN=""
if [ -n "${VST3_SAN:-}" ]; then
  OUTDIR="$PORT/build/vst3-san"
  OPT="-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined $PIC -Wall -Wextra -Wno-unused-parameter -DMPC_DESKTOP=1"
  LDSAN="-fsanitize=address,undefined"
fi
OBJ="$OUTDIR/obj"
if [ -z "$SKIN" ]; then
  for d in "$ROOT/$PORT"/build/skin/*" - VST - $NAME"; do [ -d "$d" ] && SKIN="$d"; done
fi
EDITOR_CF=""
EDITOR_LIBS=""
if [ -z "$SKIN" ]; then
  echo "editor: none (no built skin in $PORT/build/skin; run build_port.sh, or set VST3_SKIN)"
elif [ "$ARCH" = x86_64-win ]; then
  if [ -n "${CAIRO_PREFIX:-}" ] && [ -f "$CAIRO_PREFIX/lib/libcairo.a" ]; then
    EDITOR_CF="-DVST3_EDITOR -DCAIRO_WIN32_STATIC_BUILD -I$CAIRO_PREFIX/include/cairo -I$CAIRO_PREFIX/include/freetype2 -I$CAIRO_PREFIX/include"
    EDITOR_LIBS="$CAIRO_PREFIX/lib/libcairo.a $CAIRO_PREFIX/lib/libpixman-1.a $CAIRO_PREFIX/lib/libfreetype.a"
    EDITOR_LIBS="$EDITOR_LIBS $CAIRO_PREFIX/lib/libpng16.a $CAIRO_PREFIX/lib/libz.a -ld2d1 -ldwrite -lwindowscodecs -lole32 -luuid -lgdi32 -lmsimg32 -luser32"
  else
    echo "editor: none (set CAIRO_PREFIX to a static Windows cairo: tools/build_cairo_windows.sh)"
  fi
elif [ -n "$MAC" ]; then
  if [ -n "${CAIRO_PREFIX:-}" ] && [ -f "$CAIRO_PREFIX/lib/libcairo.a" ]; then
    EDITOR_CF="-DVST3_EDITOR -I$CAIRO_PREFIX/include/cairo -I$CAIRO_PREFIX/include/freetype2 -I$CAIRO_PREFIX/include"
    EDITOR_LIBS="$CAIRO_PREFIX/lib/libcairo.a $CAIRO_PREFIX/lib/libpixman-1.a $CAIRO_PREFIX/lib/libfreetype.a"
    EDITOR_LIBS="$EDITOR_LIBS $CAIRO_PREFIX/lib/libpng16.a $CAIRO_PREFIX/lib/libz.a -framework Cocoa -framework CoreGraphics"
  else
    echo "editor: none (set CAIRO_PREFIX to a static universal cairo: tools/build_cairo_macos.sh)"
  fi
elif ! pkg-config --exists cairo freetype2 x11; then
  echo "editor: none (cairo, freetype2 and x11 development files are needed)"
else
  EDITOR_CF="-DVST3_EDITOR $(pkg-config --cflags cairo freetype2 x11)"
  EDITOR_LIBS="$(pkg-config --libs cairo freetype2 x11)"
fi
BUNDLE="$OUTDIR/$NAME.vst3"
rm -rf "$OBJ" "$BUNDLE"
mkdir -p "$OBJ" "$BUNDLE/Contents/$ARCH"
[ -z "$MAC" ] || CFLAGS="$(echo " $CFLAGS " | sed -E 's/ -m(fpu|cpu|arch|tune|float-abi)=[^ ]*//g')"   # device-only CPU flags
OBJS=""
for f in $SOURCES; do
  o="$OBJ/${f//\//_}.o"
  case "$f" in
    *.cpp|*.cc|*.cxx) $CXX $OPT -std=gnu++11 $CFLAGS -I"$MV/wrapper" -I"$PORT/build" -c "$f" -o "$o" ;;
    *) $CC $OPT -std=gnu11 $CFLAGS -I"$MV/wrapper" -I"$PORT/build" -c "$f" -o "$o" ;;
  esac
  OBJS="$OBJS $o"
done
SUBDIR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("defines", {}).get("MODULE_SUBDIR", "").strip("\""))' "$CFG")"
EMBED_CF=""
if [ "$ARCH" = x86_64-win ]; then   # one .vst3 file: the skin and the engine's data ride inside it (unpacked on first load)
  EMB="$OBJ/embed"
  rm -rf "$EMB"; mkdir -p "$EMB"
  if [ -n "$EDITOR_CF" ]; then
    python3 "$MV/tools/desktop_skin.py" "$SKIN" "$EMB/skin"
    cp "$MV"/tools/html_art/fonts/TitilliumWeb-{Regular,SemiBold,Bold}.ttf "$MV/tools/html_art/fonts/OFL.txt" "$EMB/skin/"
  fi
  if [ -n "$SUBDIR" ]; then mkdir -p "$EMB/$SUBDIR"; [ -z "${VST3_DATA:-}" ] || cp -R "$VST3_DATA"/. "$EMB/$SUBDIR"/; fi
  python3 "$MV/tools/pack_embed.py" "$EMB" "$OBJ/embed.bin"
  printf '\t.section .rdata,"dr"\n\t.balign 16\n\t.globl mpc_embed_start\nmpc_embed_start:\n\t.incbin "%s"\n\t.globl mpc_embed_end\nmpc_embed_end:\n' "$OBJ/embed.bin" > "$OBJ/embed.S"
  $CC -c "$OBJ/embed.S" -o "$OBJ/embed.o"
  OBJS="$OBJS $OBJ/embed.o"
  EMBED_CF="-DMPC_EMBED"
fi
for f in "$MV/wrapper/vst3_wrap.c" $ADAPTER_SRC; do
  o="$OBJ/$(basename "$f").o"
  $CC $OPT -std=gnu11 $EDITOR_CF $EMBED_CF -I"$MV/wrapper" -I"$PORT/build" -c "$f" -o "$o"
  OBJS="$OBJS $o"
done
VIEW_CLASS="MPCView_$(printf '%s_%s_%s' "$NAME" "$UID4" "$VERSION" | tr -c 'A-Za-z0-9_' '_')"   # per plugin and version
if [ "$ARCH" = x86_64-win ] && [ -n "$EDITOR_CF" ]; then   # the child window, its class named for this plugin and version
  $CC $OPT -std=gnu11 -DMPC_VIEW_CLASS="$VIEW_CLASS" -c "$MV/wrapper/vst3_editor_win.c" -o "$OBJ/vst3_editor_win.o"
  OBJS="$OBJS $OBJ/vst3_editor_win.o"
fi
if [ -n "$MAC" ] && [ -n "$EDITOR_CF" ]; then   # the NSView, its Objective-C class named for this plugin and version
  $CC $OPT -fno-objc-arc -DMPC_VIEW_CLASS="$VIEW_CLASS" -c "$MV/wrapper/vst3_editor_mac.m" -o "$OBJ/vst3_editor_mac.o"
  OBJS="$OBJS $OBJ/vst3_editor_mac.o"
fi
if [ -n "$MAC" ]; then   # the Audio Unit lives in the same binary and drives the VST3 (wrapper/au_wrap.m)
  AU_TAG="$(printf '%s_%s_%s' "$NAME" "$UID4" "$VERSION" | tr -c 'A-Za-z0-9_' '_')"
  $CC $OPT -fno-objc-arc -Wno-deprecated-declarations -DMPC_AU_TAG="$AU_TAG" -I"$MV/wrapper" -I"$PORT/build" -c "$MV/wrapper/au_wrap.m" -o "$OBJ/au_wrap.o"
  OBJS="$OBJS $OBJ/au_wrap.o"
  EDITOR_LIBS="$EDITOR_LIBS -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreFoundation -framework Cocoa"
  SO="$BUNDLE/Contents/MacOS/$NAME"
  WEAK="$(grep -ho '[a-z_0-9]*([^()]*) __attribute__((weak))' "$MV"/wrapper/*.h | sed -E 's/^([a-z_0-9]*)\(.*/-Wl,-U,_\1/' | sort -u | tr '\n' ' ')"
  $CXX -bundle $LDSAN $OBJS $LIBS $EDITOR_LIBS -lpthread $WEAK -o "$SO"   # -U: the engine's optional weak hooks may be absent
elif [ "$ARCH" = x86_64-win ]; then
  SO="$BUNDLE/Contents/$ARCH/$NAME.vst3"
  $CXX -shared $LDSAN $OBJS $LIBS $EDITOR_LIBS -static -lpthread -Wl,--no-undefined -o "$SO"
else
  SO="$BUNDLE/Contents/$ARCH/$NAME.so"
  $CXX -shared -fPIC $LDSAN $OBJS $LIBS $EDITOR_LIBS -lpthread -Wl,--no-undefined -o "$SO"
fi
[ -n "${VST3_SAN:-}" ] || $STRIP "$SO"
DATA="$BUNDLE/Contents/$ARCH/$SUBDIR"
[ -z "$MAC" ] || DATA="$BUNDLE/Contents/Resources/$SUBDIR"   # Contents/MacOS holds only code (signing)
if [ -n "$SUBDIR" ]; then
  mkdir -p "$DATA"
  [ -z "${VST3_DATA:-}" ] || cp -R "$VST3_DATA"/. "$DATA"/
fi
if [ -n "$EDITOR_CF" ]; then   # the skin, flattened for the editor, and its fonts (SIL OFL: the licence goes with them)
  RES="$BUNDLE/Contents/Resources/skin"
  python3 "$MV/tools/desktop_skin.py" "$SKIN" "$RES"
  cp "$MV"/tools/html_art/fonts/TitilliumWeb-{Regular,SemiBold,Bold}.ttf "$MV/tools/html_art/fonts/OFL.txt" "$RES/"
fi
if [ -n "$MAC" ]; then   # Info.plist, PkgInfo, an ad-hoc signature (Apple Silicon refuses unsigned code)
  BID="$(printf '%s' "$VENDOR.$NAME" | tr -c 'A-Za-z0-9.' '-' | tr 'A-Z' 'a-z')"
  VSTR="$(python3 -c 'v=int(__import__("sys").argv[1]); print("%d.%d.%d"%(v//1000%10,v//100%10,v%100))' "$VERSION")"
  cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.mpcvst.$BID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>$VSTR</string>
  <key>CFBundleVersion</key><string>$VSTR</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  printf 'BNDL????' > "$BUNDLE/Contents/PkgInfo"
  codesign --force --sign - "$BUNDLE"
  # <name>.component: the same bundle for Audio Unit hosts (Logic Pro, GarageBand): its own Info.plist names the AU
  COMP="$OUTDIR/$NAME.component"
  rm -rf "$COMP"; cp -R "$BUNDLE" "$COMP"; rm -rf "$COMP/Contents/_CodeSignature"
  AUTYPE=aumu; AUTAG=Synthesizer
  if grep -q '^#define PLUG_EFFECT' "$PORT/build/params.h"; then AUTYPE=aufx; AUTAG=Effects; fi
  AUMAN="$(python3 -c '
import json,re,sys
d=json.load(open(sys.argv[1])); m=d.get("au_manufacturer")
if not m:
    v=re.sub("[^A-Za-z0-9]","",str(d.get("vendor","mpc"))) or "Mpcv"
    m=(v[0].upper()+v[1:]+"xxxx")[:4]
    if not any(c.isupper() for c in m): m=m[0].upper()+m[1:]
print(m)' "$CFG")"
  AUVER="$(python3 -c 'v=int(__import__("sys").argv[1]); print((v//1000%10)<<16 | (v//100%10)<<8 | v%100)' "$VERSION")"
  AUVENDOR="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("au_vendor") or d.get("vendor","mpc"))' "$CFG")"
  AUNAME="$AUVENDOR: $NAME"   # Logic Pro lists Audio Units under the part before ":"
  cat > "$COMP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.mpcvst.au.$BID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>$VSTR</string>
  <key>CFBundleVersion</key><string>$VSTR</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>AudioComponents</key>
  <array><dict>
    <key>type</key><string>$AUTYPE</string>
    <key>subtype</key><string>$UID4</string>
    <key>manufacturer</key><string>$AUMAN</string>
    <key>name</key><string>$AUNAME</string>
    <key>description</key><string>$NAME</string>
    <key>version</key><integer>$AUVER</integer>
    <key>factoryFunction</key><string>MPCAUFactory_$AU_TAG</string>
    <key>sandboxSafe</key><true/>
    <key>tags</key><array><string>$AUTAG</string></array>
  </dict></array>
</dict>
</plist>
PLIST
  codesign --force --sign - "$COMP"
  echo "component: $ROOT/$COMP ($AUTYPE $UID4 $AUMAN)"
  echo "exported: $(nm -gU "$SO" 2>/dev/null | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  lipo -info "$SO"
elif [ "$ARCH" = x86_64-win ]; then
  echo "exported: $(x86_64-w64-mingw32-objdump -p "$SO" | awk '/Ordinal\/Name Pointer/{f=1;next} f&&NF==0{f=0} f{print $NF}' | tr '\n' ' ')"
else
  echo "exported: $(readelf --dyn-syms -W "$SO" | grep -E ' GLOBAL .* [0-9]+ [A-Za-z]' | grep -v UND | awk '{print $8}' | tr '\n' ' ')"
fi
if [ "$ARCH" = x86_64-win ]; then   # what Windows hosts scan (MPC 3 lists only single files): <name>.vst3, everything inside
  FLAT="$OUTDIR/windows"
  rm -rf "$FLAT"; mkdir -p "$FLAT"
  cp "$SO" "$FLAT/$NAME.vst3"
  echo "windows: $ROOT/$FLAT/$NAME.vst3 ($(du -h "$FLAT/$NAME.vst3" | cut -f1), skin and data inside)"
fi
echo "bundle: $ROOT/$BUNDLE"
if [ "${2:-}" = --install ] && [ -n "$MAC" ]; then
  D="$HOME/Library/Audio/Plug-Ins/VST3"
  mkdir -p "$D"
  rm -rf "$D/$NAME.vst3"
  cp -R "$BUNDLE" "$D/$NAME.vst3"
  echo "installed: $D/$NAME.vst3"
  C="$HOME/Library/Audio/Plug-Ins/Components"
  mkdir -p "$C"; rm -rf "$C/$NAME.component"; cp -R "$OUTDIR/$NAME.component" "$C/"
  killall -9 AudioComponentRegistrar 2>/dev/null || true
  echo "installed: $C/$NAME.component"
elif [ "${2:-}" = --install ]; then
  mkdir -p "$HOME/.vst3"
  rm -rf "$HOME/.vst3/$NAME.vst3.new"
  cp -r "$BUNDLE" "$HOME/.vst3/$NAME.vst3.new"
  OLD_DATA="$HOME/.vst3/$NAME.vst3/Contents/$ARCH/$SUBDIR"
  if [ -n "$SUBDIR" ] && [ -d "$OLD_DATA" ]; then   # the user's data (kits, models) moves into the new bundle
    rm -rf "$HOME/.vst3/$NAME.vst3.new/Contents/$ARCH/$SUBDIR"
    mv "$OLD_DATA" "$HOME/.vst3/$NAME.vst3.new/Contents/$ARCH/$SUBDIR"
  fi
  rm -rf "$HOME/.vst3/$NAME.vst3"
  mv "$HOME/.vst3/$NAME.vst3.new" "$HOME/.vst3/$NAME.vst3"
  echo "installed: $HOME/.vst3/$NAME.vst3"
fi
