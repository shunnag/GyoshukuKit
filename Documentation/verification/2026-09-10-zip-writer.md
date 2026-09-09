# 検証: ZIP / ZIP64 の新規作成 (2026-09-10)

## 対象と環境

段階 1 の前半。既存書庫の更新・暗号化・他形式は実装しない。
最初に本リポジトリの design.md を読み、KaitoKit の ArchiveReader、
DeflateDecompressor、ArArchiveBuilder と KaitoFinder 設計 §7・ditto ZIP64 検証を参照した。
両参照リポジトリは変更していない。KaitoKit は `db2c5d0`。

- macOS 27.0 (26A428)、Apple Silicon arm64
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、Swift 6 言語モード、deployment target macOS 26
- `/usr/bin/unzip`: Apple 版 Info-ZIP UnZip 6.00 (2009-04-20)
- `/opt/homebrew/bin/7zz`: 7-Zip 26.03 arm64 (2026-09-03)
- `/usr/bin/ditto`: この OS に同梱のもの
- `/usr/bin/tar`: bsdtar 3.5.3 / libarchive 3.7.4
- `/usr/bin/python3`: 独立した標準 ZIP の作成だけに使用
- `/usr/bin/cmp`: 大きい展開物の byte 比較

製品は純 Swift、`private import zlib` と `.linkedLibrary("z")` だけを使用する。
shim target、Apple Compression、system libarchive のリンク・dlopen は無い。
外部プロセスの bsdtar は検証 oracle であり、製品の実装依存ではない。
`nm -u libGyoshukuKit.a` でも `_crc32` / `_deflate` / `_deflateEnd` /
`_deflateInit2_` を確認した。

## API と失敗時の契約

```swift
ArchiveWriter.create(url: URL, format: ArchiveFormat = .zip,
                     options: WriterOptions = WriterOptions()) throws -> ArchiveWriter
writer.add(contentsOf: URL, as: String) throws
writer.addDirectory(String) throws
writer.add(data: Data, as: String, modificationDate: Date? = nil,
           permissions: UInt16? = nil) throws
writer.finish() throws
```

`ArchiveFormat.zip`、`CompressionMethod.stored / .deflate`、`WriterOptions: Sendable`。
設定は method、level (既定 6、0...9)、拡張子ヒューリスティック (既定 true)、
owner IDs (既定 false)、macOS metadata (既定 false)。owner IDs は disk source に
0x7875 で保存し、macOS metadata を true にすると明示的に未対応エラーを返す。

writer は thread-safe / Sendable にせず、呼出側が直列化する。O_EXCL で作成し、
既存ファイルを壊さない。ディレクトリは再帰追加、symlink は lstat/readlink で
リンク自体を保存する。通常ファイルは O_NOFOLLOW で開いて inode と変更を検査する。
entry のデータは 256 KiB 単位、メタデータは entry 数と名前長に比例する。

`finish()` 成功で完成し、成功後の再呼出しは no-op。add/finish の失敗は terminal。
部分ファイルは呼出側が削除する。deinit は閉じるだけで完成扱いにしない。
相対パスの検証、NFC 重複、file/子の衝突も検証する。Unix timestamp は秒へ切り捨て、
符号付き 32 bit の範囲外を拒否する。DOS はローカル時刻へ変換・範囲を clamp する。

## 参照実装との差分結果

完成した各 fixture に unzip `-t` / `-l`、7zz `t` / `l`、ditto `-x -k`、
bsdtar `-tf` を実行した。小さい fixture と 65,536 entry の書庫では KaitoKit の
全 entry の名前・kind・内容・mtime・permissions・CRC・非圧縮サイズを比較し、
ditto の全ファイル内容と symlink target / directory を検査した。
4 GiB 超では KaitoKit を stream で全 byte と CRC を検査し、ditto 展開後は cmp した。
必要ツールの欠落は skip にせず失敗する。

