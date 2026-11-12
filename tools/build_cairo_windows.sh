#!/usr/bin/env bash
# Build a static 64-bit Windows cairo for the Windows VST3 editor (tools/build_vst3.sh, VST3_TARGET=windows), cross-compiled
# on Linux with mingw-w64:   tools/build_cairo_windows.sh <prefix>
# Output: <prefix>/lib/{libcairo,libpixman-1,libfreetype,libpng16,libz}.a and <prefix>/include/... Same cairo release and
# backends as tools/build_cairo_macos.sh (image, PNG, FreeType; cairo adds its Win32 surface, which needs gdi32 and
# msimg32), so the page draws the same on every desktop. Needs mingw-w64, python3 and network access.
set -euo pipefail
PREFIX="$(mkdir -p "$1" && cd "$1" && pwd)"
CAIRO_VERSION=1.18.4
CAIRO_SHA256=445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb
WORK="${CAIRO_WORK:-$(mktemp -d)}"
T=x86_64-w64-mingw32
if ! command -v meson >/dev/null || ! command -v ninja >/dev/null; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet meson ninja
  export PATH="$WORK/venv/bin:$PATH"
fi
cd "$WORK"
if [ ! -d "cairo-$CAIRO_VERSION" ]; then
  curl -fsSL -o cairo.tar.xz "https://cairographics.org/releases/cairo-$CAIRO_VERSION.tar.xz"
  echo "$CAIRO_SHA256  cairo.tar.xz" | sha256sum -c -
  tar xf cairo.tar.xz
fi
cat > cross-win64.ini <<INI
[binaries]
c = '$T-gcc'
cpp = '$T-g++'
ar = '$T-ar'
strip = '$T-strip'
windres = '$T-windres'
pkg-config = 'false'
[built-in options]
c_args = ['-O2']
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
INI
rm -rf build-win64 inst-win64
meson setup build-win64 "cairo-$CAIRO_VERSION" --cross-file cross-win64.ini --prefix "$WORK/inst-win64" \
  --buildtype=release --default-library=static --wrap-mode=nofallback \
  --force-fallback-for=zlib,libpng,freetype2,pixman-1,pixman -Db_ndebug=true \
  -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled -Dfontconfig=disabled -Dquartz=disabled -Dxlib=disabled \
  -Dxcb=disabled -Dglib=disabled -Dspectre=disabled -Dsymbol-lookup=disabled -Dtests=disabled -Dgtk_doc=false \
  -Dlzo=disabled -Dgtk2-utils=disabled \
  -Dpixman:tests=disabled -Dpixman:demos=disabled -Dpixman:gtk=disabled -Dpixman:libpng=disabled \
  -Dfreetype2:png=disabled -Dfreetype2:bzip2=disabled -Dfreetype2:brotli=disabled -Dfreetype2:harfbuzz=disabled \
  -Dfreetype2:zlib=internal
meson compile -C build-win64
meson install -C build-win64 --quiet
mkdir -p "$PREFIX/lib" "$PREFIX/include"
for lib in libcairo libpixman-1 libfreetype libpng16 libz; do
  a="$(cd inst-win64 && find . -name "$lib.a" | head -1)"
  [ -n "$a" ] || { echo "missing $lib.a" >&2; exit 1; }
  cp "inst-win64/$a" "$PREFIX/lib/$lib.a"
done
cp -R inst-win64/include/. "$PREFIX/include/"
echo "cairo $CAIRO_VERSION (static, win64): $PREFIX"
