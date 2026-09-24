# M2: 7z / tar.xz の並列 LZMA2

基点は `feature/2026-09-24-review` の M1 (`807c16b`)。M1 の POSIX 読取と ZIP deflater 再利用を維持する。

## ファイル別の変更

| ファイル | 変更 |
| --- | --- |
| `Sources/GyoshukuKit/WriterOptions.swift` | 公開 API に `compressionThreads: Int?` を追加。1...64 を検証し、nil は有効 CPU 数・物理メモリ GiB・8 の最小値（最低1）。thread ごとの約130 MiB と対象形式を文書化。 |
| `Sources/GyoshukuKit/LZMA2ChunkPipeline.swift` | 専用 concurrent DispatchQueue と送信側の QoS を使う順序付き pipeline。未出力の仕事を thread 数までに制限し、50 ms ごとに呼出 Task の取消しを確認する。marker、順序付きエラー、abandon を扱う。worker は入力・結果だけを保持する。 |
| `Sources/GyoshukuKit/SevenZipWriter.swift` | 256 KiB 読取・CRC・source 検査を呼出側に残し、16 MiB chunk を entry 間でも並列化。properties・packed size・AES・終端・entry 確定は出力順に処理。finish で drain、abort で abandon。出力は Data slice を使う。 |
| `Sources/GyoshukuKit/ParallelXZCompressor.swift` | 16 MiB ごとに独立 block を作る単一 XZ stream。block の両 size、LZMA2 filter/property、CRC32、padding、index、footer を生成。空入力は0 record。元データの CRC は worker で計算する。 |
| `Sources/GyoshukuKit/XZCompressor.swift` | 旧 Apple streaming encoder の実装を削除。既存内部テストが使う名前は新実装への typealias として維持する。 |
| `Sources/GyoshukuKit/ArchiveWriter.swift` | 新 XZ compressor と thread 設定を接続。add 後に圧縮失敗が通知され得ることを文書化。内部 factory に chunk size と encoder のテスト用差替えを追加。 |
| `Sources/GyoshukuKit/TarCompressor.swift` | 中止用の `abandon()` を追加。同期 compressor の既定動作は空処理。 |
| `Sources/GyoshukuKit/TarWriter.swift` | abort 時に compressor を abandon してから既存の truncate / unlink を行う。 |
| `Sources/GyoshukuKit/XZLZMA2.swift` | `withUnsafeBytes` で container を解析し、payload だけを1回コピー。結果を Sendable にする。 |
| `Sources/GyoshukuKit/DeflateCompressor.swift` | 既存 CRC helper に raw buffer overload を追加。空 buffer は途中の CRC をそのまま返す。 |
| `Tests/GyoshukuKitTests/LZMA2ChunkPipelineTests.swift` | 完了済み仕事も含む上限、順序、marker、遅延エラー、worker が動作中の abandon / deinit を検証。 |
| `Tests/GyoshukuKitTests/ParallelLZMA2WriterTests.swift` | 1/4/8 thread の7z byte 一致、200個の個別 disk add と空 entry、entry 間の実並列動作、AES、KaitoKit 往復、XZ 外部検証、0 record、取消し・失敗時の削除、option 検証を追加。 |

XZ framing の参照は [XZ file format specification 1.2.1](https://tukaani.org/xz/xz-file-format.txt)。
既存テストのソースは変更していない。

## 検証コマンド

通常の `swift build` は sandbox がユーザー領域の module cache 書込を拒否したため、
既存の検証手順と同じく cache を workspace 内に置いた。隣接する `../KaitoKit` を使用。

```sh
cd /Users/nagash/Github/GyoshukuKit
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"

swift build --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security

swift test --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security \
  --filter 'LZMA2ChunkPipelineTests|ParallelLZMA2WriterTests|XZLZMA2Tests'

swift test --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security

git diff --check
```

ログは `.build/m2-swift-build.log`、`.build/m2-focused-tests.log`、`.build/m2-swift-test.log`。
256 MiB text/random、SDK headers、50k files の速度・peak RSS benchmark は今回実行していない。

## 結果

- `swift build`: 成功。
- focused tests: 20件、失敗0、skip0。
- 全 `swift test`: 264件、失敗0、skip1、493.703秒。skip は既存の
  `GYOSHUKU_LARGE_TAR_TESTS=1` を必要とする4 GiB圧縮tar検査。
- 7z: 3.5 MiB入力を1 MiB境界で分割した結果、および200個の個別disk追加に
  空ファイル・ディレクトリを挟んだ結果が、直列referenceと1/4/8 threadでbyte一致。
  AES（header暗号化の有無を含む）と全内容のKaitoKit往復も成功。
- tar.xz: `xz -t`、`xz -l --robot`、`bsdtar -tf`、`7zz t` とKaitoKitの全内容読取が成功。
  `xz -l` はstream数1、block数4、CRC32を報告。入力0 byteのXZはstream数1、block数0。
- workerを停止させたまま呼出Taskを取り消す検査では、7z addが51.4 ms、tar.xz finishが53.8 msで終了。
  いずれもCancellationError、出力削除、hard linkのtruncateを確認（全テスト実行時）。
- 既存の40 MiB 7z往復・圧縮率、5/16 MiB payload一致、実encoder動作中の取消し、rewrite、ZIP64検査も成功。
- `git diff --check`: 成功。

全件実行後、取消しテストのgateに5秒の退行時timeoutを追加し、focused testsを再実行した。
