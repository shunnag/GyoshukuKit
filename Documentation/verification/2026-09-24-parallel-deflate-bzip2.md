# M8: ZIP / tar.gz / tar.bz2 の並列圧縮

tar.bz2 の現行設定は [correction 1](#correction-1-bzip2-chunk-を5倍へ拡大) の固定5倍。

M2 `069aaf0` を基準に、`feature/2026-09-24-review-m8` の worktree 内だけを変更した。
`../GyoshukuKit` / `../KaitoKit` は編集していない。commit は作成していない。

## 変更ファイル

| ファイル | 変更 |
|---|---|
| `Sources/GyoshukuKit/OrderedChunkPipeline.swift` | M2 の順序付き pipeline を入力・出力・tag の generic に抽出。完了済み結果も枠を使い、待機は50 ms単位。入力確保前の capacity 待機、継続可能な drain、finish / abandon を提供。worker は writer / FileHandle を保持しない。 |
| `Sources/GyoshukuKit/LZMA2ChunkPipeline.swift` | 既存の LZMA2 encoder / CRC / marker API を保つ薄い adapter。7z / XZ の framing は変更しない。 |
| `Sources/GyoshukuKit/DeflateBlock.swift` | 固定1 MiBの raw deflate。直前入力末尾32 KiBを辞書にし、非終端は SYNC_FLUSH、終端だけ FINISH。block 単位と member 全体の overflow 検査付き上限を実装。 |
| `Sources/GyoshukuKit/ArchiveWriter.swift` | 小さい ZIP member を add 間で並列化。大きい member は固定 block に分割。read / CRC / source 検査は呼出側、local header・offset・AES・size・central entry 確定は順序付き出力側。stored / ZipCrypto の前に drain、finish は CD より前に drain。updater / rewriter も同じ経路を使う。 |
| `Sources/GyoshukuKit/GzipCompressor.swift` | 同じ deflate encoder と pipeline を使用。最後の満杯 block を次の入力まで保持し、余分な終端 block を作らない。従来の header と CRC32 / ISIZE trailer を持つ単一 gzip member。 |
| `Sources/GyoshukuKit/ParallelBzip2Compressor.swift` | 5 × level × 100,000 byte ごとに既存 libbz2 compressor で完全な stream を作り、順に連結。 |
| `Sources/GyoshukuKit/EncryptionPrimitives.swift` | AES の内部 initializer にテスト用 salt 注入を追加。通常は従来どおり SecRandomCopyBytes を使用。 |
| `Sources/GyoshukuKit/TarCompressor.swift` | bzip2 の連結 stream を含む説明へ更新。 |
| `Sources/GyoshukuKit/WriterOptions.swift` | compressionThreads の対象形式、固定 block サイズ、メモリ量を更新。 |
| `README.md` | 並列数、遅延エラー、固定境界、bzip2 連結、メモリの説明を追加。 |
| `Tests/GyoshukuKitTests/DeflateBlockTests.swift` | level 0...9、辞書有無、ランダム入力、flush 上限、ZIP64 算術境界、辞書の利用、gzip の空入力・ちょうど境界・短い write を検証。 |
| `Tests/GyoshukuKitTests/ParallelCompressionLifecycleTests.swift` | 個別 disk add の実並列動作、完了済み結果と入力組立を含む容量制限、add / finish 中の取消し、遅延エラー、ZipCrypto の直列経路を検証。新規の取消し検査は経過時間を合否条件にしない。 |
| `Tests/GyoshukuKitTests/ParallelDeflateBzip2WriterTests.swift` | 1/4/8 thread、3.5 MiB member / 64 KiB override、160個の個別 disk add、stored heuristic・空・directory・symlink・AES の byte 一致。tar.gz / tar.bz2、updater / rewriter、short read、KaitoKit と外部ツールを検証。 |
| `Tests/GyoshukuKitTests/ParallelZIP64BoundaryTests.swift` | 64 KiB の固定ランダム block を反復し、非圧縮長 < 4 GiB かつ圧縮長 ≥ ZIP64 sentinel の実書庫を作成。header の後置 patch、KaitoKit の全 byte / CRC、unzip / 7zz を検証。巨大な出力はテスト後に削除。 |

## ZIP64 上限とメモリ

windowBits=15 / memLevel=8 の各 block 長 `n` に対し、従来の zlib compressBound 式
`n + (n >> 12) + (n >> 14) + (n >> 25) + 13` に6 byteを加える。
SYNC_FLUSH は byte 境界への詰め物と空 stored block を追加するため、終端を置き換える増分は最大6 byte。
member の上限は固定境界で分けた各 block の上限の和とし、AES はさらに28 byteを加える。
最後の block にも同じ保守的上限を使う。全加算・乗算で overflow を検査する。
圧縮側はこの block 上限 + 1 byte を一度に確保し、一回の flush を収める。
出力不足による flush 再試行と余分な空 block は発生しない。

参照: [zlib manual](https://zlib.net/manual.html)、
[zlib deflateBound](https://github.com/madler/zlib/blob/v1.3.1/deflate.c)、
[bzip2 manual: concatenated streams](https://www.sourceware.org/bzip2/manual/manual.html)。

deflate / bzip2 は入力を組み立てる前に枠を確保する。未出力 job と組立中 block の合計は
`compressionThreads` 以下。辞書用の32 KiBはコピーし、前 block 全体の backing storage を保持しない。
取消し時は worker の終了を待たずに結果を破棄する。実行中の codec は後で終了するが、出力には触れない。
ZIP の部分出力は従来どおり呼出側が削除する。tar は abort 時に truncate / unlink する。

## コマンド

Swift 6.4、macOS 26 deployment target、隣接する `../KaitoKit` を使用。
通常の `swift build` は sandbox 外の module cache 書込で失敗するため、cache を worktree 内へ移した。

```sh
cd ~/Github/GyoshukuKit-m8
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"

swift build --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security

swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security

swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security \
  --filter 'DeflateBlockTests|ParallelCompressionLifecycleTests|ParallelDeflateBzip2WriterTests|ParallelZIP64BoundaryTests|LZMA2ChunkPipelineTests|ParallelLZMA2WriterTests'

git diff --check
```

外部検証はテスト内で以下を実行し、展開した byte を元データと比較する。
新規テストは既存の候補パス探索を使い、ツールが存在しない場合だけ skip する。

```sh
/usr/bin/unzip -t archive.zip
/usr/bin/unzip -p archive.zip member
/usr/bin/ditto -x -k archive.zip extracted
/opt/homebrew/bin/7zz t archive
/opt/homebrew/bin/7zz t -pGyoshuku-test-2026 archive.zip
/opt/homebrew/bin/7zz x -y -pGyoshuku-test-2026 -oextracted archive.zip
/usr/bin/bsdtar -xf archive -C extracted
/usr/bin/gzip -t archive.tar.gz
/usr/bin/bzip2 -t archive.tar.bz2
```

Python の zlib は gzip member が一つだけで CRC / ISIZE が一致することを検証。
Python bz2 は全 stream の展開結果を連結し、最後以外の入力長が4,500,000 byteであることを検証する。

## 初回M8の検証結果（correction 1より前）

- `swift build`: 成功。ログ `.build/m8-build.log`。
- 全 `swift test`: **283件、失敗0、skip1、513.231秒**。ログ `.build/m8-all-tests.log`。
  skip は既存の `GYOSHUKU_LARGE_TAR_TESTS=1` が必要な4 GiB tar検査。
  この全件実行後に追加した空入力 / 境界検査と圧縮サイズZIP64実書庫検査は、追加の focused 実行で確認した。
- focused: **37件、失敗0、skip0、30.439秒**。ログ `.build/m8-focused-tests.log`。
- 圧縮長ZIP64境界: 入力 **4,293,394,432 byte**、payload **4,295,032,227 byte**。
  KaitoKitで全byteとCRCを照合し、`unzip -t` / `7zz t` も成功した。圧縮長だけがZIP64を必要とし、
  従来のmember全体の上限式では予約を逃す入力である。
- 新規の1/4/8 thread byte一致、固定saltでのAES、個別disk add、KaitoKit、外部ツール、
  workerを停止したままの取消し、遅延エラー、M2 pipeline回帰検査が成功。
- 実測の取消し時間・peak RSS・速度は今回の報告対象に含めず、orchestrator の比較計測に委ねる。

## 初回M8とM2の出力サイズ比較（bzip2は1倍chunk、修正前）

M2 `069aaf0` を `.build/m8-bench/m2-source` に `git archive` で展開し、
そのコピーの manifest だけを隣接 KaitoKit の絶対 path 依存に変更した。
両版の同一クライアントは `.build/m8-bench/{baseline,candidate}/Sources/m8bench/main.swift`。
Release、8 thread、deflate level 6 / 9、bzip2 level 9、既定 heuristic を使用した。
各 corpus を一回の `add(contentsOf:as:)` で追加し、directory は writer の名前順再帰追加を使った。
テストやビルドと並行していたため、所要時間は速度比較として報告しない。

使用した既存 corpus:
`$SP/corpus`。

| corpus | 通常ファイル数 | 入力 byte |
|---|---:|---:|
| text256.txt | 1 | 268,435,605 |
| random256.bin | 1 | 268,435,456 |
| headers | 9,485 | 103,355,973 |
| small | 50,000 | 105,025,301 |

発見した headers corpus は103.36 MBで、依頼文の64 MBとは異なる。下記はこの実在 corpus の結果。

| corpus | ZIP 6 | ZIP 9 | tar.gz 6 | tar.gz 9 | tar.bz2 9 |
|---|---:|---:|---:|---:|---:|
| text256.txt | +0.0020% | +0.0020% | +0.0020% | +0.0021% | +0.0155% |
| random256.bin | +0.0005% | +0.0005% | +0.0005% | +0.0005% | +0.0036% |
| headers | -0.0005% | -0.0007% | -0.0041% | -0.0032% | +0.4096% |
| small | +0.0000% | +0.0000% | +0.0038% | +0.0040% | +2.0870% |

50k small files の bzip2 は **+2.0870%** で、「≈0」の予想より増えた。
指定どおり生のtar byteを900,000 byteで区切っている。
libbz2の内部blockはRLE後のbyte数で決まるため、既存の単一streamとは圧縮境界が異なる。
その違いがtarのpaddingや短いmemberを多く含む入力で影響したと考えられる。

| corpus | 形式 / level | M2 byte | M8 byte |
|---|---|---:|---:|
| text256.txt | zip / 6 | 129,407,505 | 129,410,044 |
| text256.txt | zip / 9 | 129,389,401 | 129,392,049 |
| text256.txt | tgz / 6 | 129,407,494 | 129,410,123 |
| text256.txt | tgz / 9 | 129,389,432 | 129,392,117 |
| text256.txt | tbz / 9 | 102,413,974 | 102,429,798 |
| random256.bin | zip / 6 | 268,517,487 | 268,518,797 |
| random256.bin | zip / 9 | 268,517,487 | 268,518,797 |
| random256.bin | tgz / 6 | 268,517,541 | 268,518,854 |
| random256.bin | tgz / 9 | 268,517,536 | 268,518,849 |
| random256.bin | tbz / 9 | 269,623,893 | 269,633,659 |
| headers | zip / 6 | 23,820,165 | 23,820,040 |
| headers | zip / 9 | 23,698,234 | 23,698,072 |
| headers | tgz / 6 | 16,301,918 | 16,301,251 |
| headers | tgz / 9 | 16,121,049 | 16,120,532 |
| headers | tbz / 9 | 12,673,860 | 12,725,775 |
| small | zip / 6 | 66,456,798 | 66,456,798 |
| small | zip / 9 | 66,456,798 | 66,456,798 |
| small | tgz / 6 | 53,011,177 | 53,013,208 |
| small | tgz / 9 | 52,808,853 | 52,810,972 |
| small | tbz / 9 | 39,985,128 | 40,819,621 |

計測コマンド（helper と結果は worktree の `.build/m8-bench` 内に保存）:

```sh
mkdir -p .build/m8-bench/m2-source
git archive 069aaf0 | tar -xf - -C .build/m8-bench/m2-source

for variant in baseline candidate; do
  swift build -c release -debug-info-format none \
    --package-path ".build/m8-bench/$variant" --disable-sandbox \
    --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" \
    --security-path "$PWD/.build/security"
done

python3 .build/m8-bench/measure_sizes.py > .build/m8-size-comparison.log 2>&1
```

最初のRelease helperビルドはdSYM生成時にsandboxで拒否されたため、
最終ビルドでは `-debug-info-format none` を指定した。両版とも最終ビルドは成功。
helperの呼出し形式は `m8bench <zip|tgz|tbz> <new-output> <deflate-level> <threads> <source>...`。
JSON結果は `.build/m8-bench/sizes.json`、ログは `.build/m8-size-comparison.log`。

## Correction 1: bzip2 chunk を5倍へ拡大

libbz2の内部block上限はRLE1後の長さで決まる。生のtarを900,000 byteごとに切ると、
ゼロの多いheader / paddingが縮んだ分だけ内部blockが満たされない。
今回、独立streamへの入力を **5 × level × 100,000 byte** に変更した。
thread数には依存せず、1/4/8 threadでbyte一致する。

### 倍率の選定

M2が生成した50k corpusのtar.bz2を展開し、同じ143,472,640 byteのtarを固定倍率で区切って
libbz2（Python bz2）に渡した。最大8 jobに制限して順序どおり連結した結果を比較した。
最初に8倍を測定し、その後2〜7倍と9倍を測定した。1倍は前回の実writer結果。

| 倍率 | level 9のchunk byte | 出力 byte | M2比 |
|---:|---:|---:|---:|
| 1 | 900,000 | 40,819,621 | +2.0870% |
| 2 | 1,800,000 | 40,665,294 | +1.7010% |
| 3 | 2,700,000 | 40,475,527 | +1.2265% |
| 4 | 3,600,000 | 40,178,769 | +0.4843% |
| 5 | 4,500,000 | 40,100,407 | +0.2883% |
| 6 | 5,400,000 | 40,185,883 | +0.5021% |
| 7 | 6,300,000 | 40,192,568 | +0.5188% |
| 8 | 7,200,000 | 40,125,081 | +0.3500% |
| 9 | 8,100,000 | 40,011,472 | +0.0659% |

**8倍は+0.3500%で目標を超える。5倍は+0.2883%で、≤+0.3%を満たす最小の固定整数倍率。**
圧縮率は境界位置にも左右され、倍率に対して単調ではない。9倍の+0.0659%より増分は大きいが、
指定された50k corpusの目標を満たしながら、chunk用バッファをより小さくできる5倍を採用した。
5倍の実writer出力と倍率探索結果はSHA-256まで一致した:
`c4ce8c144c3d8ecd1d1b8e6d33275f8aeb3fa1559c5d0c298a4d0aed288c3c4f`。

### 全4 corpusの再測定

M2と修正後writerを同じ既存corpusに対して再実行した。bzip2 level 9、8 thread、Release。
全8書庫に `bzip2 -t` を実行し、成功した。

| corpus | M2 byte | correction 1 byte | M2比 |
|---|---:|---:|---:|
| text256.txt | 102,413,974 | 102,425,462 | +0.0112% |
| random256.bin | 269,623,893 | 269,626,816 | +0.0011% |
| headers | 12,673,860 | 12,728,338 | +0.4298% |
| small | 39,985,128 | 40,100,407 | +0.2883% |

SDK headersは+0.4298%で、1倍の+0.4096%より僅かに増えた。
今回の選定条件は50k corpusで≤+0.3%となる最小倍率であり、全入力で改善する保証はない。
既存headers corpusは9,485ファイル / 103,355,973 byteで、上の初回計測と同じ入力を使用した。
ZIP / tar.gzのpayload生成は今回変更せず、deflate level 6 / 9の初回計測を保持する。
速度・peak RSSはこのサイズ比較の計測対象に含めない。

### メモリと変更点

入力確保前にpipelineの枠を待つ処理を維持した。組立中のchunkと未出力jobの合計は最大で
`compressionThreads` 個で、キューは入力全体の大きさに比例しない。待機中の取消しは50 ms単位。
level 9のchunkは4,500,000 byte。threadごとの入力と出力は約9 MB、libbz2のcodec stateは
約7.6 MBで、合計約**16.6 MB（15.8 MiB）**。allocator等を除く概算で、実測RSSではない。
codec stateの概算は [bzip2 manual §2.5](https://www.sourceware.org/bzip2/manual/manual.html) の
`400k + 8 × block size` に基づく。

| ファイル | correction 1での変更 |
|---|---|
| `Sources/GyoshukuKit/ParallelBzip2Compressor.swift` | 固定chunkを5倍に変更。chunkとlibbz2の内部blockを区別する名前へ整理。 |
| `Sources/GyoshukuKit/WriterOptions.swift` | 固定倍率とlevel 9のthreadごとのメモリ概算を文書化。 |
| `README.md` | 5倍のstream入力、4.5 MBのchunk、16.6 MB/threadの概算を記載。 |
| `Tests/GyoshukuKitTests/ParallelDeflateBzip2WriterTests.swift` | bzip2 fixtureを9 MB超に拡大して3 streamを通す。Pythonの入力境界検査を4,500,000 byteに更新。KaitoKit / bsdtar / 7zz / bzip2の検証と1/4/8 thread一致を維持。 |
| `Tests/GyoshukuKitTests/ParallelCompressionLifecycleTests.swift` | 取消し用入力を実際のchunkサイズに追従させ、add中の取消しがfinish中にすり替わらないよう検査。 |

### コマンドと結果

```sh
cd ~/Github/GyoshukuKit-m8
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"

.build/m8-bench/baseline/.build/out/Products/Release/m8bench tbz \
  .build/m8-bench/correction-1/m2-small.tar.bz2 9 8 \
  $SP/corpus/small
python3 .build/m8-bench/correction-1/screen_multiples.py

swift build -c release -debug-info-format none \
  --package-path .build/m8-bench/candidate --disable-sandbox \
  --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security"
python3 .build/m8-bench/correction-1/measure_sizes.py

swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security \
  --filter 'CompressedTarWriterTests|ParallelDeflateBzip2WriterTests|ParallelCompressionLifecycleTests'
swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security

git diff --check
```

- Release helperビルド: 成功。
- bzip2関連focused: **22件、失敗0、skip1、25.502秒**。
  skipは既存のopt-in 4 GiB tar検査。
- 全suite: **285件、失敗0、skip1、511.071秒**。skipは同じ既存のopt-in 4 GiB tar検査。
- `git diff --check`: 成功。
- ログ: `.build/m8-bzip2-correction-build.log`、`.build/m8-bzip2-correction-focused.log`、
  `.build/m8-bzip2-correction-all-tests.log`、`.build/m8-bzip2-correction-sizes.log`、
  `.build/m8-bzip2-multiples.log`。
- JSON: `.build/m8-bench/correction-1/sizes.json` / `multiple-screen.json`。
- commitは作成していない。以前のM8変更を全て保持した。
