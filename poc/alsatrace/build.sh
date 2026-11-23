#!/bin/sh
# Build the alsatrace probe: build/package/ (armhf .so + addin.manifest + the shared addin installer, ready to copy to a
# device and run `sh install.sh`), and build/tools/mpc_negotiate (armhf, run on the device: replays MPC's ALSA negotiation
# against a PCM name). test.sh builds build/host/ for the offline test. Needs Docker.
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p build/package
CFLAGS="-O2 -Wall -Wextra -fPIC -shared -fvisibility=hidden -Wl,--no-undefined"
docker run --rm --platform linux/arm/v7 -v "$PWD":/w -w /w arm32v7/gcc:11-bullseye \
    sh -c "gcc $CFLAGS -o build/package/libalsatrace.so alsatrace.c -ldl -lpthread && mkdir -p build/tools && gcc -O2 -Wall -o build/tools/mpc_negotiate mpc_negotiate.c -ldl -lm -lpthread"
cp addin.manifest build/package/
cp "$ROOT/tools/release/addin/install.sh" "$ROOT/tools/release/addin/uninstall.sh" "$ROOT/tools/release/addin/addin-lib.sh" build/package/
echo "built build/package/ and build/tools/mpc_negotiate (armhf)"