| fixture | unzip | 7zz | ditto | KaitoKit |
|---|---|---|---|---|
| 22 byte の空 ZIP | exit 1、空書庫警告 | exit 0 | exit 1、下記制限 | 0 entry |
| small stored / deflate | 検査・一覧 OK | 警告なし | byte 一致 | 全属性一致 |
| zero byte | stored、payload なし | 警告なし | byte 一致 | CRC / size 0 |
| directory tree / 0644 / 0755 / symlink | OK | 警告なし | 全内容とリンク一致 | 全属性一致 |
| 日本語 NFC 名 | CRC OK、表示に下記制限 | 正しい名前 | 正しい名前と内容 | 生名前 byte / 全属性一致 |
| levels 0 / 1 / 6 / 9、owner opt-in、heuristic | OK | 警告なし | byte 一致 | 全属性一致 |
| dangling symlink / sliced Data | OK | 警告なし | リンク・内容一致 | 全属性一致 |
| 4 GiB + 1 MiB | 真のサイズ、CRC OK | 真のサイズ、警告なし | cmp exit 0 | 全 byte / CRC 一致 |
| 65,536 empty entries | 全件を一覧・検査 | 65,536 件、警告なし | 全件一致 | 全件全属性一致 |

全 fixture の bsdtar `-tf` も exit 0。実行ログと小さい書庫は
`build/verification/<fixture>/` に保存する。失敗系テストの未完成ファイルは
有効な ZIP として検証する対象にはしない。

### 4 GiB の実測

ゼロの繰り返しを `truncate` で入力ファイルにし、writer は sparse 検出せず全 byte を
読み、level 6 で圧縮した。入力の実サイズは **4,296,015,872**、compressed payload は
**4,175,523**、書庫全体は **4,175,693** bytes、CRC は **0xC6A48B28**。
巨大な入力・展開物は成功後削除し、小さい ZIP とログを残す。

```text
unzip -t: testing: zeros.bin OK
No errors detected in compressed data ...
unzip -l: 4296015872  11-15-2023 07:13   zeros.bin
7zz t: Everything is Ok
Size:       4296015872
Compressed: 4175693
7zz l: 4296015872      4175523  zeros.bin
ditto -x -k: exit 0 (出力なし)
cmp: exit 0 (出力なし)
KAITO ZIP64 size=4296015872 compressed=4175523 CRC=c6a48b28; every byte verified
```

65,536 件の書庫は **7,864,418** bytes。ZIP64 EOCD と locator が存在し、通常 EOCD は
count のみ 0xFFFF。CD の size / offset は通常幅の真値のまま。

```text
unzip -l: 0                     65536 files
7zz t: Everything is Ok
Files: 65536
Size:       0
Compressed: 7864418
KAITO ZIP64 count=65536; all names, bytes, dates, permissions and CRCs verified
```

### local ZIP64 の例外と 7-Zip の警告

[PKWARE APPNOTE 4.5.3](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) の
「extra にある値は対応する欄が sentinel」と「local は両サイズを必ず含む」を
合わせ、local ZIP64 は両サイズ欄が 0xFFFFFFFF、0x0001 は 16 data bytes とする。
central は別に組み立て、sentinel の欄だけを uncompressed / compressed / offset /
disk start 順で載せる。単一 volume なので disk start は常に 0 で extra に載らない。

4 GiB fixture の central は uncompressed だけが sentinel、extra は 8 data bytes。
compressed size と local offset は真値の 32 bit。CD 自体の count/size/offset は
収まるので、この fixture の EOCD は通常のものだけでよい。

切り分け実験では、local compressed size を通常幅にして extra に両サイズを置くと
7-Zip は **exit 0 / Everything is Ok と同時に Headers Error 警告**を出した。
local の両欄を sentinel にすると警告が消え、ZIP64 EOCD を足すだけでは消えなかった。
テストは以後、7-Zip の警告文も失敗として扱う。この local 例外を central / EOCD の
全フィールド一括 sentinel 化に流用しない。

圧縮サイズ・local offset・CD size が実際に 4 GiB を超える出力は生成していない。
これらは serializer の各欄を sentinel 直前 / 一致 / 組合せで検査している。

### 既知の実ツール制限と未検証項目

1. **空 ZIP**: 全 byte が Python `zipfile.ZipFile(..., 'w').close()` と一致する。
   unzip は `zipfile is empty` (exit 1)、ditto は `Incorrect pkzip signature` (exit 1)。
   Python の空 ZIP に対する ditto の拒否もテスト内で独立に確認する。
   ダミー entry を足して空書庫を偽装せず、この既知の結果を明示的に検査する。
