#!/usr/bin/env python3
"""実測JSONLを検査し、経路表・wall/CPU表・試験記録を残す。"""
import collections
import csv
import json
from pathlib import Path
import re
import shutil
import sys

sys.dont_write_bytecode = True
from multicore import CASES

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build/multicore"
DEST = ROOT / "Documentation/verification"

FILE_PURPOSES = {
    ".gitignore": "隔離した基準版buildを除外",
    "Sources/GyoshukuKit/API/WriterOptions.swift": "並列化の対象と待ち入力上界を更新",
    "Sources/GyoshukuKit/Compression/EntryCompressionConfiguration.swift": "項目workerの予約・並列数・取消しlatch・spool所有権",
    "Sources/GyoshukuKit/Zip/ZipEntryCompressor.swift": "既存の項目codec状態をcaller/workerごとに分離",
    "Sources/GyoshukuKit/Zip/ZipWriter.swift": "ZIP中項目とbatchを順序付き並列圧縮",
    "Sources/GyoshukuKit/SevenZip/SevenZipWriter.swift": "非solid LZMA/BZip2/PPMdの中folderを並列圧縮",
    "Sources/GyoshukuKit/SevenZip/SevenZipBlockWriter.swift": "solid/filter folderのspoolを順序付き並列圧縮",
    "Sources/GyoshukuKit/LHA/LHAWriter.swift": "中member窓と大member内の既存片並列を切替",
    "Sources/GyoshukuKit/LHA/LHAEntryCompressor.swift": "既存writerで中memberの完成recordをworker内で作成",
    "Sources/GyoshukuKit/Writer/ArchiveWriter.swift": "ZIP batchの圧縮spoolを受け取って出力",
    "Sources/GyoshukuKit/Writer/SourcePrefetchLimiter.swift": "内部prefetch結果に圧縮spoolを保持",
    "Tests/GyoshukuKitTests/Writer/MulticoreWriterTests.swift": "暗号化・filter・順序・メモリ・取消し・LHA fallbackの照合",
    "Tests/GyoshukuKitTests/Probes/MulticoreBenchmarkTests.swift": "opt-inで53経路のwall/CPU/size/SHAを計測",
    "Tests/GyoshukuKitTests/Probes/ZipConcatenatedZstdProbeTests.swift": "ZIP93連結frameのreader受理と大memberのサイズ差を調査",
    "Tests/GyoshukuKitTests/Compression/LZMAWriterConfigurationTests.swift": "項目窓に合わせた待ち入力上界",
    "Tests/GyoshukuKitTests/Compression/PPMd/PPMdWriterOptionsTests.swift": "PPMdモデルを保った並列項目窓の上界",
    "Tests/GyoshukuKitTests/SevenZip/SevenZipCompressionMethodTests.swift": "新規7z folder窓の上界",
    "Tests/GyoshukuKitTests/Zip/ZipAdditionalCompressionWriterTests.swift": "ZIP BZip2/XZの入力待ち上界",
    "Tests/GyoshukuKitTests/Zip/ZipPPMdWriterTests.swift": "PPMdの中項目待ち入力上界",
    "Tests/GyoshukuKitTests/Zip/ZipZstdWriterTests.swift": "Zstdの中項目待ち入力上界",
    "Tests/GyoshukuKitTests/LHA/LHACompressionMethodTests.swift": "LHA中member窓を含む入力上界",
    "Tests/GyoshukuKitTests/LHA/LHAStreamSpliceTests.swift": "中memberの順序待ちと既存逐次bit列の照合",
    "Tests/README.md": "計測gateの登録",
    "Benchmarks/multicore.py": "固定corpus生成・交互5回計測・参照CLI計測",
    "Benchmarks/multicore-report.py": "sample検査と経路表・速度表・試験記録の生成",
    "Benchmarks/README.md": "基準版buildと計測の再実行手順",
    "Documentation/design.md": "予約・入力上界・spool/進捗/取消し契約と実測",
    "Documentation/verification/2026-10-07-writer-multicore.md": "全経路の実測と検証結果",
    "Documentation/verification/2026-10-07-writer-multicore.samples.jsonl": "全library sampleの生データ",
    "Documentation/verification/2026-10-07-writer-multicore.references.jsonl": "参照commandと全sampleの生データ",
    "Documentation/verification/2026-10-07-writer-multicore.zstd-frame-ratio.jsonl": "ZIP Zstd大memberのframe resetサイズとreader照合",
    "Documentation/verification/2026-10-07-writer-multicore.tsv": "throughput・size・coreの集計",
    "Documentation/verification/2026-10-07-writer-multicore.tests.jsonl": "実行したtest名・構成・結果・case時間の記録",
}


