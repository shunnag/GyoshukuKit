# Write-throughput benchmark

PPMd の encoder 単独で旧 commit と同一 flags を比較する手順は [PPMd/README.md](PPMd/README.md) を参照。

macOS 26+、Swift 6、Python 3 が必要です。独立した SwiftPM package なので、root の
products / targets / `swift test` は変えません。repository root から実行します。
`../` の GyoshukuKit に依存する実行 package なので `Tests/` の外に置きます（KaitoKit の
`Tests/Measurement/` は package ではなく script の directory です）。試験の構成と、`swift test` の中の
opt-in の計測（`GYOSHUKU_*`）は [Tests/README.md](../Tests/README.md) にあります。

```sh
Benchmarks/make-corpora.sh /tmp/gyoshuku-corpora
Benchmarks/run.sh /tmp/gyoshuku-corpora
Benchmarks/run.sh /tmp/gyoshuku-corpora 'zip,tgz,tbz,txz,7z' 'text,small' --threads 4 --references
```

`make-corpora.sh` は新規または空の directory に以下を作ります。

| 選択名 | 入力 | 生成条件 |
|---|---|---|
| `text` | `text256.txt` | 256 MiB。`/usr/share/dict/words` から空白区切りで標本化、seed 20260924 |
| `random` | `random256.bin` | 256 MiB。Python MT19937、seed 20260925、1 MiB ごとの `getrandbits` を little endian に変換 |
| `headers` | `headers/` | `xcrun --sdk macosx --show-sdk-path` の `usr/include` をコピー。symlink は実体化 |
| `small` | `small/` | 50,000 files、各 1,024〜4,096 byte の単語列、seed 20260926 |

`WORDS_FILE` / `SDKROOT` で辞書 / SDK を指定できます。SDK の `usr/include` がなければ
理由を表示して headers を skip します。生成物の時刻と mode は固定し、`manifest.json` に
Python version、seed、辞書の SHA-256、SDK path、corpus ごとの件数・byte 数・digest を保存します。
corpus digest は名前順の各 file について、root 相対名の UTF-8 byte 長（UInt64 LE）、名前、
file size（UInt64 LE）、内容を順に SHA-256 へ渡した値です。同じ Python・辞書・SDK で再生成し、
digest を照合してください。SDK の版によって headers の件数とサイズは変わります。
過去の一時 harness と同じ種別の入力ですが、過去の corpus の byte 列を再現するものではありません。

`run.sh` は release build 後、指定した形式 × corpus をそれぞれ1回実行します。
形式と corpus は引用した空白区切り、または comma 区切りで指定できます。省略時は全形式・全 corpus。
`/usr/bin/time -l` の wall / user 秒、peak RSS（macOS の byte 値を MiB へ換算）、出力 byte 数、
thread 設定を TSV で表示します。コマンド、標準出力、生の time 出力、corpus manifest、
`results.tsv` は `Benchmarks/.build/results/run.XXXXXX/` に残し、成功した書庫は測定ごとに削除します。
失敗時は非ゼロで終了し、ログと残った出力を保持します。

`--mode recursive|items|batch` は GyoshukuKit の追加経路を選ぶ。既定の recursive は directory を
そのまま writer に渡す。items と batch は同じ名前順の前順走査（計時に含む）で項目列を作り、
items は項目別 API、batch は一回の `add(_:events:)` を使う。`--progress` は byte 進捗を観測し、
finish の前に `finishAdditions` を呼ぶ。directory の日時は現在時刻なので、この bench の mode 間の
比較では書庫 byte の一致を要求しない。`make-corpora.sh` の small は一つの directory に 50,000 file を平らに置きます。

`--references` は選択した `zip` / `txz` / `7z` に対して、PATH 上にある
`zip -r -6` / `tar | xz -6 -T0` / `7zz a -mx6` を追加します。欠けたツールは理由付きで skip。
`tar+xz` は tar 作成も計時し、RSS は `/usr/bin/time` の子プロセス群の最大値です
（同時使用メモリの合計ではありません）。reference の thread 数は zip が1、xz / 7zz が自動です。
7zz の solid 圧縮と writer の non-solid 圧縮など、既定設定の違いも結果に含まれます。
比較時は同じマシン・入力を使い、他の build / test と同時に実行せず、必要に応じて繰り返してください。

単独実行もできます。

```sh
swift build -c release --package-path Benchmarks
bin_dir=$(swift build -c release --package-path Benchmarks --show-bin-path)
"$bin_dir/gyoshuku-bench" zip /tmp/new-output.zip /tmp/gyoshuku-corpora/text256.txt --level 6 --threads 8
```

`gyoshuku-bench <zip|tar|tgz|tbz|txz|7z|lha> <output> <source>... [--level N] [--threads N]`
は source の basename で追加し、directory は名前順に再帰します。出力は入力の外にある新規 file に限ります。
`--level` は元の harness と同じ `deflateLevel`（0...9、既定6）で、ZIP / tar.gz に適用します。
bzip2 は library 既定の9、XZ / 7z / LHA は library 固有の設定です。
tar.xz は 4 MiB 以下の member を最大 4 MiB の block に詰め、4 MiB を越える member は header 群と
本文を分けて、本文と大きな header 群を最大 16 MiB の片にします。この配置は 0.6.0 からなので、
0.6.0 より前の tar.xz の結果とはサイズ・時間をそのまま比べないでください。
`--threads` は `compressionThreads`（1...64）へ渡し、省略時は nil のまま library に委ねます。
表示する `threads` は圧縮の並列数の設定です。tar.xzは2以上で64 KiB以下のblockを枠に数えず、
未出力blockを合計 `2 × threads + 1` まで許すため、同時に動くencoderの総数とは一致しません。
自動値の表示は library の現行規則（CPU 数・物理メモリ GiB・8 の最小値、最低1）と揃えています。
非圧縮 tar は常に1です。単独実行の `elapsed_s` は `ContinuousClock` で create から finish までを
測り、runner の wall 秒はプロセス起動・終了も含みます。`--level` / `--threads` は reference には適用しません。

