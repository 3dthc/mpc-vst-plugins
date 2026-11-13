#!/usr/bin/env python3
"""Pack a folder into the blob a single-file Windows VST3 carries inside it (tools/build_vst3.sh, VST3_TARGET=windows):
   pack_embed.py <folder> <out.bin>
Format (little-endian): b"MPCRES01", u32 file count, then per file: u16 path length, the path (UTF-8, '/' separated,
relative to the folder), u32 size, the bytes. vst3_wrap.c (embed_dir) unpacks it once into %LOCALAPPDATA%."""
import os, struct, sys

root, out = sys.argv[1], sys.argv[2]
files = []
for d, _, names in os.walk(root):
    for n in sorted(names):
        p = os.path.join(d, n)
        files.append((os.path.relpath(p, root).replace(os.sep, "/"), p))
files.sort()
with open(out, "wb") as f:
    f.write(b"MPCRES01" + struct.pack("<I", len(files)))
    total = 0
    for rel, p in files:
        data = open(p, "rb").read()
        b = rel.encode("utf-8")
        f.write(struct.pack("<H", len(b)) + b + struct.pack("<I", len(data)) + data)
        total += len(data)
print("embedded: %d files, %.1f MB" % (len(files), total / 1e6))
