#!/bin/sh
# Offline test (Linux container, the host's own arch): builds the probe and a driver that makes MPC-like ALSA calls on
# alsa-lib's "null" PCM, runs the driver with and without the probe preloaded, and checks that every call returns the same
# with it as without it, and that the log has the expected lines. Prints PASSED or FAILED.
set -eu
cd "$(dirname "$0")"
docker run --rm -v "$PWD":/w -w /w debian:bookworm sh -c '
set -eu
apt-get -qq update >/dev/null && apt-get -qq install -y gcc libc6-dev libasound2-dev >/dev/null 2>&1
mkdir -p build/host
gcc -O1 -g -Wall -Wextra -fPIC -shared -fvisibility=hidden -Wl,--no-undefined -o build/host/libalsatrace.so alsatrace.c -ldl -lpthread
gcc -O1 -g -Wall -o build/host/driver test_driver.c -lasound
./build/host/driver > build/host/plain.txt
rm -f build/host/trace.log
ALSATRACE_LOG=build/host/trace.log LD_PRELOAD=$PWD/build/host/libalsatrace.so ./build/host/driver > build/host/traced.txt
fail=0
cmp -s build/host/plain.txt build/host/traced.txt || { echo "FAIL: results differ with the probe loaded"; diff build/host/plain.txt build/host/traced.txt | head; fail=1; }
for want in "open \"null\" PLAYBACK" "open \"null\" CAPTURE" "hw set_access" "hw set_format" "hw set_rate " "hw test_rate" \
            "hw set_rate_near" "hw set_period_size_near" "hw set_buffer_size_near" "hw_params (apply)" "sw set_start_threshold" \
            "sw_params (apply)" "link " "prepare " "start " "writei " "readi " "totals " "writei: " "close " "card_next " "ctl_open "; do
    grep -q -- "$want" build/host/trace.log || { echo "FAIL: no \"$want\" line in the log"; fail=1; }
done
n=$(grep -c " writei " build/host/trace.log || true)
[ "$n" -le 6 ] || { echo "FAIL: writei logged $n times (only the first 3 per PCM should be)"; fail=1; }
nm -D --defined-only build/host/libalsatrace.so | awk "{print \$3}" | grep -v -E "^(snd_pcm_|snd_ctl_|snd_card_next$|snd_device_name_hint$|_init$|_fini$)" | grep . && { echo "FAIL: exports other than snd_pcm_*"; fail=1; }
cat build/host/trace.log | head -n 60
[ $fail = 0 ] && echo PASSED || { echo FAILED; exit 1; }
'
