#!/usr/bin/env bash
# One MPC preset file per program, for the Sounds browser's preset page (docs/NOTES.md, "Instruments-browser tiles"):
#   tools/xpl_presets.sh path/to/vst.json [out dir]
# Builds the port with the wrapper on this machine (like tools/test_port.sh, without sanitizers), selects each program
# and writes <out dir>/NNNN-<name>.xpl holding the plugin's own chunk for it (default out dir: <vst dir>/xpl). Commit the
# folder and name it in vst.json as "xpl_presets": gen_vst.py ships it as the skin's Presets/ in place of the Default one.
# Categories (folders on MPC's preset page, NNNN-<category>-<name>.xpl): vst.json "xpl_category" is "engine" (the engine
# answers get_param("preset_category:<index>")) or a regex on the program name with (?P<cat>) and optionally (?P<name>).
# Run it from wherever the engine finds its data at runtime when that matters (the plugin dir is the build dir here).
set -euo pipefail
MV="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
eval "$(python3 "$MV/tools/gen_vst.py" "$CFG" --shell)"
[ "$(uname -s)" = Darwin ] && LIBS=${LIBS//-ldl/}
python3 "$MV/tools/gen_vst.py" "$CFG" --params-h >/dev/null
OUTDIR="${2:-$(dirname "$CFG")/xpl}"
ADAPTER_SRC=""
[ -n "$ADAPTER" ] && ADAPTER_SRC="$MV/adapters/$ADAPTER/${ADAPTER}_engine.c"
B="$ROOT/$PORT/build/xpl"
mkdir -p "$B"
cd "$ROOT"
OBJS=""
for f in $SOURCES; do
  o="$B/${f//\//_}.o"
  case "$f" in
    *.cpp|*.cc|*.cxx) echo "g++ -O1 -w -std=gnu++17 $CFLAGS -I$PORT/build -I$MV/wrapper -c $f -o $o" ;;
    *) echo "gcc -O1 -w -std=gnu11 $CFLAGS -I$PORT/build -I$MV/wrapper -c $f -o $o" ;;
  esac
  OBJS="$OBJS $o"
done | xargs -P "$(nproc 2>/dev/null || echo 4)" -I{} sh -c '{}'
OBJS=""
for f in $SOURCES; do OBJS="$OBJS $B/${f//\//_}.o"; done
for f in "$MV/tools/xpl_dump.c" "$MV/wrapper/vst2_wrap.c" $ADAPTER_SRC; do
  o="$B/$(basename "$f").o"
  gcc -O1 -w -std=gnu11 -DPROG_NAME_LEN=64 -I"$PORT/build" -I"$MV/wrapper" -c "$f" -o "$o"
  OBJS="$OBJS $o"
done
g++ $OBJS $LIBS -lpthread -o "$B/xpl_dump"
# MODULE_SUBDIR (data beside the plugin, found at runtime): link the port's folder of that name beside this binary
SUB=$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1])).get("defines",{}).get("MODULE_SUBDIR","")).strip("\""))' "$CFG")
if [ -n "$SUB" ] && [ ! -e "$B/$SUB" ]; then
  for d in "$(dirname "$CFG")/$SUB" "$ROOT/$SUB"; do [ -d "$d" ] && ln -s "$d" "$B/$SUB" && break; done
fi
EC=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1])).get("xpl_category")=="engine" else "")' "$CFG")
(cd "$B" && XPL_ENGINE_CATEGORY=$EC "$B/xpl_dump") > "$B/programs.tsv"
python3 -c '
import json,re,sys
c=json.load(open(sys.argv[1])); s=re.compile(c["xpl_skip"]) if c.get("xpl_skip") else None
for i,l in enumerate(open(sys.argv[2],encoding="utf-8",errors="replace")):
    n=l.split("\t")[0].strip()
    if n and not (s and s.search(n)): sys.stdout.write("%d %s" % (i,l))' "$CFG" "$B/programs.tsv" > "$B/keep.tsv"
(cd "$B" && "$B/xpl_dump" --verify < "$B/keep.tsv") || { echo "xpl_presets: a preset does not restore its program (above)"; exit 1; }
python3 "$MV/tools/xpl.py" --programs "$CFG" "$B/programs.tsv" "$OUTDIR"
