# 検証: ZIP / ZIP64 の追加更新 (2026-09-10)

## 対象と環境

段階 1 の後半。開始時の main は `e2ab728770eb53a29bf4e1bf7a0df7d15f594349`。
設計 §3・§5・§6、前半の writer 検証、全 writer source、KaitoFinder の
`2026-09-10-ditto-zip64.md` を先に確認した。
削除・改名は段階 3 へ残す。KaitoKit (`db2c5d0`) と KaitoFinder (`e5d9088`) は変更しない。

- macOS 27.0 (26A428)、Apple Silicon arm64
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、Swift 6 言語モード、deployment target macOS 26
- `/usr/bin/unzip`: Apple 版 Info-ZIP UnZip 6.00
- `/opt/homebrew/bin/7zz`: 7-Zip 26.03 arm64 (2026-09-03)
- `/usr/bin/ditto`、`/usr/bin/zip`、`/usr/bin/tar`: OS 同梱の実ツール
- `/usr/bin/python3`: 公開 byte 表から CP932 / 空 ZIP64 fixture を構築するためだけに使用

製品の依存は KaitoKit と OS の Foundation / Darwin / zlib。
KaitoKit の公開 reader / ByteSource を使い、新しい KaitoKit API は足さない。
system libarchive のリンク・dlopen・C prototype は無い。bsdtar は外部の検証 oracle。

## API と失敗時の契約

```swift
ArchiveUpdater.open(url: URL) throws -> ArchiveUpdater
updater.add(contentsOf: URL, as: String) throws
updater.add(data: Data, as: String, modificationDate: Date? = nil,
            permissions: UInt16? = nil) throws
updater.addDirectory(String) throws
updater.commit() throws
```

thread-safe / Sendable にはしない。呼出側は instance と同一書庫への操作を直列化する。
新 entry は `ArchiveWriter` 自体の add / record-emitting code を共有する。
既定の deflate level 6・拡張子判断・UTF-8 / NFC / bit 11・UNIX mode・timestamp extra・
local header の seek patch も同じ。固定時刻で同じ二つの entry を新規作成した ZIP と、
一つ目を作成して二つ目を追加した ZIP は、**書庫全体が byte 単位で一致**する。

最初の add で同一 volume の `.itemReplacementDirectory` を取得し、
`FileManager.copyItem` で APFS clone を作る。原本を読み取り専用 descriptor で保持し、
clone の旧 CD offset から新 local record を書く。commit は原本の旧 CD を 256 KiB
ずつそのままコピーし、新 CD と合算値の EOCD を書いて truncate・同期する。
旧 local record は位置も byte も不変であり、descriptor を探す処理は無い。
旧 CD の名前・flag・extra・comment・mode を再符号化しない。ZIP コメントも保持する。

`replaceItemAt` の直後に元の POSIX mode を戻し、元に quarantine があれば同じ byte を戻す。
Finder tags・任意 xattr・作成日は Foundation の置換で保持されることも実測した。
この実行では clone の速度を再計測していない。300 MB / 0.002 s は先行実測値である。

add / commit の失敗は terminal。未 commit の clone は失敗時・deinit 時に削除する。
add のみ・add 失敗・競合する updater の commit 拒否で原本の全 byte 不変を確認した。
追加なしの commit と成功後の commit 再呼出しは no-op。成功後の add は拒否する。
open 時の inode / device / size / mtime / ctime / mode と commit 直前を比較し、変更を拒否する。
排他 lock は取らないため、この確認と replace の間の他プロセス操作まで保証しない。
置換後の mode / quarantine 復元で失敗したときはエラーを返すが、内容の置換は完了している。

## 三つの門番

`UpdaterError.editingRefused(gatekeeper:reason:)` で識別子と理由文字列を返す。

| 識別子 | purpose-built fixture | 検査した理由文字列 |
|---|---|---|
| `sfxPrefix` | MZ / e_lfanew / PE signature を持つ 128 byte の非実行 prefix | `SFX prefix があるため ZIP の offset 基準を保証できません` |
| `trailingData` | 正常な EOCD の後ろへ `trailing data` を付加 | `EOCD の後ろに trailing data があります` |
| `centralDirectoryOffset` | EOCD offset の上位 bit を手で落とし、CD 以外を指させる | `EOCD.cdOffset が PK\x01\x02 を指しません。ZIP64 なしの offset 切り詰めなどが疑われます` |

