#!/usr/bin/env python3
"""同じ swiftc flags で旧版と作業 tree を比較する。XCTest は使わない。"""
import argparse
import filecmp
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("Sources/GyoshukuKit/Compression/PPMd")
H_ORDERS = [3, 4, 4, 5, 6, 6, 8, 12, 16]
I_ORDERS = [3, 4, 5, 6, 8, 8, 10, 12, 16]
HEAPS = [1, 2, 4, 8, 16, 16, 32, 64, 192]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--mode", choices=["all", "build", "bench", "identity", "profile"], default="all")
parser.add_argument("--directory", type=Path, default=ROOT / ".build/ppmd-r2")
parser.add_argument("--baseline", default="f273d34")
parser.add_argument("--runs", type=int, default=7)
args = parser.parse_args()
if args.runs < 5:
    parser.error("--runs must be at least 5")
work = args.directory.resolve()
work.mkdir(parents=True, exist_ok=True)
os.chdir(ROOT)


def run(command, **kwargs):
    return subprocess.check_output([str(x) for x in command], **kwargs)


def build():
    cache = ROOT / ".build/clang-module-cache"
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    flags = ["-O", "-wmo", "-swift-version", "6", "-module-cache-path", str(cache)]
    commands = {}
    source_hashes = {}
    for label in ["baseline", "new"]:
        directory = work / label
        directory.mkdir(exist_ok=True)
        sources = []
        source_hashes[label] = {}
        for path in sorted((ROOT / SOURCE).glob("*.swift")):
            relative = path.relative_to(ROOT)
            data = run(["git", "show", f"{args.baseline}:{relative}"]) if label == "baseline" else path.read_bytes()
            target = directory / path.name
            target.write_bytes(data)
            sources.append(target)
            source_hashes[label][path.name] = hashlib.sha256(data).hexdigest()
        command = ["swiftc", *flags, *sources, ROOT / "Tests/GyoshukuKitTests/Support/TestCorpus.swift",
                   ROOT / "Benchmarks/PPMd/main.swift", "-o", directory / "encoder"]
        commands[label] = [str(x) for x in command]
        subprocess.run(command, env=env, check=True)
    (work / "build.json").write_text(json.dumps({"baseline": args.baseline, "commands": commands,
                                               "source_sha256": source_hashes}, indent=2))
    run([work / "new/encoder", "prepare", work / "corpora"])


def encode(label, corpus, variant, order, heap, restoration=0, width=0, output=None):
    command = [work / label / "encoder", "encode", work / "corpora" / f"{corpus}.bin",
               variant, order, heap, restoration, 1, width]
    if output:
        command.append(output)
    size, elapsed, speed = run(command, text=True).strip().split("\t")
    return {"bytes": int(size), "seconds": float(elapsed), "MB/s": float(speed)}


def reference_command(corpus, variant, level, order, heap):
    tool = shutil.which("7zz")
    archive = work / f"reference-{corpus}-{variant}-{level}.{'zip' if variant == 'I' else '7z'}"
    method = (["-t7z", f"-m0=PPMd:o={order}:mem={heap}m"] if variant == "H" else
              ["-tzip", f"-mm=PPMd:o={order}:mem={heap}m:a=0", f"-mx={level}"])
    command = [tool, "a", *method, "-mmt=1", archive, work / "corpora" / f"{corpus}.bin"]
    return archive, command


def reference(corpus, variant, order, archive, command, times):
    tool = command[0]
    run([tool, "t", archive])
    assert run([tool, "x", "-so", archive]) == (work / "corpora" / f"{corpus}.bin").read_bytes()
    listing = run([tool, "l", "-slt", archive], text=True)
    size = int([line.split(" = ")[1] for line in listing.splitlines() if line.startswith("Packed Size = ")][-1])
    if variant == "I":
        data = archive.read_bytes()
        offset = 30 + int.from_bytes(data[26:28], "little") + int.from_bytes(data[28:30], "little")
        word = int.from_bytes(data[offset:offset + 2], "little")
        assert (word & 15) + 1 == order and word >> 12 == 0
        actual_heap = ((word >> 4) & 255) + 1
    else:
        tag = [line.split(":mem")[1] for line in listing.splitlines() if line.startswith(f"Method = PPMD:o{order}:mem")][-1]
        actual_heap = int(tag[:-1]) if tag.endswith("m") else (1 << int(tag)) >> 20
    fastest = min(times)
    return {"bytes": size, "seconds": fastest,
            "MB/s": (work / "corpora" / f"{corpus}.bin").stat().st_size / 1e6 / fastest,
            "heapMiB": actual_heap, "runs": times, "command": [str(x) for x in command]}