検証記録:
[並列 LZMA2](../Documentation/verification/2026-09-24-parallel-lzma2.md)、
[並列 deflate / bzip2](../Documentation/verification/2026-09-24-parallel-deflate-bzip2.md)（2026-09-24）、
[tar.xz の block の詰め方](../Documentation/verification/2026-09-26-p14-xz-packing.md)（2026-09-26、
親 commit と交互に作った受入比較）、
[batch 追加](../Documentation/verification/2026-09-27-p7g-batch.md)（2026-09-27、三階層の固定 small corpus での
mode 間の受入計測）。


round 1のwriter全経路比較は`MulticoreBenchmarkTests`のrelease XCTest bundleを使いました。
当時の計測手順・参照CLI・全53経路の結果は
[2026-10-07 writer multicore](../Documentation/verification/2026-10-07-writer-multicore.md)のround 1節に保存しています。
現在の`multicore.py measure`は下の独立executableを使います。`references`は同じ256 MiB本文での従来のCLI比較です。
通常のswift testではbenchmark probeはskipされます。

## writer multicore round 2

`multicore.py` の既定は単一10 MiB（7z solidは既定blockSize）、5,000個の1〜4 KiB、従来256 MiB、およびLHA用の10 MiBと128小ファイルの混在。
`GyoshukuMulticore` は公開APIだけを使う独立executableで、timing buildに`-enable-testing`を付けない。
両版を次の同じflagsでbuildする。基準sourceは`git archive f273d34`で作ったものを使い、
新しいBenchmarks/Package.swiftとSources/GyoshukuMulticore/main.swiftだけを同じ場所へコピーする。
他のworktreeには書かない。native buildのexecutableはscratch-path/out/Products/Releaseに出る。

```sh
mkdir -p .build-base/source
git archive f273d34 | tar -x -C .build-base/source
ln -s /Users/nagash/Github/KaitoKit .build-base/KaitoKit
cp Benchmarks/Package.swift .build-base/source/Benchmarks/Package.swift
mkdir -p .build-base/source/Benchmarks/Sources/GyoshukuMulticore
cp Benchmarks/Sources/GyoshukuMulticore/main.swift .build-base/source/Benchmarks/Sources/GyoshukuMulticore/main.swift
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path Benchmarks --scratch-path .build/multicore-release --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path .build-base/source/Benchmarks --scratch-path .build-base/multicore-release --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
python3 Benchmarks/multicore.py corpus
python3 Benchmarks/multicore.py measure --results .build/multicore/round2.jsonl
python3 Benchmarks/multicore.py report --results .build/multicore/round2.jsonl
```

threads=1/12、それぞれbase/newを交互に各5回。pairの先行版も反転し、各群の最短wallを使う。
SHA-256は両版・両threadsで一致を要求し、load average（1/5/15分）は各sampleに記録する。
`report`は必要sample数、hash、new/base <= 1.05を検査し、一つでも不一致なら非ゼロ終了する。
`--workloads single,small`や`--cases zip-zstd`で範囲を指定する。corpusは既存manifestがあれば再生成しない。
`references`は従来どおり256 MiBのCLI計測用。最終結果は同日のverification記録のround 2節を参照。

## writer multicore round 3

`--profile round3 --round1 <executable>`はbase / round1 / newの三版を交互に各5回比較する。
既定はtree、single、single16r、small、lha-mixedをt=1/12、corpusの4方式だけをt=12で測る（810 sample）。
`tree`はseed20261008のSwift本文、100 folder ×（64〜256 KiB text 6 file＋空file＋空subdirectory）。
`single16r`は同じseedの16 MiB乱数file。modeはfile0644 / directory0755、日時は1700000000。
`report`は全版・threadsのSHA-256とsize、全条件new/base <= 1.05、tree/smallのnew/round1 <= 1.05を検査する。
`--threads 12`で追加測定のthread数を絞れる。round 2の既定とraw記録は維持する。

```sh
python3 Benchmarks/multicore.py corpus --profile round3
python3 Benchmarks/multicore.py measure --profile round3 \
  --base .build/r3-builds/base/build/out/Products/Release/gyoshuku-multicore \
  --round1 .build/r3-builds/round1/build/out/Products/Release/gyoshuku-multicore \
  --new .build/r3-builds/new/build/out/Products/Release/gyoshuku-multicore \
  --results .build/multicore/round3.r3.jsonl
python3 Benchmarks/multicore.py report --profile round3 \
  --round1 .build/r3-builds/round1/build/out/Products/Release/gyoshuku-multicore \
  --results .build/multicore/round3.r3.jsonl
```

三版ともround 2と同じrelease flagsを使い、timingには`-enable-testing`を付けない。
base / round1 sourceはworktree内の`git archive f273d34` / `git archive f9d5178`から作り、同じharnessをコピーする。
結果は[検証記録](../Documentation/verification/2026-10-07-writer-multicore.md)のround 3節と`.r3.*`を参照。