三つとも正確な error case / reason と原本の全 byte 不変を assert する。
KaitoKit の列挙は三つとも可能。SFX と trailing data では既存 payload の読み取りも比較した。
offset を壊した fixture の payload が正常に読めるとは主張しない。
実際の 4 GiB ditto 書庫を再生成せず、記録された障害の判定条件だけを小さい fixture で再現した。

ZIP64 では locator / EOCD64 を検証して解決した CD offset を probe する。
空 ZIP は CD signature を持たないので、count / size / offset が全て 0 で、CD の終端位置も
0 の正規形を例外として許可する。通常終端と ZIP64 終端の空書庫をそれぞれ更新した。
KaitoKit の ByteSource 経由の形式判定は空 ZIP64 を拒否するが、entry がない正規形は検証済み終端だけで
扱えるため updater は reader の entry 解析を省略する。追加後の全 entry は KaitoKit で往復した。
分割・不整合な終端は `invalidArchive`、原本の変更は `sourceChanged`、終了後の操作は
`invalidState`。KaitoKit の metadata / entry 数上限は維持し、展開しないので展開量上限は緩める。

## 参照実装との差分

完成した全更新 fixture で `unzip -t/-l`、`7zz t/l -slt`、`ditto -x -k`、`bsdtar -tf` を実行する。
必要ツールが無い場合は skip しない。7zz は exit code に加え `Headers Error` / `warnings:` /
`errors:` が無いことを assert する。全 fixture の KaitoKit 全 entry について名前・kind・
内容・mtime・permissions・CRC・非圧縮サイズを比較し、ditto の全ファイル内容・ディレクトリ・
symlink target を入力と照合する。日本語の filesystem 名は canonical equivalence を認める。

| fixture (`build/verification/` 以下) | 結果 |
|---|---|
| `update-writer` | 旧 local / CD 不変、新規 writer と全 byte 一致、全ツール・全属性一致 |
| `update-tree` | disk source の再帰追加、symlink、0755 executable、空 directory の追加を往復 |
| `update-ditto` | 旧 deflate の local / CD 両方で bit 3 を確認。CD より前が全 byte 不変 |
| `update-infozip` | `zip -j` で独立に作成した旧 entry と新 entry を往復 |
| `update-cp932` | 旧名 `93 fa 96 7b 8c ea 2e 74 78 74` / flag 0 が不変。新名は UTF-8 NFC / bit 11 |
| `update-zip64-count` | 65,530 + 10 = 65,540。新たな ZIP64 EOCD / locator、全 entry・全属性一致 |
| `update-existing-zip64` | その ZIP64 に再追加し 65,541 件。旧 local / CD 不変、全 entry・全属性一致 |
| `update-metadata` | 原本 mode 0651、quarantine、Finder tags、任意 xattr、作成日が不変 |
| `update-safety` | 破棄・不正 add・重複・no-op と競合拒否。勝者の完成書庫を全ツールで往復 |
| `update-comment-true` / `update-comment-false` | 空 / 非空 ZIP のコメントを保存して追加、全ツール一致 |
| `update-comment-zip64-empty` | 空 ZIP64 とコメントを保存して追加、全ツール一致 |

65,540 件は **7,864,898 bytes**。通常 EOCD の count だけが 0xFFFF、CD size / offset は
32 bit の真値であり、ZIP64 EOCD と locator が新たに現れる。65,541 件は **7,865,030 bytes**。
大きな ditto 展開ディレクトリは成功後に削除し、書庫と全ログは残す。

### 文字コードと時刻の実ツール上の制限

CP932 fixture は Python の `struct` / `zlib.crc32` のみで作った。
旧 local / CD の名前 byte は CP932、bit 11 は 0、Unicode path extra は無い。
KaitoKit と ditto は `日本語.txt` と新しい `追加/ガラス.txt` を正しく読み、内容も一致した。
Apple unzip は integrity を通るが日本語表示が崩れる。CP932 fixture では一覧の件数を確認し、
正しい名前そのものは生 byte / KaitoKit / ditto で照合する。