def bench():
    start = time.monotonic()
    result = {"load_start": os.getloadavg(), "swift": run(["swiftc", "--version"], text=True),
              "7zz": run([shutil.which("7zz"), "i"], text=True).splitlines()[:4], "rows": []}
    for corpus, variant, level in itertools.product(["text", "dyld"], ["H", "I"], [1, 6, 9]):
        order, heap = (I_ORDERS if variant == "I" else H_ORDERS)[level - 1], HEAPS[level - 1]
        row = {"corpus": corpus, "variant": variant, "level": level, "order": order, "heapMiB": heap,
               "input_bytes": (work / "corpora" / f"{corpus}.bin").stat().st_size,
               "load": os.getloadavg(), "baseline": [], "new": []}
        archive, command = reference_command(corpus, variant, level, order, heap)
        reference_times = []
        for _ in range(args.runs):
            for label in ["baseline", "new"]:
                row[label].append(encode(label, corpus, variant, order, heap, output=work / f"bench-{label}"))
            archive.unlink(missing_ok=True)
            reference_start = time.monotonic()
            run(command)
            reference_times.append(time.monotonic() - reference_start)
        assert filecmp.cmp(work / "bench-baseline", work / "bench-new", shallow=False)
        row["7zz"] = reference(corpus, variant, order, archive, command, reference_times)
        result["rows"].append(row)
        (work / "benchmark.json").write_text(json.dumps(result, indent=2))
        speeds = {label: max(x["MB/s"] for x in row[label]) for label in ["baseline", "new"]}
        print("BENCH", corpus, variant, level, speeds, "ratio", speeds["new"] / speeds["baseline"], flush=True)
    result.update(load_end=os.getloadavg(), seconds=time.monotonic() - start)
    (work / "benchmark.json").write_text(json.dumps(result, indent=2))


def identity():
    start = time.monotonic()
    rows = []
    for corpus in ["dyld", "zsh", "mixed", "empty", "one", "zeros"]:
        for variant in ["H", "I"]:
            orders = [2, 4, 8, 16, 32] if variant == "H" else [2, 4, 8, 16]
            for order, heap, restoration in itertools.product(orders, [1, 3, 64], [0] if variant == "H" else [0, 1]):
                for label in ["baseline", "new"]:
                    encode(label, corpus, variant, order, heap, restoration, output=work / f"identity-{label}")
                assert filecmp.cmp(work / "identity-baseline", work / "identity-new", shallow=False), (corpus, variant, order, heap, restoration)
                data = (work / "identity-new").read_bytes()
                rows.append([corpus, variant, order, heap, restoration, len(data), hashlib.sha256(data).hexdigest()])
        print("IDENTITY", corpus, len(rows), flush=True)
    # 全 preset のサイズと、呼出しをまたぐ状態の byte 一致も確認する。
    for corpus, variant, level in itertools.product(["text", "dyld"], ["H", "I"], range(1, 10)):
        order, heap = (I_ORDERS if variant == "I" else H_ORDERS)[level - 1], HEAPS[level - 1]
        for restoration in ([0, 1] if variant == "I" else [0]):
            for label in ["baseline", "new"]:
                encode(label, corpus, variant, order, heap, restoration, output=work / f"identity-{label}")
            assert filecmp.cmp(work / "identity-baseline", work / "identity-new", shallow=False)
            rows.append([corpus, variant, "level", level, restoration, (work / "identity-new").stat().st_size])
    for variant, width in itertools.product(["H", "I"], [1, 7, 65536]):
        encode("baseline", "zeros", variant, 8, 3, output=work / "identity-baseline")
        encode("new", "zeros", variant, 8, 3, width=width, output=work / "identity-new")
        assert filecmp.cmp(work / "identity-baseline", work / "identity-new", shallow=False)
        rows.append(["streaming", variant, width])
    for variant in ["H", "I"]:
        for restoration, width in itertools.product([0, 1] if variant == "I" else [0], [7, 65536]):
            encode("baseline", "dyld", variant, 8, 3, restoration, output=work / "identity-baseline")
            encode("new", "dyld", variant, 8, 3, restoration, width, output=work / "identity-new")
            assert filecmp.cmp(work / "identity-baseline", work / "identity-new", shallow=False)
            rows.append(["streaming-dyld", variant, restoration, width])
    (work / "identity.json").write_text(json.dumps({"rows": rows, "seconds": time.monotonic() - start}, indent=2))
    print("IDENTITY PASS", len(rows), "seconds", time.monotonic() - start, flush=True)


