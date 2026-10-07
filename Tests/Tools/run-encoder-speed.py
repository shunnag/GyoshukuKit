#!/usr/bin/env python3
"""同じ DEBUG bundle を再ビルドせず、before / after を対にして計測する。"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import time

CLASSES = ["PPMdEncoderTests", "LZMAEncoderTests", "SevenZipPPMdWriterTests", "ZipPPMdWriterTests",
           "ZstdEncoderTests", "SingleStreamCompressorTests", "LZWStreamEncoderTests", "TarXZLZMALevelTests"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--new", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path(".build/speed/paired"))
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--classes", help="class 名の comma 区切り。省略時は対象の 8 class")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    classes = args.classes.split(",") if args.classes else CLASSES
    selected = ",".join("GyoshukuKitTests." + name for name in classes)

    def pair(round_number):
        results = []
        for variant, bundle in [("baseline", args.baseline), ("new", args.new)]:
            label = f"{variant}-{round_number}"
            env = dict(os.environ, GYOSHUKU_ENCODER_TIMING="1", GYOSHUKU_ENCODER_BENCHMARK_RUN=label)
            # opt-in の規模試験は default suite の計測に混ぜない。
            env.pop("GYOSHUKU_LARGE_ENCODER_TESTS", None)
            start = time.monotonic()
            with (args.output / (label + ".log")).open("w") as log:
                result = subprocess.run(["xcrun", "xctest", "-XCTest", selected, str(bundle)],
                                        stdout=log, stderr=subprocess.STDOUT, env=env)
            seconds = time.monotonic() - start
            row = dict(round=round_number, variant=variant, seconds=seconds, exit_code=result.returncode)
            results.append(row)
            (args.output / (label + ".json")).write_text(json.dumps(row, indent=2) + "\n")
            print(json.dumps(row), flush=True)
            if result.returncode:
                break
        return results

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(pair, range(1, args.rounds + 1)))
    (args.output / "runs.json").write_text(json.dumps(results, indent=2) + "\n")
    if any(row["exit_code"] for pair_results in results for row in pair_results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
