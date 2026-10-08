#!/usr/bin/env python3
"""単一・tree・小ファイル・256 MiB corpus の release executable 交互比較。C/C++ のソースは使わない。"""
import argparse
import hashlib
import json
import io
import tarfile
import os
from pathlib import Path
import random
import resource
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = (["zip-" + m for m in ["stored", "deflate", "bzip2", "lzma", "xz", "zstd", "ppmd"]]
         + ["tar" + s for s in ["", ".gz", ".bz2", ".xz", ".zst", ".lz", ".lzma", ".lz4", ".br", ".Z"]]
         + ["7z-" + m + s for m in ["lzma2", "lzma", "deflate", "bzip2", "ppmd", "copy"]
            for s in ["", "-filter", "-solid", "-solid-filter"]]
         + ["lha-lh5", "lha-lh6", "lha-lh7"]
         + ["stream-" + s for s in ["gz", "bz2", "xz", "zst", "lz", "lzma", "lz4", "br", "Z"]])


def corpus(directory):
    members = directory / "mixed"
    members.mkdir(parents=True, exist_ok=True)
    snapshot = subprocess.run(["git", "archive", "f273d34", "Sources/GyoshukuKit"], cwd=ROOT,
                              stdout=subprocess.PIPE, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(snapshot)) as archive:
        source = b"".join(archive.extractfile(p).read() for p in sorted(archive.getmembers(), key=lambda p: p.name)
                          if p.name.endswith(".swift") and p.isfile())
    rng = random.Random(0x47594F5348554B55)
    mib = 1 << 20
    pattern = bytes(range(256)) * 4096
    for i in range(96):
        start = (i * 1871) % len(source)
        text = (source[start:] + source[:start]) * 4
        data = text[:mib] + pattern[:mib // 2] + rng.randbytes(mib // 2)
        path = members / f"medium-{i:03d}.dat"
        path.write_bytes(data)
        os.utime(path, (1700000000, 1700000000))
    large = b"".join((source * 4)[:mib] + pattern[:mib // 2] + rng.randbytes(mib // 2) for _ in range(32))
    path = members / "z-large.dat"
    path.write_bytes(large)
    os.utime(path, (1700000000, 1700000000))
    with (directory / "mixed.bin").open("wb") as out:
        for path in sorted(members.iterdir()):
            out.write(path.read_bytes())
    raw = (directory / "mixed.bin").read_bytes()
    assert len(raw) == 256 * mib
    (directory / "manifest.json").write_text(json.dumps({
        "bytes": len(raw), "files": 97, "medium": "96 x 2 MiB", "large": "1 x 64 MiB",
        "composition": "50% repository Swift text, 25% repeated binary bytes, 25% seeded random",
        "seed": "0x47594f5348554b55", "sha256": hashlib.sha256(raw).hexdigest(),
    }, indent=2) + "\n")


ROUND2 = {
    "single": ["lha-lh5", "lha-lh7", "7z-deflate-solid", "7z-lzma2-solid", "zip-xz", "zip-zstd"],
    "small": ["zip-zstd", "zip-bzip2", "zip-deflate", "7z-lzma", "7z-lzma2"],
    "lha-mixed": ["lha-lh5", "lha-lh7"],
    "corpus": ["zip-" + m for m in ["stored", "deflate", "bzip2", "lzma", "xz", "zstd", "ppmd"]]
        + ["7z-" + m + suffix for m in ["lzma2", "lzma", "deflate", "bzip2", "ppmd", "copy"]
           for suffix in ["", "-filter", "-solid", "-solid-filter"]]
        + ["lha-lh5", "lha-lh6", "lha-lh7"],
}


ROUND3 = {
    "tree": ["zip-zstd", "zip-bzip2", "zip-deflate", "zip-stored", "7z-lzma", "7z-lzma2"],
    "single16r": ["zip-zstd", "zip-bzip2", "zip-deflate", "zip-stored", "7z-lzma", "7z-lzma2"],
    "single": ROUND2["single"],
    "small": ROUND2["small"],
    "lha-mixed": ROUND2["lha-mixed"],
    "corpus": ["zip-zstd", "zip-bzip2", "7z-lzma2-solid", "lha-lh7"],
}



# r3bは変更したLHAとZIPに絞り、過去のprofileは保存する。
ROUND3B = {
    "corpus": ["lha-lh7", "zip-zstd", "zip-bzip2"],
    "lha-mixed": ["lha-lh5", "lha-lh7"],
    "single": ["lha-lh5", "lha-lh7", "zip-zstd"],
    "tree": ["zip-zstd", "zip-bzip2", "zip-deflate", "zip-stored"],
    "small": ["zip-zstd", "zip-bzip2", "zip-deflate"],
}


def workload_cases(args, workload):
    catalog = {"round3": ROUND3, "round3b": ROUND3B}.get(args.profile, {**ROUND2, "tree": ROUND3["tree"], "single16r": ROUND3["single16r"]})
    return args.cases.split(",") if args.cases else catalog[workload]


def workload_threads(args, workload):
    return [int(t) for t in args.threads.split(",")] if args.threads else ([12] if args.profile in ["round3", "round3b"] and workload == "corpus" else [1, 12])


def regression_corpora(directory):
    source = (directory / "mixed.bin").read_bytes()
    single = directory / "single"
    single.mkdir(exist_ok=True)
    (single / "single.dat").write_bytes(source[:10 * (1 << 20)])
    small = directory / "small"
    small.mkdir(exist_ok=True)
    rng = random.Random(20261007)
    for index in range(5000):
        size = rng.randint(1024, 4096)
        start = rng.randrange(len(source) // 2 - size)
        (small / f"small-{index:05d}.dat").write_bytes(source[start:start + size])
    mixed = directory / "lha-mixed"
    mixed.mkdir(exist_ok=True)
    shutil.copyfile(single / "single.dat", mixed / "000-medium.dat")
    for index, path in enumerate(sorted(small.iterdir())[:128]):
        shutil.copyfile(path, mixed / f"tiny-{index:04d}.dat")
    random_single = directory / "single16r"
    random_single.mkdir(exist_ok=True)
    (random_single / "random.dat").write_bytes(random.Random(20261008).randbytes(16 << 20))
    tree = directory / "tree"
    tree.mkdir(exist_ok=True)
    snapshot = subprocess.run(["git", "archive", "f273d34", "Sources/GyoshukuKit"], cwd=ROOT,
                              stdout=subprocess.PIPE, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(snapshot)) as archive:
        text = b"".join(archive.extractfile(p).read() for p in sorted(archive.getmembers(), key=lambda p: p.name)
                        if p.name.endswith(".swift") and p.isfile())
    rng = random.Random(20261008)
    for index in range(100):
        folder = tree / f"folder-{index:03d}"
        folder.mkdir(exist_ok=True)
        for file in range(6):
            size = rng.randint(64 << 10, 256 << 10)
            start = rng.randrange(len(text))
            data = text[start:] + text[:start]
            (folder / f"text-{file}.txt").write_bytes((data * ((size + len(data) - 1) // len(data)))[:size])
        (folder / "z-empty").write_bytes(b"")
        (folder / "zz-subdirectory").mkdir(exist_ok=True)
    for members in [single, small, mixed, random_single, tree]:
        for path in list(members.rglob("*")) + [members]:
            os.chmod(path, 0o755 if path.is_dir() else 0o644)
            os.utime(path, (1700000000, 1700000000))


def measure(args):
    results = args.results.resolve()
    results.parent.mkdir(parents=True, exist_ok=True)
    bundles = {"base": args.base.resolve(), "new": args.new.resolve()}
    if args.round1:
        bundles = {"base": args.base.resolve(), "round1": args.round1.resolve(), "new": args.new.resolve()}
    completed = {}
    hashes = {}
    if results.exists():
        for line in results.read_text().splitlines():
            row = json.loads(line)
            if row.get("mode", "item") != args.mode:
                continue
            key = (row["workload"], row["path"], row["threads"], row["label"])
            completed[key] = completed.get(key, 0) + 1
            hashes.setdefault((row["workload"], row["path"]), set()).add((row["sha256"], row["output_bytes"]))
    for workload in args.workloads.split(","):
        selected = workload_cases(args, workload)
        members = args.corpus / ("mixed" if workload == "corpus" else workload)
        for case in selected:
            for repeat in range(args.repeats):
                # 三版の順も回転・反転し、同じ条件を続けて比較する。
                labels = list(bundles)
                order = labels[repeat % len(labels):] + labels[:repeat % len(labels)]
                if len(labels) == 3 and (repeat // len(labels)) % 2: order.reverse()
                for threads in workload_threads(args, workload):
                    for label in order:
                        if completed.get((workload, case, threads, label), 0) > repeat:
                            continue
                        suffix = {"round3": ".r3", "round3b": ".r3b"}.get(args.profile, "")
                        if args.mode == "batch": suffix += ".batch"
                        log = results.parent / f"{workload}-{case}-{threads}-{label}-{repeat}{suffix}.log"
                        print(f"{workload} {case} threads={threads} {label} sample={repeat + 1}/{args.repeats}", flush=True)
                        key = (workload, case)
                        for attempt in range(2):
                            # 列挙によるatime更新も戻す。harnessも計時直前に再設定する。
                            for source in list(members.rglob("*")) + [members]:
                                os.utime(source, (1700000000, 1700000000))
                            sample = log.with_suffix(".sample.jsonl")
                            sample.unlink(missing_ok=True)
                            attempt_log = log if attempt == 0 else log.with_suffix(".retry.log")
                            with attempt_log.open("w") as out:
                                subprocess.run([str(bundles[label]), str(args.corpus.resolve()), str(sample),
                                                case, str(threads), label, workload] + (["batch"] if args.mode == "batch" else []),
                                               cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=True)
                            row = json.loads(sample.read_text())
                            if row.get("mode", "item") != args.mode:
                                raise RuntimeError(f"Harness mode mismatch: expected {args.mode}; see {attempt_log}")
                            sample.unlink()
                            identity = (row["sha256"], row["output_bytes"])
                            if not hashes.get(key) or identity in hashes[key]:
                                hashes.setdefault(key, set()).add(identity)
                                with results.open("a") as out:
                                    out.write(json.dumps(row, sort_keys=True) + "\n")
                                break
                            # 不一致sampleはbest値から除外し、再試行の根拠だけ別に保存する。
                            with results.with_suffix(".retry.jsonl").open("a") as out:
                                out.write(json.dumps({**row, "attempt": attempt, "log": str(attempt_log)}, sort_keys=True) + "\n")
                            if attempt:
                                raise RuntimeError(f"Output identity failed after retry: {key}; see {attempt_log}")
                            print(f"Output identity mismatch: {key}; retry once", flush=True)



def report(args):
    rows = [row for line in args.results.read_text().splitlines()
            if (row := json.loads(line)).get("mode", "item") == args.mode]
    labels = ["base", "round1", "new"] if args.round1 else ["base", "new"]
    names = " / ".join(labels)
    print(f"| workload / method | t=1 {names} 秒 | t=12 {names} 秒 | new/base 最大 | new/round1 最大 | load(1分) {names}: t=1; t=12 |")
    print("|---|---:|---:|---:|---:|---|")
    failures = []
    for workload in args.workloads.split(","):
        for case in workload_cases(args, workload):
            samples = {}
            threads = workload_threads(args, workload)
            for t in threads:
                for label in labels:
                    group = [r for r in rows if (r["workload"], r["path"], r["threads"], r["label"]) == (workload, case, t, label)]
                    if len(group) != args.repeats:
                        raise RuntimeError(f"Expected {args.repeats} samples: {workload}/{case}/{t}/{label}: {len(group)}")
                    samples[t, label] = min(group, key=lambda r: r["wall_s"])
            identities = {(r["sha256"], r["output_bytes"]) for r in rows if r["workload"] == workload and r["path"] == case}
            if len(identities) != 1:
                raise RuntimeError(f"Output identity failed: {workload}/{case}")
            ratios = [samples[t, "new"]["wall_s"] / samples[t, "base"]["wall_s"] for t in threads]
            r1 = [samples[t, "new"]["wall_s"] / samples[t, "round1"]["wall_s"] for t in threads] if args.round1 else []
            timing = [" / ".join(f'{samples[t, label]["wall_s"]:.4f}' for label in labels) if t in threads else "—" for t in [1, 12]]
            loads = "; ".join("/".join(f'{samples[t, label]["load"][0]:.2f}' for label in labels) if t in threads else "—" for t in [1, 12])
            r1_ratio = f"{max(r1):.3f}" if r1 else "—"
            print(f"| {workload} / {case} | {timing[0]} | {timing[1]} | {max(ratios):.3f} | {r1_ratio} | {loads} |")
            for t, ratio in zip(threads, ratios):
                if ratio > 1.05:
                    failures.append(f"{workload}/{case}/t={t} new/base: {ratio:.3f}")
            if workload in ["tree", "small"] or (args.profile == "round3b" and workload == "corpus" and case == "lha-lh7"):
                for t, ratio in zip(threads, r1):
                    if ratio > 1.05:
                        failures.append(f"{workload}/{case}/t={t} new/round1: {ratio:.3f}")
    print(f"\nSHA-256/size: all builds/thread counts identical. No-regression: {len(failures) == 0}.")
    if failures:
        print("\n" + "\n".join(failures))
        raise SystemExit(1)


def references(args):
    directory = args.corpus.resolve()
    results = args.results.resolve()
    results.parent.mkdir(parents=True, exist_ok=True)
    members = sorted(p.name for p in (directory / "mixed").iterdir())
    homebrew = Path("/opt/homebrew/bin")
    raw = directory / "mixed.bin"
    # stream oracle は同じ256 MiBの連結本文を使う。tar の header は参照入力に含めない。
    commands = {
        "stream-gz": ["/usr/bin/gzip", "-c", "-6", str(raw)],
        "stream-bz2": ["/usr/bin/bzip2", "-c", "-9", str(raw)],
        "stream-xz": [str(homebrew / "xz"), "-c", "-6", "-T12", str(raw)],
        "stream-zst": [str(homebrew / "zstd"), "-c", "-3", "-T12", str(raw)],
        "stream-lz": [str(homebrew / "lzip"), "-c", "-6", str(raw)],
        "stream-lzma": [str(homebrew / "xz"), "--format=lzma", "-c", "-6", str(raw)],
        "stream-lz4": [str(homebrew / "lz4"), "-c", "-B7", str(raw)],
        "stream-br": [str(homebrew / "brotli"), "-c", "-q", "2", str(raw)],
    }
    selected = args.cases.split(",") if args.cases else CASES
    for case in selected:
        for repeat in range(args.repeats):
            output = directory / ("reference.lzh" if case.startswith("lha-") else "reference.archive")
            output.unlink(missing_ok=True)
            stdout_archive = False
            staged = None
            if case == "stream-Z":
                # BSD compress -cは/dev/stdoutを再openする。sandbox内の通常fileへ出す。
                staged = directory / "reference-compress-input"
                output = directory / "reference-compress-input.Z"
                output.unlink(missing_ok=True)
                shutil.copyfile(raw, staged)  # copyは計時外、元corpusは削除させない。
                command = ["/usr/bin/compress", "-f", "-b", "16", str(staged)]
            elif case in commands:
                command = commands[case]
                stdout_archive = True
            elif case == "tar":
                command = ["/usr/bin/tar", "-cf", str(output)] + members
            elif case.startswith("tar."):
                # 同じ入力本文での stream 参照を上の行に記録する。
                continue
            elif case.startswith("zip-"):
                method = case[4:]
                if method == "zstd":
                    continue  # 7zz の ZIP Zstd encoder はない。stream-zst が codec の参照。
                mm = {"stored": "Copy", "deflate": "Deflate", "bzip2": "BZip2", "lzma": "LZMA",
                      "xz": "xz", "ppmd": "PPMd"}[method]
                level = "9" if method == "bzip2" else "6"
                command = [str(homebrew / "7zz"), "a", "-tzip", "-mm=" + mm, "-mx=" + level, "-mmt=12", str(output)] + members
            elif case.startswith("7z-"):
                parts = case.split("-")
                mm = {"lzma2": "LZMA2", "lzma": "LZMA", "deflate": "Deflate", "bzip2": "BZip2",
                      "ppmd": "PPMd", "copy": "Copy"}[parts[1]]
                level = "9" if parts[1] == "bzip2" else "6"
                methods = ["-m0=Delta:4", "-m1=" + mm] if "filter" in parts else ["-m0=" + mm]
                command = [str(homebrew / "7zz"), "a", "-t7z", "-mx=" + level, "-mmt=12",
                           "-ms=16m" if "solid" in parts else "-ms=off"] + methods + [str(output)] + members
            elif case.startswith("lha-"):
                command = [str(Path.home() / ".local/bin/lha-unix"), "ao" + case[-1] + "q", str(output)] + members
            else:
                raise ValueError(case)
            log = results.parent / f"reference-{case}-{repeat}.log"
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.monotonic()
            with log.open("wb") as messages, (output.open("wb") if stdout_archive else open(os.devnull, "wb")) as out:
                process = subprocess.run(command, cwd=directory / "mixed", stdout=out if stdout_archive else messages,
                                         stderr=messages, env=dict(os.environ, LC_ALL="C", COPYFILE_DISABLE="1"))
            wall = time.monotonic() - start
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            row = {"path": case, "label": "reference", "command": command, "wall_s": wall,
                   "cpu_s": after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
                   "input_bytes": 256 << 20, "output_bytes": output.stat().st_size if output.exists() else 0,
                   "status": process.returncode}
            with results.open("a") as out:
                out.write(json.dumps(row, sort_keys=True) + "\n")
            print(json.dumps(row), flush=True)
            output.unlink(missing_ok=True)
            if staged is not None:
                staged.unlink(missing_ok=True)
            if process.returncode:
                raise RuntimeError(f"Reference failed; see {log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["corpus", "measure", "report", "references"])
    parser.add_argument("--corpus", type=Path, default=ROOT / ".build/multicore/corpus.noindex")
    parser.add_argument("--base", type=Path, default=ROOT / ".build-base/multicore-release/out/Products/Release/gyoshuku-multicore")
    parser.add_argument("--round1", type=Path)
    parser.add_argument("--profile", choices=["round2", "round3", "round3b"], default="round2")
    parser.add_argument("--threads")
    parser.add_argument("--mode", choices=["item", "batch"], default="item")
    parser.add_argument("--new", type=Path, default=ROOT / ".build/multicore-release/out/Products/Release/gyoshuku-multicore")
    parser.add_argument("--results", type=Path)
    parser.add_argument("--cases")
    parser.add_argument("--workloads")
    parser.add_argument("--repeats", type=int, default=5)
    args = parser.parse_args()
    if args.results is None:
        args.results = ROOT / {"round2": ".build/multicore/round2.jsonl", "round3": ".build/multicore/round3.r3.jsonl", "round3b": ".build/multicore/round3b.r3b.jsonl"}[args.profile]
        if args.mode == "batch":
            args.results = args.results.with_name(args.results.stem + ".batch.jsonl")
    if args.workloads is None:
        args.workloads = {"round2": "single,small,lha-mixed,corpus", "round3": "tree,single,single16r,small,lha-mixed,corpus", "round3b": "corpus,lha-mixed,single,tree,small"}[args.profile]
    if args.repeats < 5:
        parser.error("best-of-5 以上で測定する")
    if args.operation == "corpus":
        if not (args.corpus / "manifest.json").exists():
            corpus(args.corpus)
        regression_corpora(args.corpus)
    elif args.operation == "measure":
        measure(args)
    elif args.operation == "report":
        report(args)
    else:
        references(args)


if __name__ == "__main__":
    main()
