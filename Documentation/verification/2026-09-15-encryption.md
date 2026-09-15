# 検証: パスワード付き ZIP / 7z 出力 (2026-09-15)

## 対象と環境

開始時の GyoshukuKit HEAD は `92ddc19`、作業ツリーは clean。
KaitoKit の内部 `WinZipAES.swift` / `ZipCrypto.swift` / `SevenZipAES.swift` と folder decoder を
読み、公開パラメータに合わせて GyoshukuKit 内に暗号化処理を実装した。
KaitoKit は参照専用で変更していない。確認時の HEAD は `c3a21e7`。
commit は行っていない。Package.swift、依存宣言、キャッシュの回避設定も変更していない。

- macOS 27.0 (26A428)、Apple Silicon arm64
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、Swift 6 言語モード、macOS 26 deployment target
- `/opt/homebrew/bin/7zz`: 7-Zip 26.03 arm64 (2026-09-03)
- `/usr/bin/unzip`: Apple Info-ZIP UnZip 6.00
- workspace-write sandbox。ホーム下の Clang module cache への書込は許可されていない

## 実行結果

| 検査 | 結果 |
|---|---|
| `swift build` | **未完了**。manifest のコンパイル時に sandbox が cache 書込を拒否。exit 1 |
| `swift test` | **未実行**。同じ manifest エラーで停止。exit 1、XCTest の実行件数は得られていない |
| 全製品 source / 全 XCTest source の `swiftc -frontend -parse` | exit 0。構文検査のみ |
| `git diff --check` | exit 0 |
| 指定された禁止語の大文字小文字を区別しない検索 | 一致なし（.git / .build / build を除外） |
| 7zz 製 7z の folder / EncodedHeader の byte 検査 | 実行済み。下記の graph / property を確認 |
| 7zz 製 7z の正誤パスワード / パスワードなしの一覧 | 実行済み。下記の表を参照 |
| GyoshukuKit が生成した暗号書庫の KaitoKit / unzip / 7zz 往復 | **未確認**。追加 XCTest の実行が必要 |
| 300 MiB の往復・spool cleanup・xattr 変更の XCTest | **未確認**。追加 XCTest の実行が必要 |
| 40 MiB の圧縮率の参照計測 | Apple Compression を直接呼んで実行済み。16 MiB reset は一括圧縮比 +1.16% |
| 40 MiB の GyoshukuKit 往復・±5% guard、5 / 16 MiB の byte 一致 | **未確認**。追加 XCTest の実行が必要 |

実行した SwiftPM の確認コマンド（pipeline は `set -o pipefail` を指定）:

```sh
swift build 2>&1 | tail -3
swift test 2>&1 | grep -E 'Executed|error:|failed' | tail -5
```

両方とも次のエラーで、製品 source のコンパイルに到達しなかった。