2. **Apple unzip の日本語表示**: この build の compilation options に Unicode 対応が
   無く、bit 11 の正しい UTF-8 名も表示時に壊す。Python で NFC 名を入れた ZIP と
   `-l` の名前欄が同じになることを比較する。名前そのものは local byte、7zz 一覧、
   ditto のファイル名、KaitoKit で確認。macOS filesystem の NFD と Swift の NFC は
   canonical equivalence で比較し、ZIP の生 byte は NFC と完全一致させる。
3. **Archive Utility**: Computer Use で直接検証を試みたが、
   `Computer Use was not approved to use Archive Utility` で使用を許可されなかった。
   ditto の成功を GUI アプリの直接検証とは扱わない。
4. **Windows Explorer**: この macOS 環境では直接検証できていない。
5. **macOS 26 実機**: deployment target は 26 だが、実行検証は上記 macOS 27。

したがって「全 reader が全 fixture を無条件で受け入れた」とは報告しない。
CLI と KaitoKit の確認済み範囲、および空書庫・日本語表示・GUI の制限を区別する。

## テスト名

`ZipWriterTests`:

- `testEmptyArchive`
- `testSingleSmallFileStoredAndDeflated`
- `testZeroByteFileUsesStoredWithoutPayload`
- `testJapaneseUTF8NFCAndTimestampExtraLengths`
- `testDirectoryTreePermissionsAndSymlink`
- `testCompressionLevelsHeuristicAndOwnerOptIn`
- `testInvalidInputsAndWriterLifecycle`
- `testDOSDateAndTimestampBounds`
- `testRejectsFileDirectoryConflictsAndOutputAsSource`
- `testDanglingSymlinkAndSlicedDataRoundTrip`

`Zip64WriterTests`:

- `testZIP64UncompressedSizeAbove4GiBRoundTrips`
- `testZIP64MoreThan65535EntriesRoundTrips`
- `testZIP64PerFieldSentinelsAtExactBoundaries`

## 再現コマンドと build / test 出力

指定どおりの `swift build 2>&1 | tail -20` と `swift test 2>&1 | tail -40` も実行したが、
この managed sandbox ではユーザーの SwiftPM cache と Clang module cache に書けず、
両方とも manifest 評価で exit 1。ソースのコンパイル以前の環境制限である。
全出力は `build/requested-swift-build.log` / `build/requested-swift-test.log`。

```text
warning: /Users/nagash/Library/org.swift.swiftpm/configuration is not accessible or not writable ...
warning: /Users/nagash/Library/org.swift.swiftpm/security is not accessible or not writable ...
warning: /Users/nagash/Library/Caches/org.swift.swiftpm is not accessible or not writable ...
error: 'gyoshukukit': Invalid manifest ...
error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output:
... Operation not permitted
```

キャッシュを許可された作業ディレクトリへ移す次のコマンドでは build / test とも
exit 0、コンパイラ・SwiftPM の警告なし。`--disable-sandbox` は SwiftPM の子プロセス用
設定であり、外側の managed sandbox の権限は変えていない。

```sh
cd /Users/nagash/GyoshukuKit
mkdir -p build/cache build/config build/security build/clang
CLANG_MODULE_CACHE_PATH="$PWD/build/clang" swift build --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  > build/swift-build.log 2>&1
CLANG_MODULE_CACHE_PATH="$PWD/build/clang" swift test --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  > build/swift-test.log 2>&1
tail -20 build/swift-build.log
tail -40 build/swift-test.log
```

13 XCTest、0 failures、約 82 秒。末尾の Swift Testing の `0 tests` は別 runner の出力で、
XCTest の 13 件が未実行という意味ではない。以下は成功した最終実行の出力末尾。

### swift build

```text
Building for debugging...
[Planning deferred tasks]
[2 / 7] GyoshukuKit
[6 / 10] GyoshukuKit
[8 / 11] GyoshukuKit
Build complete! (0.65秒)
```

### swift test