この macOS 版 7zz の `-mcp=932` / UTF-8 locale でも、旧名の表示は
`Path = {.txt` だった。**更新前の独立 fixture にも同じ表示**があり、
その baseline と更新後の旧名表示を比較する。新 entry の日本語名表示は正しい。
7zz の整合性検査は両方とも警告なし。`-mcl=on` の併用でも改善しなかった。
POSIX 版の文字列変換は UTF-8 強制時に code page 指定を使わない経路を持つ
([7-Zip の一次 source](https://github.com/ip7z/7zip/blob/main/CPP/Common/StringConvert.cpp))。
これは製品に第三者コードを導入したものではなく、参照ツールの表示制限の調査である。

初回の ditto fixture では source の奇数秒 1700000001 が DOS 時刻で 1700000002 になり、
期待値との不一致が出た。旧 CD は既に byte 不変だった。最終 fixture は表現可能な
偶数秒 1700000000 を source に設定して作成する。新 entry は writer の UT extra で
1700000001 を保持する。読み手から得た値を期待値へ流用してはいない。

## テスト名

新規 `ZipUpdaterTests` は 11 件。

- `testAppendWriterArchiveSharesExactRecordBytes`
- `testAppendDiskTreeAndDirectory`
- `testAppendDittoDataDescriptorsAndInfoZIP`
- `testAppendCP932PreservesRawNamesAndFlags`
- `testGatekeeperSFXPrefixLeavesOriginalUntouched`
- `testGatekeeperTrailingDataLeavesOriginalUntouched`
- `testGatekeeperTruncatedCDOffsetLeavesOriginalUntouched`
- `testAppendCrossesZIP64CountAndUpdatesZIP64Again`
- `testCommitPreservesModeQuarantineXattrsAndCreationDate`
- `testFailureAbandonmentAndConcurrentChangePreserveOriginal`
- `testEmptyArchiveAndCommentSurviveAppend`

既存の `ZipWriterTests` 10 件、`Zip64WriterTests` 3 件も実行する。
テスト名は [writer 検証記録](2026-09-10-zip-writer.md#テスト名) に列挙したまま。

## 未検証・保証しない範囲

- 新しい CD offset / CD size が実際に 4 GiB を超える更新は生成していない。
  合算値は共有 serializer へ渡し、その 32 bit / 16 bit sentinel 境界は既存テストで検査する。
  65,535 件の境界は実際の更新と実ツールで検査した。
- 電源断を注入していない。原本への書き込み descriptor を持たず clone だけを変更し、
  同期後に atomic replace する構造と、破棄 / 失敗 / 競合の原本不変を検査した。
- 原本 mode 0451 では fixture の xattr 設定と Foundation の replace が permission denied に
  なった。最終 metadata fixture は書き込み可能な 0651。読み取り専用の原本の更新成功は保証しない。
- KaitoKit の既定 metadata 上限を超える書庫、分割 ZIP、曖昧な終端構造は編集対象にしない。
- Archive Utility、Windows Explorer、macOS 26 実機での直接検証はしていない。
  実行 OS は上記 macOS 27。削除・改名・descriptor 探索は実装していない。

## 実行コマンドと正確な出力

指定された `swift build 2>&1 | tail -20` と `swift test 2>&1 | tail -40` は今回も
managed sandbox の cache 書き込み拒否により exit 1。SwiftPM の user cache 警告と
manifest 評価エラーであり、製品 source のコンパイル以前に停止する。
全出力は `build/updater-requested-swift-build.log` / `build/updater-requested-swift-test.log`。
両方の末尾 2 行は次のとおり。

```text
<unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

workspace 内へ cache を移すコマンドでは build / test とも exit 0、警告なし。
`--disable-sandbox` は SwiftPM の子プロセス設定であり、外側の managed sandbox は維持する。

```sh
cd /Users/nagash/GyoshukuKit
set -o pipefail
CLANG_MODULE_CACHE_PATH="$PWD/build/clang" swift build --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  2>&1 | tee build/updater-swift-build.log | tail -20
CLANG_MODULE_CACHE_PATH="$PWD/build/clang" swift test --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  2>&1 | tee build/updater-swift-test.log | tail -40
```

### swift build の tail -20

```text
Building for debugging...
Build complete! (0.21秒)
```

### swift test の tail -40

```text
REFERENCE japanese/python-unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE japanese/7zz-t: exit 0; Size:       16 | Compressed: 185
REFERENCE japanese/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE japanese/ditto-x: exit 0; 
REFERENCE japanese/bsdtar-t: exit 0; 日本語/ガラス.txt
Test Case '-[GyoshukuKitTests.ZipWriterTests testJapaneseUTF8NFCAndTimestampExtraLengths]' passed (0.568 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' started.
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' passed (0.003 seconds).
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
Test Case '-[GyoshukuKitTests.ZipWriterTests testSingleSmallFileStoredAndDeflated]' passed (0.864 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' started.
REFERENCE zero/unzip-t: exit 0;     testing: zero                     OK | No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/zero/archive.zip.
REFERENCE zero/unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE zero/7zz-t: exit 0; Size:       0 | Compressed: 128
REFERENCE zero/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE zero/ditto-x: exit 0; 
REFERENCE zero/bsdtar-t: exit 0; zero
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' passed (0.429 seconds).
Test Suite 'ZipWriterTests' passed at 2026-09-10 08:39:26.710.
	 Executed 10 tests, with 0 failures (0 unexpected) in 5.991 (5.993) seconds
Test Suite 'GyoshukuKitTests.xctest' passed at 2026-09-10 08:39:26.710.
	 Executed 24 tests, with 0 failures (0 unexpected) in 174.796 (174.801) seconds
Test Suite 'All tests' passed at 2026-09-10 08:39:26.710.
	 Executed 24 tests, with 0 failures (0 unexpected) in 174.796 (174.801) seconds
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

XCTest は既存 13 + 新規 11 = **24 件、0 failures**。
末尾の Swift Testing の `0 tests` は別 runner の表示。

## 各更新書庫の実ツール出力

以下は保存ログからそのまま転記した UTF-8 表示。unzip は `-t` の末尾 2 行と `-l` の
最終行、7zz は `t` の全文。各 `ditto -x -k` は exit 0、stdout / stderr とも空であり、
その空出力を成功メッセージに置き換えてはいない。展開物の内容照合は XCTest が行う。
`7zz l -slt` と `bsdtar -tf` の全文も各 fixture directory に保存する。

### update-writer

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-writer/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 304 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-writer/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-writer/archive.zip
Type = zip
Physical Size = 304

Everything is Ok

Files: 2
Size:       56
Compressed: 304
```

### update-tree

unzip -t / -l（exit 0）:

```text
    testing: empty/                   OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-tree/archive.zip.
       62                     5 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 652 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-tree/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-tree/archive.zip
Type = zip
Physical Size = 652

Everything is Ok

Folders: 2
Files: 3
Size:       62
Compressed: 652
```

### update-ditto

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-ditto/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 326 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-ditto/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-ditto/archive.zip
Type = zip
Physical Size = 326

Everything is Ok

Files: 2
Size:       56
Compressed: 326
```

### update-infozip

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-infozip/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 334 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-infozip/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-infozip/archive.zip
Type = zip
Physical Size = 334

Everything is Ok

Files: 2
Size:       56
Compressed: 334
```

### update-cp932

unzip -t / -l（exit 0）:

```text
    testing: 追�?�/�?��?��?�.txt     OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-cp932/archive.zip.
       33                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 309 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-cp932/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-cp932/archive.zip
Type = zip
Physical Size = 309

Everything is Ok

Files: 2
Size:       33
Compressed: 309
```

### update-zip64-count

unzip -t / -l（exit 0）:

```text
    testing: entry-65539              OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-zip64-count/archive.zip.
        0                     65540 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 7864898 bytes (7681 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-zip64-count/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-zip64-count/archive.zip
Type = zip
Physical Size = 7864898
64-bit = +
Characteristics = Zip64

Everything is Ok

Files: 65540
Size:       0
Compressed: 7864898
```

### update-existing-zip64

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-existing-zip64/archive.zip.
       18                     65541 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 7865030 bytes (7681 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-existing-zip64/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-existing-zip64/archive.zip
Type = zip
Physical Size = 7865030
64-bit = +
Characteristics = Zip64

Everything is Ok

Files: 65541
Size:       18
Compressed: 7865030
```

### update-metadata

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-metadata/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 304 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-metadata/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-metadata/archive.zip
Type = zip
Physical Size = 304

Everything is Ok

Files: 2
Size:       56
Compressed: 304
```

### update-safety

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-safety/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 304 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-safety/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-safety/archive.zip
Type = zip
Physical Size = 304

Everything is Ok

Files: 2
Size:       56
Compressed: 304
```

### update-comment-true

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-comment-true/archive.zip.
       18                     1 file
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 174 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-comment-true/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-comment-true/archive.zip
Type = zip
Physical Size = 174
Comment = 
{
ZIP comment: 保存
}

Everything is Ok

Size:       18
Compressed: 174
```

### update-comment-false

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-comment-false/archive.zip.
       56                     2 files
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 324 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-comment-false/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-comment-false/archive.zip
Type = zip
Physical Size = 324
Comment = 
{
ZIP comment: 保存
}

Everything is Ok

Files: 2
Size:       56
Compressed: 324
```

### update-comment-zip64-empty

unzip -t / -l（exit 0）:

```text
    testing: new.txt                  OK
No errors detected in compressed data of /Users/nagash/GyoshukuKit/build/verification/update-comment-zip64-empty/archive.zip.
       18                     1 file
```

7zz t（exit 0、警告なし）:

```text
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 174 bytes (1 KiB)

Testing archive: /Users/nagash/GyoshukuKit/build/verification/update-comment-zip64-empty/archive.zip
--
Path = /Users/nagash/GyoshukuKit/build/verification/update-comment-zip64-empty/archive.zip
Type = zip
Physical Size = 174
Comment = 
{
ZIP comment: 保存
}

Everything is Ok

Size:       18
Compressed: 174
```

ZIP64 の KaitoKit 照合で出力した行:

```text
KAITO UPDATE ZIP64 count=65540; all names, bytes, dates, permissions and CRCs verified
```

> **Verification: ZIP/ZIP64 append (2026-09-10)**
>
> Starting from main e2ab728, ArchiveUpdater now adds disk entries, data and
> directories, then commits through a same-volume APFS copy/clone and atomic
> replacement. New entries use ArchiveWriter itself; a deterministic update is
> byte-identical to creating the same complete archive with the writer. Old local
> records stay at their offsets and the old CD is streamed verbatim, including
> CP932 name bytes, flags, extras and attributes. No descriptor scanning or
> recompression is introduced. KaitoKit parses existing entries; the updater only
> validates end-record layout and edit eligibility. Canonical empty archives need
> no entry parser, including empty ZIP64 that KaitoKit's ByteSource detector does not recognize.
>
> Three distinct gatekeeper IDs and reason strings reject SFX, trailing data and
> invalid declared CD offsets, with unchanged-original assertions. Commit restores
> POSIX mode immediately and reinstates quarantine; tests also preserve Finder
> tags, arbitrary xattrs and creation time. Abandonment, invalid additions, no-op
> commits and competing updater commits are checked. Callers serialize access;
> no cross-process lock or injected power-loss guarantee is claimed. Metadata
> restoration can fail after content replacement has succeeded.
>
> All completed update fixtures pass unzip integrity, warning-free 7zz integrity,
> ditto extraction and full KaitoKit comparisons of every entry's name, bytes,
> kind, time, permissions, size and CRC. Fixtures include writer, ditto bit 3,
> Info-ZIP, clean-room Python CP932, directories/symlinks, comments and empty ZIPs.
> A real 65,530 + 10 update introduces ZIP64 and all readers count 65,540; another
> update of that ZIP64 yields 65,541. Exact reference output is reproduced above.
> Apple unzip and macOS 7zz have legacy-name display limitations reproduced before
> updating; KaitoKit and ditto retain the correct Japanese names and contents.
>
> With workspace caches, all 24 XCTest tests pass without compiler/SwiftPM warnings,
> including the original 13. Literal default-cache commands remain blocked by the
> managed sandbox. Actual updated CD size/offset above 4 GiB, power-loss injection,
> GUI readers, Windows Explorer and physical macOS 26 remain unverified. The shared
> serializer's per-field boundary tests still pass. Deletion/renaming are stage
> three; KaitoKit and KaitoFinder were not modified. Full logs and small artifacts
> are retained under build; large extracted count fixtures are removed after checks.


## ローカル commit の制限

main 上で `git add` を試したが、sandbox が index lock の作成を拒否した。

```text
fatal: Unable to create '/Users/nagash/GyoshukuKit/.git/index.lock': Operation not permitted
```

続く `git commit -F build/commit-message.txt` は exit 1:

```text
no changes added to commit (use "git add" and/or "git commit -a")
```

ステージング自体ができないため、変更は **未ステージの作業ツリー** に残る。
HEAD は `e2ab728` のまま。指定された二つの trailer を末尾に持つ日本語メッセージは
`build/commit-message.txt` に保存した。push はしていない。

> **Local commit limitation:** staging was denied with `.git/index.lock: Operation
> not permitted`; the commit attempt then reported `no changes added to commit`.
> Changes remain unstaged on main at e2ab728. The Japanese commit message, ending
> with both requested trailers, is saved in build/commit-message.txt. Nothing was pushed.
