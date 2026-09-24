#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || $1 == --help || $1 == -h ]]; then
    echo "Usage: $0 <new-or-empty-dir>"
    if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then exit 0; fi
    exit 1
fi

python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
if root.exists() and (not root.is_dir() or any(root.iterdir())):
    sys.exit(f"Refusing non-empty destination: {root}")
dictionary = Path(os.environ.get("WORDS_FILE", "/usr/share/dict/words"))
try:
    dictionary_bytes = dictionary.read_bytes()
except OSError as error:
    sys.exit(f"Cannot read dictionary {dictionary}: {error}")
words = [word + b" " for word in dictionary_bytes.splitlines() if word]
if not words:
    sys.exit(f"Empty dictionary: {dictionary}")
root.mkdir(parents=True, exist_ok=True)

size = 256 * 1024 * 1024
chunk_size = 1024 * 1024
fixed_time = 1_700_000_000
seeds = {"text": 20260924, "random": 20260925, "small": 20260926}
manifest = {
    "version": 1,
    "generator": "Python random.Random (MT19937); random bytes: getrandbits, little endian, 1 MiB blocks",
    "python": platform.python_version(),
    "seeds": seeds,
    "mtime": fixed_time,
    "dictionary": str(dictionary.resolve()),
    "dictionary_sha256": hashlib.sha256(dictionary_bytes).hexdigest(),
    "corpora": {},
}


def word_block(rng, length):
    data = bytearray()
    while len(data) < length:
        data.extend(rng.choice(words))
    return data[:length]


def describe(name, source):
    files = sorted(p for p in source.rglob("*") if p.is_file()) if source.is_dir() else [source]
    digest = hashlib.sha256()
    total = 0
    for item in files:
        relative = item.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        length = item.stat().st_size
        digest.update(length.to_bytes(8, "little"))
        total += length
        with item.open("rb") as stream:
            while block := stream.read(chunk_size):
                digest.update(block)
        item.chmod(0o644)
        os.utime(item, (fixed_time, fixed_time))
    if source.is_dir():
        directories = [source] + [p for p in source.rglob("*") if p.is_dir()]
        for directory in directories:
            directory.chmod(0o755)
            os.utime(directory, (fixed_time, fixed_time))
    manifest["corpora"][name] = {
        "path": source.name, "files": len(files), "bytes": total, "sha256": digest.hexdigest(),
    }
    print(f"{name}: {len(files)} files, {total} bytes, sha256={digest.hexdigest()}", flush=True)


print(f"Generating corpora in {root}", flush=True)
rng = random.Random(seeds["text"])
with (root / "text256.txt").open("xb") as stream:
    for _ in range(size // chunk_size):
        stream.write(word_block(rng, chunk_size))
describe("text", root / "text256.txt")

rng = random.Random(seeds["random"])
with (root / "random256.bin").open("xb") as stream:
    for _ in range(size // chunk_size):
        stream.write(rng.getrandbits(chunk_size * 8).to_bytes(chunk_size, "little"))
describe("random", root / "random256.bin")

sdk = os.environ.get("SDKROOT")
if not sdk and shutil.which("xcrun"):
    result = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True)
    if result.returncode == 0:
        sdk = result.stdout.strip()
include = Path(sdk) / "usr/include" if sdk else None
if include is not None and include.is_dir():
    # LHA でも同じ入力を使えるよう、SDK の symlink は実体をコピーする。
    shutil.copytree(include, root / "headers", symlinks=False)
    manifest["sdk"] = str(Path(sdk).resolve())
    describe("headers", root / "headers")
else:
    manifest["sdk"] = sdk
    manifest["corpora"]["headers"] = {"skipped": "macOS SDK usr/include is missing"}
    print(f"Skipping headers: macOS SDK usr/include is missing ({include or 'SDK not found'}).", flush=True)

rng = random.Random(seeds["small"])
(root / "small").mkdir()
for index in range(50_000):
    length = rng.randint(1024, 4096)
    (root / "small" / f"{index:05d}.txt").write_bytes(word_block(rng, length))
describe("small", root / "small")

(root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Provenance: {root / 'manifest.json'}")
PY