def profile():
    # 診断専用のコピーに 1024 回ごとの timer を挿入する。速度の表には使わない。
    directory = work / "profile"
    directory.mkdir(exist_ok=True)
    phases = {"encode": 0, "updateModelH": 1, "updateModelI": 1,
              "createSuccessorsH": 2, "createSuccessorsI": 2, "rescale": 3}
    sources = []
    for path in sorted((ROOT / SOURCE).glob("*.swift")):
        data = path.read_text()
        for function, phase in phases.items():
            if function == "encode" and path.name != "PPMdModel.swift":
                continue
            marker = f"mutating func {function}("
            if marker in data:
                offset = data.index("{", data.index(marker)) + 1
                data = data[:offset] + f"\n        let tick = Profile.begin({phase})\n        defer {{ Profile.end({phase}, tick) }}" + data[offset:]
        if path.name == "PPMdModel.swift":
            marker = "        while true {\n            try coder.normalize"
            data = data.replace(marker, "        let suffixTick = Profile.begin(4)\n        defer { Profile.end(4, suffixTick) }\n" + marker)
        target = directory / path.name
        target.write_text(data)
        sources.append(target)
    support = directory / "Profile.swift"
    support.write_text('''import Darwin
enum Profile {
    nonisolated(unsafe) static let counts = UnsafeMutablePointer<UInt64>.allocate(capacity: 15)
    static func reset() { counts.initialize(repeating: 0, count: 15) }
    @inline(__always) static func begin(_ phase: Int) -> UInt64 {
        counts[phase] &+= 1
        if counts[phase] & 1023 != 0 { return 0 }
        counts[phase + 5] &+= 1
        return mach_absolute_time()
    }
    @inline(__always) static func end(_ phase: Int, _ tick: UInt64) {
        if tick != 0 { counts[phase + 10] &+= mach_absolute_time() &- tick }
    }
    static func report() {
        for phase in 0..<5 {
            print("PROFILE\\t\\(phase)\\t\\(counts[phase])\\t\\(counts[phase + 5])\\t\\(counts[phase + 10])")
        }
    }
}
''')
    main = directory / "main.swift"
    data = (ROOT / "Benchmarks/PPMd/main.swift").read_text()
    main.write_text(data.replace("let args = CommandLine.arguments", "Profile.reset()\nlet args = CommandLine.arguments") + "\nProfile.report()\n")
    cache = ROOT / ".build/clang-module-cache"
    command = ["swiftc", "-O", "-wmo", "-swift-version", "6", "-module-cache-path", cache,
               *sources, support, ROOT / "Tests/GyoshukuKitTests/Support/TestCorpus.swift", main,
               "-o", directory / "encoder"]
    subprocess.run([str(x) for x in command], env=dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache)), check=True)
    results = {}
    for corpus, variant in itertools.product(["text", "dyld"], ["H", "I"]):
        output = run([directory / "encoder", "encode", work / "corpora" / f"{corpus}.bin",
                      variant, 6 if variant == "H" else 8, 16, 0, 20, 0], text=True)
        results[f"{corpus}-{variant}"] = output
        print(corpus, variant, output[output.index("PROFILE"):], flush=True)
    (work / "profile.json").write_text(json.dumps(results, indent=2))


if args.mode in ["all", "build"]:
    build()
if args.mode in ["all", "bench"]:
    bench()
if args.mode in ["all", "identity"]:
    identity()
if args.mode == "profile":
    profile()