def mechanism(path):
    if path.startswith("zip-"):
        method = path[4:]
        if method == "stored":
            return "逐次I/O（batchは並列先読み/CRC）", "同左"
        if method == "deflate":
            return "1 MiB block / 項目間（ZipCryptoは逐次）", "同左"
        if method == "xz":
            return "項目内XZ block（nil levelは16 MiB）", "加えて16 MiB以下の項目間"
        return "一項目の単一stream/frame/model、逐次", "16 MiB以下の項目間、大項目は逐次"
    if path.startswith("7z-"):
        method = path.split("-")[1]
        blocks = "filter" in path or "solid" in path
        if method in ("lzma2", "deflate"):
            old = "folder内blockのみ" if blocks else "block / 項目間"
        else:
            old = "単一folderを逐次"
        if blocks:
            new = "folder間（solid上限/非solid16 MiB以下）、大folderは従来経路"
        elif method in ("lzma2", "deflate", "copy"):
            new = "同左"
        else:
            new = "16 MiB以下のfolder間、大項目は逐次"
        return old, new
    if path.startswith("lha-"):
        return "1 MiB以下のmember間 / 大member内1 MiB片", "加えて1 MiB超〜16 MiBのmember間"
    suffix = path.split("-")[1] if path.startswith("stream-") else path.removeprefix("tar.")
    route = {"gz": "単一gzipの1 MiB Deflate block", "bz2": "独立bzip2 stream（level9は最大4.5 MB）",
             "xz": "単一XZのblock（nilは16 MiB、tarは小memberを4 MiB packing）",
             "zst": "独立Zstd frame（既定4 MiB）", "lz": "独立lzip member（既定24 MiB）",
             "lzma": "LZMA_Alone単一stream、逐次", "lz4": "単一frameの独立4 MiB block",
             "br": "Brotli単一stream、逐次", "Z": "LZW単一stream、逐次", "tar": "逐次I/O"}[suffix]
    return route, "同左"


def cases(log):
    text = (WORK / log).read_text()
    return re.findall(r"Test Case '-\[GyoshukuKitTests\.(\w+) (\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)", text)


def run_summary(log):
    source = (WORK / log).read_text()
    summary = re.findall(r"Executed (\d+) tests?, with (\d+) failures.*? in [\d.]+ \(([\d.]+)\) seconds", source)
    if not summary:
        raise ValueError(f"試験summaryが無い: {log}")
    count, failures, seconds = summary[-1]
    skipped = sum(result == "skipped" for _, _, result, _ in cases(log))
    return f"{int(count) - int(failures) - skipped}成功/{failures}失敗/{skipped}skip、{seconds}秒"