```text
error: 'gyoshukukit': Invalid manifest
error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output:
/Users/nagash/.cache/clang/ModuleCache: Operation not permitted
error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

これは package の macOS 26 target を変更すべきという診断ではない。manifest を処理する段階の
失敗なので、Package.swift やキャッシュを変更して回避していない。
構文検査は以下で成功したが、型検査・リンク・実行時の正しさを検証したことにはならない。

```sh
swiftc -frontend -parse Sources/GyoshukuKit/*.swift Tests/GyoshukuKitTests/*.swift
git diff --check
```

## 7zz の参照レイアウト

`/private/tmp/gk-encryption-reference-z_42ddyb` に、920 byte の参照テキストを格納する
`header-off.7z` / `header-on.7z` を作った。コマンドは以下の組合せ。

```sh
7zz a -t7z -pfixture-password -mhe=off -mhc=off header-off.7z distinctive-file.txt
7zz a -t7z -pfixture-password -mhe=on  -mhc=off header-on.7z  distinctive-file.txt
```

plain header の folder は AES coder → LZMA2 coder の順だった。bind pair は `(1, 0)`、
unpack sizes は圧縮結果 43 byte、元ファイル 920 byte。AES の packed size は 48 byte。
AES properties は `53 0F` + 16 byte IV。salt なし、NumCyclesPower=19 に対応する。

header 暗号化ありの NextHeader は `17`（EncodedHeader）から始まり、AES-only folder を持つ。
PackPos は 48、header packed size は 144、平文 header size は 130。folder CRC も存在した。
実装と XCTest の folder 検査器はこの decoder 順と真の unpack size の区別を使う。

| 7zz 製入力 | 操作 | exit | 名前の表示 |
|---|---|---:|---|
| header 平文 | `t -pfixture-password` | 0 | — |
| header 平文 | `t -pwrong-password` | 2 | — |
| header 平文 | `l`（password なし） | 0 | 表示された |
| header 暗号化 | `t -pfixture-password` | 0 | — |
| header 暗号化 | `t -pwrong-password` | 2 | — |
| header 暗号化 | `l`（password なし、stdin は EOF） | 255 | 表示されない |

この表は参照ツールが生成した書庫の実測であり、未ビルドの GyoshukuKit 出力の検証結果ではない。

## 追加した XCTest（実行待ち）

[EncryptionTests.swift](../../Tests/GyoshukuKitTests/EncryptionTests.swift) と
[EncryptionTestSupport.swift](../../Tests/GyoshukuKitTests/EncryptionTestSupport.swift) を追加した。
16 個の test method で、以下の条件を組み合わせる。oracle が欠けた場合は skip せず失敗する。

- ZIP AES-256 / ZipCrypto: 0 / 5 / 19 / 20 / 21 byte、1 MiB deflate、1 MiB 超の jpg 名 stored、
  directory / symlink。KaitoKit の全 entry の bytes / kind / isEncrypted、local / central の
  flag / method / version / size / CRC / 0x9901、descriptor がないことを確認する。
- AES の AE-1 / AE-2 境界、CTR の 1 / 15 / 16 / 17 byte 等の分割、ciphertext と HMAC の改変、
  誤パスワード。7zz の test / Method 表示、ZipCrypto は unzip の `-P ... -t` も使う。
- 7z の header 暗号化 on/off、AES-only EncodedHeader、空 stream だけの書庫、coder / bind / unpack size、
  KaitoKit 往復、7zz、UTF-8 と UTF-16LE の両方の生の名前が暗号化 header にないことを確認する。
- 日本語・結合文字・絵文字を含むパスワード、同じ入力に対する salt / IV の独立性。
- 無効な options を作成・更新・再構築で先に拒否し、出力を残さないこと。
- ZipCrypto spool の mode 0600、作成失敗の WriterError.io、読取中の短縮 / 伸長 / mtime / mode
  変更と CancellationError で spool が消え、失敗した writer が再利用できないこと。
- 平文 ZIP と 7zz 製 AES ZIP への AES / ZipCrypto 追加。旧 local header + payload の byte 一致、
  追加・削除・改名の混在時の ciphertext 保存、既存暗号書庫への平文追加。
- 7zz 製暗号 ZIP から AES ZIP / ZipCrypto ZIP / AES 7z（header on/off）への同じパスワードでの
  再構築、暗号 → 平文、平文 → 暗号、異なる入力・出力パスワード、in-place 置換。
- 一つの 300 MiB 入力を ZIP AES / 7z AES / ZipCrypto に渡し、KaitoKit で全 byte を一定量ずつ照合する。
  AES で出力 directory に scratch がないこと、ZipCrypto の spool が終了後に消えることも確認する。
  圧縮可能な入力にして実行時間と保存物を抑え、300 MiB 入力は終了時に削除する。
- 通常のディスク追加の read closure 内で Finder tag xattr を設定し、ctime だけが変わっても成功すること。
  updater の open と commit の間で tag を変更する場合も確認する。
- 固定 seed の 40 MiB 擬似ソースコードの平文 / 暗号 7z 往復と `7zz t`、Apple の一括圧縮との
  packed size 比 ±5% の guard。5 / 16 MiB では short read を混ぜ、圧縮 payload の byte 一致も確認する。

製品側の ctime 比較は全て除外した。dev / ino / size / mode / mtime の検査と、既存の
updater / writer / rewriter の回帰テストは維持している。

## 追補: C API の型と LZMA2 圧縮単位の修正

利用者のビルドで判明した `EncryptionPrimitives.swift` の三項演算子の型不一致を修正した。
`kCCParamError` は Swift で Int、`CCCryptorStatus` は Int32 なので、エラー側を
`Int32(kCCParamError)` とした。ほかの呼出箇所も同じ型の混在を残さないように確認した。

参照した SDK は `MacOSX27.0.sdk` の `CommonCryptor.h` / `CommonCryptoError.h` /
`CommonKeyDerivation.h` / `CommonHMAC.h`、Security の `SecRandom.h` / `SecBase.h`、`MacTypes.h`。
製品・テストを検索した結果、CommonCrypto / Security の呼出しは全て `EncryptionPrimitives.swift` にある。
指定された ZipCryptoEncryptor、SevenZipWriter / Records、ZipRecords、ArchiveWriter / Updater / Rewriter、
二つの Encryption test ファイルも対象として確認した。

| 境界 | SDK と変換 |
|---|---|
| `CCCrypt` / `CCCryptorCreate` / `Update` / `Final` | 戻り値を `CCCryptorStatus` と明示。比較は `CCCryptorStatus(kCCSuccess)` |
| operation / algorithm / options | UInt32 の各 typedef へ `CCOperation` / `CCAlgorithm` / `CCOptions` で変換。CBC の 0 も `CCOptions(0)` |
| `CCKeyDerivationPBKDF` | C の int 戻り値を Int32 と明示。algorithm / PRF は各 UInt32 typedef、rounds は `UInt32(1_000)` |
| `CCHmacInit` / `Update` / `Final` | algorithm は `CCHmacAlgorithm`。Final に status 戻り値はない |
| size_t と size_t * | Swift の長さ引数を明示的に Int へ変換し、出力 byte 数の変数を `Int` と宣言 |
| `SecRandomCopyBytes` | SDK の C int は Int32。OSStatus も SInt32 の別名なので `OSStatus` と宣言し、同じ型の `errSecSuccess` と比較 |
| `CCCryptorRelease` | 数値の引数なし。deinit では戻り値を明示的に破棄 |

LZMA2 は 256 KiB reset を撤回し、`lzmaChunkSize = 16 * 1024 * 1024` とした。
読取・暗号化・書込の `chunkSize = 256 * 1024` は別に保ち、short read でも圧縮境界を早めない。
Apple の辞書は 8 MiB。16 MiB 以下は一回の buffer API 呼出しになるので従来の全体圧縮と同じ
payload / 圧縮率になり、40 MiB では 16 / 16 / 8 MiB の三片を連結する。
主な作業メモリは一ファイルにつき約 16 MiB 入力 + 圧縮出力。encoder / framing の一時領域を含めても
ファイル全体の長さに比例して増えない。README / 設計 / CHANGELOG も同じ説明に更新した。

### 40 MiB fixture の参照計測（実行済み）

Python の ctypes から OS の `libcompression.dylib` の `compression_encode_buffer` を直接呼んだ。
アルゴリズムは SDK `compression.h` の `COMPRESSION_LZMA`（0x306）、scratch は nil。
XCTest と同じ LCG の固定 seed `0x4D595DF4D0F33173` で擬似コードを作り、独立した 512 KiB を
一度繰り返す 1 MiB module を 40 個連結した。ゼロ列ではなく、256 KiB 辞書 reset が失う距離の一致を持つ。
入力は 41,943,040 byte、SHA-256 は
`3e35d865ac8d8d556726dd0723f96d5711841193612780590500433fdaf63eaa`。
XZ framing と重複する LZMA2 終端を除き、最終終端一つを含む packed size を比較した。

| 圧縮単位 | raw LZMA2 byte | 一括圧縮に対する比 |
|---|---:|---:|
| 入力全体 40 MiB | 5,639,568 | 1.000000 |
| 16 MiB（境界 2 箇所） | 5,705,226 | 1.011642（+1.16%） |
| 256 KiB | 12,668,909 | 2.246433（+124.64%） |

この入力は ±5% guard を 16 MiB で満たし、256 KiB への退行を検出できる。
XCTest の参照側も製品 compressor を使わず Compression framework を一度直接呼ぶ。
実書庫の比較には AES の最大 15 byte の zero pad を含む packed size を使う。
上表は encoder の参照計測であり、未ビルドの GyoshukuKit 出力の計測ではない。

### AE 境界と Method 表示

既存の 0 / 5 / 19 / 20 / 21 byte fixture を維持し、local と central の両 0x9901 を個別に parse する
assertion にした。20 byte 未満が AE-1 と実 CRC、20 byte 以上が AE-2 と CRC 0 であることを、
両 header の CRC 欄と合わせて検査する。7zz の listing では全体の文字列だけでなく、
`deflated.txt` / `stored.jpg` の Method 欄を個別に確認する。

別途 7zz 製 fixture を `-mem=AES256` / `-mem=ZipCrypto`、`-mm=Deflate` / `-mm=Copy` で作成し、
`7zz l -slt`（exit 0）で `AES-256 Deflate` / `AES-256 Store` / `ZipCrypto Deflate` / `ZipCrypto Store`
という表示を確認した。参照 fixture は `/private/tmp/gk-followup-methods-vq0ey1in` に置いた。
これは期待する Method 文字列の参照確認であり、GyoshukuKit fixture の XCTest は実行待ち。

### 追補後の実行制限

`swift build` / `swift test` を再実行したが、両方とも同じ module-cache 書込拒否で exit 1。
manifest の段階で停止するため、製品の型検査・リンク・XCTest は実行できなかった。
全 Swift source の `swiftc -frontend -parse` と `git diff --check` は再度成功した。
Package.swift とキャッシュに回避変更を加えていない。既存の未 commit の変更を保持し、
KaitoKit は編集せず、commit も行っていない。

## 残る確認

sandbox 外の通常の環境で `swift build` と `swift test` を実行する必要がある。
現時点では型検査・実ツールとの新規出力の相互運用・40 / 300 MiB の XCTest を成功とは報告しない。
40 MiB の encoder 参照計測と、実書庫の round trip 検証を区別する。
Archive Utility / Windows Explorer の直接検証は今回も行っていない。
