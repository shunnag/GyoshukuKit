#!/usr/bin/env python3
# P14 の期待出力: 詰める上限 PACK の build（S_PACK）と本文の片 PIECE の build（S_PIECE）の tar.xz から block を継ぐ。
# usage: p14-compose.py <S_PACK.tar.xz> <S_PIECE.tar.xz> <out.tar.xz> [PACK_MiB PIECE_MiB]
import subprocess, sys, struct, zlib, tarfile, io
pack_in, piece_in, out = sys.argv[1:4]
PACK = int(sys.argv[4] if len(sys.argv) > 4 else 4) << 20
PIECE = int(sys.argv[5] if len(sys.argv) > 5 else 16) << 20
def blocks(path):
    rows = subprocess.run(["xz", "--robot", "--list", "-vv", path], capture_output=True, text=True, check=True).stdout
    return [dict(coff=int(f[4]), uoff=int(f[5]), total=int(f[6]), usize=int(f[7]), hdr=int(f[11]), csize=int(f[13]))
            for f in (l.split("\t") for l in rows.splitlines()) if f[0] == "block"]
def members(path):
    image = subprocess.run(["xz", "-T0", "-dc", path], capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(image), mode="r:") as t:
        return [(m.offset, m.offset_data, m.offset_data + (m.size + 511) // 512 * 512 if m.isreg() else m.offset_data)
                for m in t.getmembers()], len(image)
ms, length = members(piece_in)
ranges = []  # (lo, hi, source)
for start, data, end in ms:
    size = end - start
    if size > PIECE: src = piece_in
    elif size > PACK and (end - data > PACK or data - start > PACK):
        sys.exit(f"not composable: member at {start} header {data - start} body {end - data}")
    else: src = pack_in
    if ranges and ranges[-1][2] == src and ranges[-1][1] == start: ranges[-1] = (ranges[-1][0], end, src)
    else: ranges.append((start, end, src))
if ranges[-1][2] == pack_in: ranges[-1] = (ranges[-1][0], length, pack_in)
else: ranges.append((ranges[-1][1], length, pack_in))
def vli(n):
    b = bytearray()
    while n >= 0x80: b.append((n & 0x7f) | 0x80); n >>= 7
    return bytes(b + bytes([n]))
cache = {p: (open(p, "rb").read(), blocks(p)) for p in (pack_in, piece_in)}
body = bytearray(cache[pack_in][0][:12]); records = []
for lo, hi, src in ranges:
    raw, bl = cache[src]
    sel = [b for b in bl if lo <= b["uoff"] < hi]
    if not sel or sel[0]["uoff"] != lo or sel[-1]["uoff"] + sel[-1]["usize"] != hi: sys.exit(f"blocks do not align at {lo}..{hi} in {src}")
    for b in sel:
        body += raw[b["coff"]:b["coff"] + b["total"]]; records.append((b["hdr"] + b["csize"] + 4, b["usize"]))
index = bytearray(b"\x00") + vli(len(records))
for unpadded, size in records: index += vli(unpadded) + vli(size)
index += bytes(-len(index) % 4); index += struct.pack("<I", zlib.crc32(index))
footer = struct.pack("<I", len(index) // 4 - 1) + bytes(body[6:8])
body += index + struct.pack("<I", zlib.crc32(footer)) + footer + b"YZ"
open(out, "wb").write(body)
print(f"{out}\tbytes={len(body)}\tblocks={len(records)}\tranges={len(ranges)}")
