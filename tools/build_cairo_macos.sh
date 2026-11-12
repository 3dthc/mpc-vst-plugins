#!/usr/bin/env bash
# Build a static, universal (arm64 + x86_64) cairo for the macOS VST3 editor (tools/build_vst3.sh, VST3_TARGET=macos):
#   tools/build_cairo_macos.sh <prefix>
# Output: <prefix>/lib/{libcairo,libpixman-1,libfreetype,libpng16,libz}.a (universal) and <prefix>/include/...
# Runs on a Mac with the Xcode command line tools, python3 (meson and ninja are pip-installed if missing) and network
# access. cairo's own Meson subprojects supply pixman, FreeType, libpng and zlib, pinned by the cairo release below.
# Only the image surface, PNG and FreeType font backends are built: no X11, Quartz, fontconfig or glib, so nothing in the
# result links to anything outside the plugin. Each architecture is built on its own and the libraries joined with lipo.
set -euo pipefail
PREFIX="$(mkdir -p "$1" && cd "$1" && pwd)"
CAIRO_VERSION=1.18.4
CAIRO_SHA256=PIN_ME
WORK="${CAIRO_WORK:-$(mktemp -d)}"
if ! command -v meson >/dev/null || ! command -v ninja >/dev/null; then   # a venv of its own: Homebrew's Python is externally managed
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet meson ninja
  export PATH="$WORK/venv/bin:$PATH"
fi
cd "$WORK"
if [ ! -d "cairo-$CAIRO_VERSION" ]; then
  curl -fsSL -o cairo.tar.xz "https://cairographics.org/releases/cairo-$CAIRO_VERSION.tar.xz"
  shasum -a 256 cairo.tar.xz
  echo "$CAIRO_SHA256  cairo.tar.xz" | shasum -a 256 -c -
  tar xf cairo.tar.xz
fi
SRC="$WORK/cairo-$CAIRO_VERSION"
OPTS=(--buildtype=release --default-library=static --wrap-mode=forcefallback -Db_ndebug=true
      -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled -Dfontconfig=disabled -Dquartz=disabled -Dxlib=disabled
      -Dxcb=disabled -Dglib=disabled -Dspectre=disabled -Dsymbol-lookup=disabled -Dtests=disabled -Dgtk_doc=false
      -Dlzo=disabled -Dgtk2-utils=disabled
      -Dpixman:tests=disabled -Dpixman:demos=disabled -Dpixman:gtk=disabled -Dpixman:libpng=disabled
      -Dfreetype2:png=disabled -Dfreetype2:bzip2=disabled -Dfreetype2:brotli=disabled -Dfreetype2:harfbuzz=disabled
      -Dfreetype2:zlib=internal)
for arch in arm64 x86_64; do
  cat > "cross-$arch.ini" <<INI
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
objc = ['clang', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
[built-in options]
c_args = ['-mmacosx-version-min=10.13', '-fPIC']
cpp_args = ['-mmacosx-version-min=10.13', '-fPIC']
c_link_args = ['-mmacosx-version-min=10.13']
[host_machine]
system = 'darwin'
cpu_family = '$( [ $arch = arm64 ] && echo aarch64 || echo x86_64 )'
cpu = '$arch'
endian = 'little'
INI
  rm -rf "build-$arch" "inst-$arch"
  extra=()
  [ "$arch" = arm64 ] || extra=(-Dpixman:a64-neon=disabled)
  meson setup "build-$arch" "$SRC" --cross-file "cross-$arch.ini" --prefix "$WORK/inst-$arch" "${OPTS[@]}" "${extra[@]}"
  meson compile -C "build-$arch"
  meson install -C "build-$arch" --quiet
done
mkdir -p "$PREFIX/lib" "$PREFIX/include"
for lib in libcairo libpixman-1 libfreetype libpng16 libz; do
  a="$(cd "$WORK/inst-arm64" && find . -name "$lib.a" | head -1)"
  [ -n "$a" ] || { echo "missing $lib.a" >&2; exit 1; }
  lipo -create "$WORK/inst-arm64/$a" "$WORK/inst-x86_64/$a" -output "$PREFIX/lib/$lib.a"
done
cp -R "$WORK/inst-arm64/include/." "$PREFIX/include/"
lipo -info "$PREFIX/lib/libcairo.a"
echo "cairo $CAIRO_VERSION (static, universal): $PREFIX"