def main():
    rows = [json.loads(line) for line in (WORK / "results.jsonl").read_text().splitlines()]
    refs = [json.loads(line) for line in (WORK / "references.jsonl").read_text().splitlines()]
    paths = CASES
    observed = {row["path"] for row in rows}
    if observed != set(paths):
        raise ValueError(f"経路の不足/余分: {set(paths) - observed} / {observed - set(paths)}")
    groups = collections.defaultdict(list)
    for row in rows:
        groups[row["path"], row["label"], row["threads"]].append(row)
    best = {}
    for path in paths:
        if len({r["sha256"] for r in rows if r["path"] == path}) != 1:
            raise ValueError(f"byte identity failure: {path}")
        for label in ["base", "new"]:
            for threads in [1, 12]:
                key = path, label, threads
                if len(groups[key]) < 5:
                    raise ValueError(f"5回未満: {key}")
                best[key] = min(groups[key], key=lambda row: row["wall_s"])
    reference = {}
    for row in refs:
        if row["status"] == 0 and (row["path"] not in reference or row["wall_s"] < reference[row["path"]]["wall_s"]):
            reference[row["path"]] = row
    for path, row in reference.items():
        if sum(r["path"] == path and r["status"] == 0 for r in refs) < 5:
            raise ValueError(f"参照の5回未満: {path}")
    required_references = {p for p in paths if not p.startswith("tar.") and p != "zip-zstd"}
    if not required_references.issubset(reference):
        raise ValueError(f"参照経路の不足: {required_references - set(reference)}")
    def rate(row):
        return row["input_bytes"] / 1e6 / row["wall_s"]
    manifest = json.loads((WORK / "corpus/manifest.json").read_text())
    frame_probe = json.loads((WORK / "zstd-frame-ratio.jsonl").read_text())
    if frame_probe["7zz_status"] != 0 or not frame_probe["kaito_accepts"]:
        raise ValueError("大memberのZstd連結frameをreaderが受理しなかった")
    text = ["# writerのmulti-core実測（2026-10-07）", "",
            "基準はf273d346fc8e0743d56604e8c59adb61cedc1828。コーデック内部と凍結fixtureは変更していない。",
            "ZIP 12/14/95/93/98の中項目、7z LZMA/BZip2/PPMdの中folder、solid/filterのfolderを有界窓で並列化した。",
            "LHA LH5/6/7も1 MiB超〜16 MiBのmemberを項目間で並列化し、既存の1 MiB符号化境界を保つ。",
            "", "## 条件", "",
            "ユーザー指定環境はApple M4 Max、16 cores、128 GB。実行環境はmacOS 27.2 (26B5101f)、Apple Swift 6.4。",
            "release、native SwiftPM、`-Xswiftc -enable-testing`。比較対象のSwiftソースは別buildに固定し、baselineに追加したのは同じopt-in harnessだけ。",
            "ZIP/7z/tar/単独streamはそのwriter変更を含む初回buildで計測。LHA中member窓は後から追加し、最終build後にLHAの60 sampleを基準版と交互に取り直した。",
            "他経路の実装・codecはその間変更していない（共有予約関数は同じ計算をhelperへ抽出）。LHA追加後のbinaryで他50経路の速度は再計測していない。",
            "同じcorpus、同じプロセス条件でbase/newを続けて実行し、threads 1/12を各5回。最短wallのsampleに対応するCPU秒を表示する。",
            "他workstreamも同じMacで動くため数値はノイズを含む。CPU秒はuser+system、実効コア数はCPU/wall。MB/sは10^6 byte/s。",
            "wall/CPUはcreate/compress〜finish、SHA-256とサイズ確認は計測外。参照CLIのwall/CPUはプロセス全体。",
            "", f"入力は{manifest['bytes']:,} byte。96×2 MiBの中file＋64 MiBの大file、Swift本文50%・反復binary25%・seeded乱数25%。",
            f"corpus SHA-256: `{manifest['sha256']}`。時刻は各sample前に1700000000へ固定。",
            "ZIP heuristicはfalse。levelはDeflate6/BZip2 9/Zstd3/PPMd6/LHA6、raw LZMA1は6、XZ/LZMA2はApple nil-level経路。",
            "7zのsolidは16 MiB block、`filter`はDelta距離4。BCJ/ARM64/autoはコード上同じfolder経路、BCJ/ARM64も機能テストで照合したが速度を個別には測っていない。",
            "単独streamは同じ順で連結した256 MiB本文。tarのcodec参照もこの本文を使う（tar headerは参照入力に含まない）。",
            "", "参照: 7zz 26.04（26.03はこのMacに無かった）、xz 5.8.4、zstd 1.5.7、lzip1.26、LZ4 1.10.0、Brotli1.2.0、OS gzip/bzip2/compress、LHa for UNIX1.14i-ac20260723。",
            "CLI commandと全sampleは末尾のJSONLに保存した。参照presetはlibraryの自前presetと同一アルゴリズムではない。",
            "参照43条件は各5回成功。OS compress -cの初回1件は/dev/stdoutのsandbox拒否で失敗し、速度集計から除外した。",
            ".Z参照は計時外で作った同一本文のコピーへ通常file出力し、元corpusを保った。失敗行も参照JSONLに残す。",
            "", "## コードの経路表", "", "| 経路 | f273d34でthreads>1が行う仕事 | 変更後 |", "|---|---|---|"]
    for path in paths:
        old, new = mechanism(path)
        text.append(f"| {path} | {old} | {new} |")
    text += ["", "ZIP stored・tar・7z Copyの主処理はI/O。Brotli/LZW/Alone LZMA1は独立substreamへ分割しない。",
             "ZIP BZip2のstream連結は使わない。ZIP XZは一streamのmulti-blockを維持する。",
             "ZIP Zstd連結frameのprobeは7zz 26.04 status=0、KaitoKitも全内容一致。26.03は未確認。",
             f"level {frame_probe['level']}の64 MiB memberは単一frame {frame_probe['single_frame_bytes']:,} byte、{frame_probe['chunk_bytes'] >> 20} MiB連結frame {frame_probe['concatenated_frame_bytes']:,} byte。",
             f"全ZIPのbody差し替えによる計算上のサイズ差は{frame_probe['zip_size_change_percent']:+.4f}%（候補全ZIPの速度は未測定、全levelの比率も未確認）。",
             "このframe分割は+0.3%の上限を超えるため採用せず、ZIPは大memberの単一frameと中memberの項目間並列化を維持する。",
             "", "## wall/CPU（秒）と出力", "",
             "各時間欄はwall / CPU。サイズは基準 / 変更byte。全53経路について、全20sampleのSHA-256が一つであることを確認した。",
             "", "| 経路 | 基準1t | 基準12t | 変更1t | 変更12t | 基準/変更byte |", "|---|---:|---:|---:|---:|---:|"]
    summaries = []
    for path in paths:
        b1, b12, n1, n12 = [best[path, label, threads] for label, threads in [("base", 1), ("base", 12), ("new", 1), ("new", 12)]]
        fields = [f"{r['wall_s']:.3f} / {r['cpu_s']:.3f}" for r in [b1, b12, n1, n12]]
        text.append(f"| {path} | " + " | ".join(fields) + f" | {b12['output_bytes']:,} / {n12['output_bytes']:,} |")
        refpath = "stream-" + path[4:] if path.startswith("tar.") else "stream-zst" if path == "zip-zstd" else path
        ref = reference.get(refpath)
        summaries.append({"path": path, "baseline_1_MB_s": rate(b1), "baseline_12_MB_s": rate(b12),
                          "new_1_MB_s": rate(n1), "new_12_MB_s": rate(n12), "thread_speedup": n1["wall_s"] / n12["wall_s"],
                          "change_speedup": b12["wall_s"] / n12["wall_s"], "effective_cores": n12["cpu_s"] / n12["wall_s"],
                          "baseline_bytes": b12["output_bytes"], "new_bytes": n12["output_bytes"],
                          "reference_path": refpath if ref else "", "reference_MB_s": rate(ref) if ref else "",
                          "reference_bytes": ref["output_bytes"] if ref else ""})
    text += ["", "## throughput / speedup", "",
             "thread倍率=変更1t / 変更12tのwall。変更倍率=基準12t / 変更12t。未変更経路の差は測定ノイズとして扱う。",
             "", "| 経路 | 基準1t MB/s | 基準12t MB/s | 変更1t MB/s | 変更12t MB/s | thread倍率 | 変更倍率 | 実効core | 参照MB/s / byte |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in summaries:
        ref = f"{row['reference_MB_s']:.1f} / {row['reference_bytes']:,}" if row['reference_MB_s'] else "—"
        values = [f"{row[k]:.1f}" for k in ["baseline_1_MB_s", "baseline_12_MB_s", "new_1_MB_s", "new_12_MB_s"]]
        text.append(f"| {row['path']} | " + " | ".join(values) + f" | {row['thread_speedup']:.2f}× | {row['change_speedup']:.2f}× | {row['effective_cores']:.2f} | {ref} |")
    met = [r['path'] for r in summaries if r['effective_cores'] >= 6]
    text += ["", f"実効6core以上は{len(met)}/53測定条件: " + ", ".join(met) + "。並列化可能な圧縮経路のすべてで6core以上という目標は未達。",
             "単一の大きいLZMA1/PPMd/ZIP BZip2/Zstd frameは逐次、Copy/stored/tarはI/Oに制限される。",
             "実効コア数は平均CPU使用量であり、同時worker数や瞬間peakではない。小folder数・直列読取/CRC/書出し・他workstreamのCPU競合でも低下する。",
             "", "## 変更ファイル", "", "| ファイル | 目的 |", "|---|---|"]
    for path, purpose in FILE_PURPOSES.items():
        text.append(f"| {path} | {purpose} |")
    text += [
             "", "## 機能試験", "",
             "全test suiteは実行していない。release受入は26クラス131件、220.720秒、130成功/1失敗（旧PPMd pending=0期待値）。",
             "その期待値を項目窓へ更新した後、MulticoreWriterTests/SevenZipPPMdWriterTests/ZipPPMdWriterTestsを再実行し15/15成功、76.168秒。",
             "初回release対象実行は13件、11成功/1skip/1caseで5assertion失敗、20.383秒。",
             "この新規AES比較はsalt固定漏れを固定saltへ修正して成功。対象はMulticoreWriterTests/LZMAWriterConfigurationTests/PPMdWriterOptionsTests/ZipZstdWriterTests/ZipConcatenatedZstdProbeTests。",
             f"LHA最終実装を含むrelease再検証: {run_summary('release-lha-final.log')}。",
             "", "| クラス | 最終成功case | case時間合計(秒) |", "|---|---:|---:|"]
    tests = collections.defaultdict(dict)
    for log in ["release-acceptance.log", "release-final.log", "release-lha-final.log"]:
        for cls, name, result, secs in cases(log):
            tests[cls][name] = result, float(secs)
    for cls, methods in sorted(tests.items()):
        if any(result != "passed" for result, _ in methods.values()):
            raise ValueError(f"未解決の試験失敗: {cls}")
        text.append(f"| {cls} | {len(methods)} | {sum(secs for _, secs in methods.values()):.3f} |")
    total = sum(len(methods) for methods in tests.values())
    text += ["", f"最終状態で上表のunique {total}件がすべて成功。",
             "debug初回はMulticoreWriterTestsのtestEntryMemoryReservationsKeepSequentialFallback、testQueuedEntriesCancelAndReleaseSpools、testZIPBatchHeuristicAndProgressOrderの3/3成功、3.402秒。",
             f"debug最終再検証は上記3件とtestLHAMediumMembersKeepIdentityProgressAndStoredFallback: {run_summary('debug-final.log')}。",
             "独立release実行: LZMAWriterDefaultOutputTests 1/1成功1.132秒、ZipConcatenatedZstdProbeTests/testIndependentReaders 1/1成功0.079秒。",
             f"ZipConcatenatedZstdProbeTests/testLargeMemberFrameResetSize: {run_summary('zstd-frame-ratio.log')}。",
             "既定gate確認: baseline harness1件skip。初回のZipAdditionalCompressionWriterTests/SevenZipCompressionMethodTests/SevenZipSolidWriterTestsは19成功/benchmark1skip、47.309秒。",
             "計測用MulticoreBenchmarkTests/testWriterMatrixは最終集計1060 sample（53経路×2版×2threads×5回）。LHA再build前の60 sampleは置き換え、実行数は計1120回。",
             "lzma-writers、lha-methods、sevenzip-edit、zip-modernの凍結fixture照合を対象クラスで実施。fixtureは書き換えていない。",
             "", "## メモリ・進捗・残る制約", "",
             "予約とmaximumPendingInputBytesは[design.md](../design.md)のwriter並列化節を参照。一項目入力は16 MiB、圧縮出力はdisk spool。",
             "solid/filterの入力spoolもpendingへ計上し、内部pipelineを1 threadにして入れ子の予約を抑える。大folderの従来経路では内部block並列を保つ。",
             "spoolによる追加disk I/Oと空き容量が必要。file cacheとallocator管理領域はcodecの予約に含まない。codecモデル/辞書を縮小しない。",
             "進捗と暗号化乱数の順序は呼出側に置き、取消しをworkerのread/writeへ伝え、abortでworker/spoolを解放する。",
             "計測は上記corpus/既定level/solid16 MiB/Delta4のみ。全level、他corpus、26.03そのもの、BCJ/ARM64別の速度は未測定。",
             "PPMd/Zstd/LZMAのSources配下は無変更。public API追加なし。コミットせずworktreeに残した。",
             "", "## 生データと再実行", "",
             "[全sample JSONL](2026-10-07-writer-multicore.samples.jsonl)、[参照JSONL](2026-10-07-writer-multicore.references.jsonl)、[集計TSV](2026-10-07-writer-multicore.tsv)、[test名・構成・結果](2026-10-07-writer-multicore.tests.jsonl)。",
             "`Benchmarks/multicore.py measure` / `references`と`Benchmarks/multicore-report.py`で再実行・集計できる。"]
    DEST.mkdir(parents=True, exist_ok=True)
    (DEST / "2026-10-07-writer-multicore.md").write_text("\n".join(text) + "\n")
    for source, suffix in [("results.jsonl", "samples.jsonl"), ("references.jsonl", "references.jsonl"),
                           ("zstd-frame-ratio.jsonl", "zstd-frame-ratio.jsonl")]:
        shutil.copyfile(WORK / source, DEST / ("2026-10-07-writer-multicore." + suffix))
    test_runs = [("release-acceptance.log", "release"), ("release-final.log", "release"),
                 ("release-lha-final.log", "release"), ("release-targeted.log", "release"),
                 ("frozen-lzma.log", "release"), ("zstd-concat.log", "release"),
                 ("zstd-frame-ratio.log", "release"), ("../new-build.log", "release"),
                 ("debug-targeted.log", "debug"), ("debug-final.log", "debug")]
    with (DEST / "2026-10-07-writer-multicore.tests.jsonl").open("w") as out:
        for log, configuration in test_runs:
            for cls, name, result, seconds in cases(log):
                out.write(json.dumps({"run": log, "configuration": configuration, "class": cls,
                                      "method": name, "result": result, "seconds": float(seconds)}, sort_keys=True) + "\n")
    with (DEST / "2026-10-07-writer-multicore.tsv").open("w") as out:
        writer = csv.DictWriter(out, fieldnames=list(summaries[0]), delimiter="\t")
        writer.writeheader(); writer.writerows(summaries)
    print(f"{len(rows)} samples; 53 paths; byte-identical; >=6 cores: {len(met)}")


if __name__ == "__main__":
    main()