```text
REFERENCE japanese/python-unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE japanese/7zz-t: exit 0; Size:       16 | Compressed: 185
REFERENCE japanese/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE japanese/ditto-x: exit 0;
REFERENCE japanese/bsdtar-t: exit 0; 日本語/ガラス.txt
Test Case '-[GyoshukuKitTests.ZipWriterTests testJapaneseUTF8NFCAndTimestampExtraLengths]' passed (0.626 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' started.
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' passed (0.004 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testSingleSmallFileStoredAndDeflated]' started.
REFERENCE single-stored/unzip-t: exit 0;     testing: small.txt                OK | No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/single-stored/archive.zip.
REFERENCE single-stored/unzip-l: exit 0; ---------                     ------- |         9                     1 file
REFERENCE single-stored/7zz-t: exit 0; Size:       9 | Compressed: 147
REFERENCE single-stored/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE single-stored/ditto-x: exit 0;
REFERENCE single-stored/bsdtar-t: exit 0; small.txt
REFERENCE single-deflate/unzip-t: exit 0;     testing: small.txt                OK | No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/single-deflate/archive.zip.
REFERENCE single-deflate/unzip-l: exit 0; ---------                     ------- |         9                     1 file
REFERENCE single-deflate/7zz-t: exit 0; Size:       9 | Compressed: 149
REFERENCE single-deflate/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE single-deflate/ditto-x: exit 0;
REFERENCE single-deflate/bsdtar-t: exit 0; small.txt
Test Case '-[GyoshukuKitTests.ZipWriterTests testSingleSmallFileStoredAndDeflated]' passed (0.915 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' started.
REFERENCE zero/unzip-t: exit 0;     testing: zero                     OK | No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/zero/archive.zip.
REFERENCE zero/unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE zero/7zz-t: exit 0; Size:       0 | Compressed: 128
REFERENCE zero/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE zero/ditto-x: exit 0;
REFERENCE zero/bsdtar-t: exit 0; zero
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' passed (0.472 seconds).
Test Suite 'ZipWriterTests' passed at 2026-09-10 07:41:45.588.
	 Executed 10 tests, with 0 failures (0 unexpected) in 6.363 (6.366) seconds
Test Suite 'GyoshukuKitTests.xctest' passed at 2026-09-10 07:41:45.588.
	 Executed 13 tests, with 0 failures (0 unexpected) in 81.825 (81.829) seconds
Test Suite 'All tests' passed at 2026-09-10 07:41:45.588.
	 Executed 13 tests, with 0 failures (0 unexpected) in 81.825 (81.829) seconds
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

> **Verification: ZIP/ZIP64 creation (2026-09-10)**
>
> This is stage 1, part one: creation only. The project design was read first,
> followed by KaitoKit's reader, zlib pointer discipline and clean-room builders,
> and the KaitoFinder ZIP decisions and ditto ZIP64 record. Neither reference
> repository was modified. KaitoKit revision: `db2c5d0`.
>
> **Environment:** macOS 27.0 (26A428), Apple Silicon, Apple Swift 6.4 in Swift 6
> mode, deployment target macOS 26. Reference executables were Apple UnZip 6.00,
> 7-Zip 26.03 arm64, OS-bundled ditto, bsdtar 3.5.3/libarchive 3.7.4, Python 3.9.6
> and cmp. The product itself uses only system zlib through a private Swift import
> and `linkedLibrary("z")`, without a shim, Compression or libarchive. Symbol
> inspection confirmed the expected CRC/deflate APIs. bsdtar is an external oracle.
>
> **API:** `ArchiveWriter.create(url:format:options:)`, `add(contentsOf:as:)`,
> `addDirectory(_:)`, `add(data:as:modificationDate:permissions:)`, and `finish()`.
> The writer is deliberately not thread-safe or Sendable. WriterOptions is
> Sendable, with stored/deflate, level 0–9 (default 6), an enabled-by-default
> extension heuristic and disabled-by-default owner/macOS metadata preservation.
> Disk owner IDs can be saved; macOS metadata opt-in explicitly throws unsupported.
> Output creation is exclusive, directory addition recursive, symlinks use
> lstat/readlink, and regular files use no-follow opens plus identity/change checks.
> Payload I/O uses 256 KiB chunks; metadata scales with names and entry count.
> Successful finish is idempotent; failed operations make the writer unusable and
> leave partial output for caller cleanup. Deinit only closes. Paths, normalized
> duplicates, file/child conflicts and signed-32-bit Unix timestamp ranges are
> validated. DOS times use the local timezone and clamp to their representable range.
>
> **Differential tests:** every completed fixture was tested/listed by unzip and
> 7zz, extracted by ditto and listed by bsdtar. KaitoKit checked every entry's name,
> kind, bytes, mtime, permissions, CRC and uncompressed size. ditto's files, links
> and directories were checked against the inputs. Fixtures cover empty and small
> archives, zero-byte files, stored/deflated contents, directory trees, 0644/0755,
> valid and dangling symlinks, Japanese NFC names, sliced Data, compression levels
> 0/1/6/9, the heuristic and owner opt-in. Missing reference tools fail the tests.
> Incomplete files from deliberate failure tests are not treated as valid archives.
>
> **ZIP64:** a sparse-created zero input was read normally and compressed at level
> 6. Its real size was **4,296,015,872**, compressed payload **4,175,523**, archive
> **4,175,693** bytes and CRC **0xC6A48B28**. unzip/7zz listed the true size and
> passed integrity checks; ditto and cmp exited 0; KaitoKit streamed and checked
> every byte and CRC. The 65,536-entry archive was **7,864,418** bytes; all entries
> passed every metadata/content comparison. Its EOCD uses only count sentinels,
> retaining ordinary-width CD size and offset, plus ZIP64 EOCD and locator.
> Actual output with compressed size, local offset or CD size above 4 GiB was not
> generated; those fields are covered by serializer boundary tests.
>
> **The local ZIP64 exception matters:** APPNOTE 4.5.3, linked above, requires both
> local sizes and corresponding sentinels. Central fields remain independently
> selected. A controlled experiment showed that keeping the local compressed-size
> field at normal width while including both extra values caused 7-Zip to print
> `Headers Error` despite exit 0 and `Everything is Ok`. Both local size sentinels
> removed the warning; merely adding a ZIP64 end record did not. Tests now reject
> warning diagnostics too. The final large-entry central extra contains only the
> 8-byte uncompressed size; the local extra contains both sizes in 16 bytes and
> never an offset. Its ordinary EOCD fields fit, so no ZIP64 end record is needed.
>
> **Known limits:** the valid 22-byte empty ZIP is byte-identical to Python's
> output, but Apple unzip warns with exit 1 and ditto rejects both with
> `Incorrect pkzip signature`, also exit 1. Tests explicitly assert these known
> results instead of inserting dummy entries. Apple unzip lacks Unicode support
> in this build and mangles Japanese display even for independent Python ZIPs.
> Its listing is compared against a Python NFC reference; actual names are checked
> through ZIP bytes, 7zz, ditto and KaitoKit. ZIP bytes must be NFC, while filesystem
> names may be canonically equivalent NFD. Archive Utility direct verification was
> attempted but Computer Use reported that the app was not approved. Windows
> Explorer was not available for direct testing. Runtime testing used macOS 27,
> not a physical macOS 26 installation. No claim is made that every reader accepted
> every fixture without exceptions.
>
> **Build/test:** the literal requested commands failed before source compilation
> because the managed sandbox cannot write the user's SwiftPM/Clang caches.
> Relocating cache/config/security paths inside the workspace, with the commands
> above, gave successful build and **13 XCTest tests, zero failures, about 82 s**,
> without compiler or SwiftPM warnings. SwiftPM's subprocess sandbox flag does not
> change the outer managed permissions. The final Swift Testing `0 tests` line
> belongs to a separate runner; it does not negate the 13 XCTest executions.
> Test names and exact successful output tails are listed above. Full logs and
> small archives remain under `build/`; large input/extracted files are removed
> after successful verification.

## ローカル commit の制限

main 上で `git add` が `.git/index.lock: Operation not permitted` で拒否された。
続く `git commit -F build/commit-message.txt` は `no changes added to commit` で終了した。
ステージング自体ができないため、
変更は **未ステージの作業ツリー** に残る。指定された両 trailer を含む日本語メッセージは
`build/commit-message.txt` に保存した。push は行っていない。

> **Local commit limitation:** `git add` on main was denied with
> `.git/index.lock: Operation not permitted`; the subsequent `git commit -F
> build/commit-message.txt` reported `no changes added to commit`.
> Staging itself was denied, so changes remain **unstaged in the
> working tree**. The Japanese commit message, including both requested trailers,
> is saved at `build/commit-message.txt`. Nothing was pushed.
