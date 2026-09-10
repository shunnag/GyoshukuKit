# 検証: ZIP / ZIP64 の削除・改名 (2026-09-10)

## 対象と環境

段階 3。開始点は clean な `main` / `ce155756d9d659ce3144be677c96d505f0967d1d`（0.2.0）。
設計 §3・§6・§7、追加更新の検証記録、全 writer / updater source、KaitoKit の
`2026-09-10-raw-record.md` と `RawEntryRecord.swift` を先に確認した。
CHANGELOG を 0.3.0 に更新し、README と設計の実装済み範囲を更新した。

- macOS 27.0 (26A428)、Apple Silicon arm64
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、Swift 6 言語モード、macOS 26 deployment target
- `/usr/bin/unzip`: Apple Info-ZIP UnZip 6.00
- `/opt/homebrew/bin/7zz`: 7-Zip 26.03 arm64 (2026-09-03)
- OS 同梱の `/usr/bin/ditto`、`/usr/bin/tar`、`/usr/bin/cmp`、`/usr/bin/python3`
- KaitoKit: `4ba6ea0a927a459b20b8dd0c286169793665d980`、CHANGELOG 0.4.0、変更なし
- KaitoFinder: `30ae51efc175960a00d9a42375918be01ac764d8`、変更なし

依存は既存の `.package(path: "../KaitoKit")`。version pin がないため manifest の変更は不要。
製品は純 Swift と OS の Foundation / Darwin / zlib のまま。Python・7-Zip 等はテスト oracle のみ。
system libarchive のリンク・dlopen・手書き C prototype は追加していない。

> **Scope and environment**
>
> Stage three starts from clean main at ce15575 (0.2.0), consumes the existing KaitoKit 0.4.0
> raw-record API, and records version 0.3.0. The package already uses a local dependency without
> a version pin. Neither KaitoKit nor KaitoFinder is changed. Product code remains pure Swift 6
> for macOS 26+, using only existing OS libraries. External tools are test oracles.

## API と予約の契約

```swift
ArchiveUpdater.open(url: URL) throws -> ArchiveUpdater
updater.remove(entriesAt: [Int]) throws
updater.rename(entryAt: Int, to: String) throws
updater.add(contentsOf: URL, as: String) throws
updater.add(data: Data, as: String, modificationDate: Date? = nil,
            permissions: UInt16? = nil) throws
updater.addDirectory(String) throws
updater.commit() throws
```

index は open 時の KaitoKit の archive order に対応するゼロ始まり。削除予約で詰め直さない。
新しく add した entry は index 操作の対象外。削除の重複は一度だけ適用し、同じ index の改名は
最後の予約名を使う。削除済み index の改名は拒否する。削除・改名で空く名前は後の操作で使える。
改名は予約済みの改名・削除と追加を含む名前集合に対して検査するので、名前の交換には一時名を使う。
directory の子孫は呼出側が一件ずつ指定する。symlink の target は書き換えない。

空、NUL、絶対パス、`..`、`.`、空成分、Windows の `\` / `:`、65,535 byte を越える名前を拒否する。
新しい名前は NFC / UTF-8。directory は末尾 `/` を付ける。名前の重複と file / 子の衝突も拒否する。
範囲外 index は `UpdaterError.invalidEntryIndex`、名前の問題は既存の `WriterError` を返す。
移動不能は `UpdaterError.nonRelocatableEntry(index:name:reason:)` で index・名前・理由を返す。

thread-safe / Sendable にはしない。操作と同一書庫へのアクセスは呼出側が直列化する。
成功後の commit は no-op、その他の操作は拒否する。操作・commit の失敗は terminal。

> **API contract**
>
> Removal and rename indices remain stable from open. Additions are outside that index space.
> Repeated deletion is idempotent; the last rename wins. Removed entries cannot be renamed.
> Validation accounts for queued changes and additions; callers use temporary names for swaps.
> Descendant policy and symlink-target changes belong to the caller. Unsafe names, conflicts and
> invalid indices fail explicitly. Instances remain serial, non-Sendable, and unusable after failure.

## 再構築と原本の保護

追加だけなら既存の append 経路を維持する。削除・改名は予約だけを保持し、commit で再構築する。
追加が混在するときは clone 上の append を完成させ、その APFS snapshot を読取元に分ける。
これにより新旧の全生存 entry に KaitoKit の同じ `rawRecord(of:)` を使用でき、同じファイルの
重なる範囲を読み書きしない。すべての作業ファイルは同じ `.itemReplacementDirectory` に置く。

生存 entry の `recordRange` を archive order に 256 KiB ずつ運び、新しい local offset を記録する。
`recordRange` の終端は KaitoKit だけが決める。GyoshukuKit は descriptor の署名探索や幅の算術を持たない。
payload と descriptor は再圧縮・再符号化しない。原本と更新後の圧縮 payload / descriptor byte を比較した。

改名は local header 自身の固定部・名前・extra を読み、local と central の extra 長を混同しない。
同長なら record 全体をコピーして同じ位置で local の名前と flag を patch する。
異長なら local header を再出力し、`payloadRange.lowerBound..<recordRange.upperBound` をコピーする。
旧 Unicode Path (`0x7075`) は padding ID (`0xFFFF`) に置換し、同長改名の payload 位置を保ちながら
旧名の override を無効化する。それ以外の timestamp / owner / 未知 extra、属性、comment は保持する。

CD は全 entry を再出力し、uncompressed size / compressed size / offset の各 sentinel と `0x0001`
を独立に生成する。旧 CD への offset 部分 patch は行わない。終端は writer と同じ serializer を使用し、
count / CD size / CD offset が収まれば ZIP64 EOCD / locator を落とす。ZIP コメントは保持する。
central のみで wide descriptor を宣言した entry は、必要な size / offset 欄がなくなっても空の
ZIP64 marker を残す。これを消すと KaitoKit の descriptor 解釈が変わるためである。

三門番（SFX prefix、EOCD 後の trailing data、不正な EOCD.cdOffset）は従来どおり open で拒否する。
commit は APFS clone → 再構築 → truncate / synchronize → `replaceItemAt` → POSIX mode 復元 →
quarantine 復元。inode / device / size / mtime / ctime / mode の競合検知も維持する。
Task cancellation は record / コピー chunk ごとと置換直前に確認する。
失敗・破棄では clone と snapshot を削除し、置換前の原本は全 byte 不変。
置換後の metadata 復元が失敗する場合には既に内容は置換済み、という従来の契約は変更しない。

> **Rebuild and safety**
>
> Append-only updates retain the old path. Mixed additions are completed in the clone and read
> from a separate snapshot. Every surviving record comes from KaitoKit; descriptor boundaries
> are never recomputed. Equal-length local renames patch the copied record, while other lengths
> re-emit only headers. The entire CD is emitted with independent ZIP64 fields and new offsets.
> Original name bytes/flags and unrelated metadata survive. The same gatekeepers, atomic replace,
> source checks and metadata restoration remain. Cancellation/failure before replace preserves
> the original, and temporary files are discarded.

## XCTest と受入条件

新規テスト名と観点は以下のとおり。既存 24 件も同じ全体実行に含める。

| テスト名 | 検査内容 |
|---|---|
| `testDeleteFirstMiddleLastAndSeveralPreservesRawRecords` | 先頭・中央・末尾・複数同時削除、重複指定、全生存 raw record / payload / descriptor の byte 同一 |
| `testRenameShorterEqualLongerAndJapanesePatchesBothHeaders` | 短い・同長・長い・日本語 NFD → NFC、両ヘッダと全後続 offset。同長は両名前領域だけを変えた独立 oracle と書庫全体が一致 |
| `testDeleteRenameAndAppendShareOneAtomicCommitInEitherOrder` | 削除・再改名・追加の同時 commit、追加前後の予約、削除名の再利用、成功後の状態 |
| `testDittoDescriptorsSurviveNeighborDeletionAndRename` | 実 `ditto -c -k` の bit 3 entry、隣接削除・改名後も全 descriptor byte を保存 |
| `testCP932DeletionKeepsEverySurvivingNameByte` | 3 つの CP932 名から 1 件削除、残る local / central の名前 byte・flag と KaitoKit / ditto の日本語名 |
| `testRemovingAllEntriesMatchesPythonEmptyZIP` | 全削除は 22 byte、Python zipfile の空出力と一致、7zz / KaitoKit の count 0、Apple の既知制限 |
| `testInvalidIndicesAndUnsafeOrCollidingRenamesLeaveOriginalUntouched` | 負・範囲外 index、危険な名前、NFC / 予約名 / file と子の衝突、原本 byte 不変 |
| `testNilRawRecordRefusesOnlySurvivingEntries` | 実 recovery reader が返した nil を内部取得境界へ注入し、生存なら理由付き拒否、削除対象なら問い合わせない |
| `testFailureAndAbandonmentAfterPartialWorkPreserveOriginal` | clone への追加後の破棄、2 record コピー後の I/O / size 失敗、原本 byte 不変 |
| `testTaskCancellationDuringRebuildPreservesOriginal` | 実 Task 内で 2 record コピー後に cancel、CancellationError と原本 byte 不変 |
| `testRebuildPreservesArchiveModeQuarantineXattrsCreationDateAndComment` | ZIP コメント、mode 0651、quarantine、Finder tag、任意 xattr、作成日 |
| `testFolderRenamesAreExplicitAndPreserveSymlinks` | 親だけ改名した出力と、全子孫を個別改名した出力の両方、symlink target 不変 |
| `testCP932RenameInvalidatesUnicodePathExtraWithoutMovingEqualLengthPayload` | CP932 10 byte → UTF-8 10 byte、bit 11、Unicode Path 無効化、異なる UT extra 長、未知 extra・entry comment・内部属性保持 |
| `testConcurrentReplacementRejectsQueuedRebuild` | 別 updater の commit 後は sourceChanged、勝者の全 byte 不変 |
| `testZIP64CountDropsBelowLimitAndReturnsAfterMixedCommit` | 65,536 → 65,533 → 65,536 件、ZIP64 EOCD の除去と再導入、全 entry の往復 |
| `testRebuiltCentralDirectoryAddsAndDropsEachZIP64FieldIndependently` | 0xFFFFFFFF の直前・一致・超過、size / compressed size / offset 個別欄の出入り、未知でない UT 保持 |
| `testSignedZIP32AndZIP64DescriptorsSurviveRebuild` | 0 / 16 / 24 byte descriptor の raw コピーと各実ツール往復、local ZIP64 extra 保持 |
| `testLocalOffsetCrosses4GiBThenDropsAfterDeletion` | 実 offset 4,294,967,291 → 4,294,967,307 → 0、CD extra / EOCD の増減、約 4 GiB の全 stored byte と ditto 出力 |
| `testZIP32DescriptorCrossingZIP64OffsetIsRefusedWithoutChangingOriginal` | KaitoKit 0.4.0 の offset 用 ZIP64 と descriptor 幅の制限を実 API で再現し、約 4 GiB コピー後の拒否と cmp による原本同一 |

各完成した受入 fixture は `unzip -t/-l`、`7zz t/l -slt`、`ditto -x -k`、`bsdtar -tf` で検査する。
7zz は exit code だけでなく `headers error` / `warning` / `errors:` を大文字小文字を無視して拒否する。
KaitoKit は全 entry の名前・内容・mtime・permissions・CRC・size を比較する。
ditto の全ファイル内容・directory・symlink target も照合する。巨大 entry は 256 KiB ずつ全 byte を
照合し、CRC を再計算する。巨大な書庫・展開物は成功後に削除し、小さい最終出力とログを残す。
空 ZIP の Apple ツール結果は成功と偽らず、既知の exit 1 と出力を assert する。

正常な ZIP の公開 open は incomplete entry を作らず、他形式も三門番より先には進まない。
このため nil の試験は、実 KaitoKit recovery の nil を内部 closure に差し込む。
公開 API や KaitoKit の source をテストのために変更してはいない。

> **Coverage**
>
> The table names all 19 additions. Every completed acceptance fixture is tested with real tools,
> including warning text from 7-Zip, and every KaitoKit entry is compared for content and metadata.
> Tests include actual 4 GiB offset transitions, both count directions, cancellation and failure.
> Nil is injected at the internal retrieval boundary using an actual incomplete recovery entry;
> valid public ZIP opening cannot otherwise produce this state. Empty ZIPs retain the documented
> Apple-tool exception and match Python byte-for-byte.

## 検証の限界と追加調査

### KaitoKit 0.4.0 の offset 用 ZIP64 / descriptor の制限

KaitoKit の `ZipReader.rawRecordEnd` は local **または central の 0x0001 の存在**で descriptor を
wide と解釈する。ZIP32 descriptor の entry が新しい local offset で初めて ZIP64 を必要とすると、
offset だけの extra を加えても幅の解釈が変わる。小さい対照 ZIP でも通常 read は成功する一方、
raw API が `ZIP data descriptor overlaps the next record or central directory` を返すことを assert する。

この組合せを無条件にサポートすることは、KaitoKit を変更せず descriptor を verbatim に保つ条件と
両立しない。GyoshukuKit は `nonRelocatableEntry` で明示的に拒否し、原本を維持する。
descriptor のない entry の 4 GiB 越え、元から wide な descriptor、count だけの ZIP64 増減は検証済み。
KaitoKit / KaitoFinder を変更するという範囲拡大は行わない。

### ditto の追加制限（受入 fixture と分けた調査）

署名なし descriptor（12 / 20 byte）を含む公開 byte 表の入力を調べた。
unzip・7zz（警告なし）・KaitoKit は再構築後も成功し、全 raw record の保存を確認したが、ditto は失敗した。
独立に再生成した**更新前**の入力でも同じ失敗を再現し、local の size / CRC を埋めても変わらなかった。
署名付きだけに絞ると通常の local ZIP64 は ditto でも成功し、central だけの ZIP64 descriptor は
更新前から拒否された。これらを「ditto 往復成功」の受入 fixture に含めていない。
調査ログは `build/verification/descriptor-investigation/` に保存した。

その他、Archive Utility / Windows Explorer、電源断、replace 後の metadata 復元失敗の注入、
巨大 CD **size** そのものの 4 GiB 越え、暗号化 entry の新たな外部ツール往復は今回未検証。
排他 lock を取らないため、原本の最終検査と replace の間の競合まで防ぐ保証はない。

> **Limits**
>
> One combination is explicitly refused: a ZIP32 descriptor whose relocated offset newly requires
> a ZIP64 extra. KaitoKit 0.4.0 treats that offset-only extra as a wide-descriptor declaration.
> Its real API reproduces the disagreement; retaining descriptor bytes without changing KaitoKit
> requires refusal. Other tested ZIP64 transitions succeed. Exploratory unsigned-descriptor and
> central-only ZIP64 inputs are rejected by ditto even before editing, although unzip, 7-Zip and
> KaitoKit succeed. These are not claimed as successful ditto acceptance fixtures. Other untested
> areas are listed above; the pre-existing replacement/metadata and concurrency limits remain.


## 実行コマンドと build / test の出力

指定された以下のコマンドは両方とも exit 1。ホーム配下の module cache の書込みを
managed sandbox が拒否し、manifest のコンパイル前後で停止する。pipefail で確認した。

```sh
cd /Users/nagash/Github/GyoshukuKit
set -o pipefail
swift build 2>&1 | tee build/stage3-build-requested.log | tail -20
swift test 2>&1 | tee build/stage3-test-requested.log | tail -40
```

指定 build の末尾（全出力 6 行）:

```text
warning: /Users/nagash/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: /Users/nagash/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: /Users/nagash/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
error: 'gyoshukukit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.WLgENN/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "6.0.0", "/Users/nagash/Github/GyoshukuKit/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.y167Vd/gyoshukukit-manifest"])
<unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

指定 test の末尾（全出力 6 行）:

```text
warning: /Users/nagash/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: /Users/nagash/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: /Users/nagash/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
error: 'gyoshukukit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.UFI4Nt/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "6.0.0", "/Users/nagash/Github/GyoshukuKit/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.25s08x/gyoshukukit-manifest"])
<unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

先行記録と同じく cache の置き場を明示し、SwiftPM の子プロセス sandbox だけを無効化した。
外側の filesystem 制限は変更していない。最終コマンドは以下のとおり。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/gyoshukukit-module-cache swift build --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  2>&1 | tee build/stage3-swift-build-final.log | tail -20
CLANG_MODULE_CACHE_PATH=/tmp/gyoshukukit-module-cache swift test --disable-sandbox \
  --cache-path build/cache --config-path build/config --security-path build/security \
  2>&1 | tee build/stage3-swift-test-final.log | tail -40
git diff --check
```

既存 24 件の baseline は 0 failures / 0 skips（196.757 秒）。実装後の 42 件も
0 failures / 0 skips（290.818 秒）。その後に追加した descriptor 境界の拒否と、既存の実 offset
境界試験は合わせて 2 件、0 failures（22.190 秒）で成功した。
追加調査中には ditto の未対応 descriptor による失敗と、テスト側で EOF の nil を unwrap した
失敗を検出した。前者は更新前の対照実験で確認して上記の限界として分離し、後者は EOF を
正しく扱うようテストを修正した。失敗した実行を最終成功結果には数えていない。

> **Commands**
>
> Both exact requested commands exit 1 because the managed environment cannot write the home
> module cache. The command/output blocks above record this rather than reporting those commands
> as successful. Adjusted commands keep the outer filesystem restrictions and use writable caches.
> Baseline, intermediate and focused runs are identified separately from the final full-suite run.

## 最終実行の結果

環境調整後の最終 build / 全 test は exit 0。コンパイラ警告なし、43 XCTest（既存 24 + 新規 19）、
0 failures / 0 skips。末尾の Swift Testing の 0 tests は別 runner の出力。

### swift build の tail -20

```text
Building for debugging...
Build complete! (0.19秒)
```

### swift test の tail -40

```text
REFERENCE japanese/python-unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE japanese/7zz-t: exit 0; Size:       16 | Compressed: 185
REFERENCE japanese/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE japanese/ditto-x: exit 0; 
REFERENCE japanese/bsdtar-t: exit 0; 日本語/ガラス.txt
Test Case '-[GyoshukuKitTests.ZipWriterTests testJapaneseUTF8NFCAndTimestampExtraLengths]' passed (0.596 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' started.
Test Case '-[GyoshukuKitTests.ZipWriterTests testRejectsFileDirectoryConflictsAndOutputAsSource]' passed (0.002 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testSingleSmallFileStoredAndDeflated]' started.
REFERENCE single-stored/unzip-t: exit 0;     testing: small.txt                OK | No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/single-stored/archive.zip.
REFERENCE single-stored/unzip-l: exit 0; ---------                     ------- |         9                     1 file
REFERENCE single-stored/7zz-t: exit 0; Size:       9 | Compressed: 147
REFERENCE single-stored/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE single-stored/ditto-x: exit 0; 
REFERENCE single-stored/bsdtar-t: exit 0; small.txt
REFERENCE single-deflate/unzip-t: exit 0;     testing: small.txt                OK | No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/single-deflate/archive.zip.
REFERENCE single-deflate/unzip-l: exit 0; ---------                     ------- |         9                     1 file
REFERENCE single-deflate/7zz-t: exit 0; Size:       9 | Compressed: 149
REFERENCE single-deflate/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE single-deflate/ditto-x: exit 0; 
REFERENCE single-deflate/bsdtar-t: exit 0; small.txt
Test Case '-[GyoshukuKitTests.ZipWriterTests testSingleSmallFileStoredAndDeflated]' passed (0.893 seconds).
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' started.
REFERENCE zero/unzip-t: exit 0;     testing: zero                     OK | No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/zero/archive.zip.
REFERENCE zero/unzip-l: exit 0; ---------                     ------- |         0                     1 file
REFERENCE zero/7zz-t: exit 0; Size:       0 | Compressed: 128
REFERENCE zero/7zz-l: exit 0; Volume Index = 0 | Offset = 0
REFERENCE zero/ditto-x: exit 0; 
REFERENCE zero/bsdtar-t: exit 0; zero
Test Case '-[GyoshukuKitTests.ZipWriterTests testZeroByteFileUsesStoredWithoutPayload]' passed (0.437 seconds).
Test Suite 'ZipWriterTests' passed at 2026-09-10 10:51:21.508.
	 Executed 10 tests, with 0 failures (0 unexpected) in 6.062 (6.064) seconds
Test Suite 'GyoshukuKitTests.xctest' passed at 2026-09-10 10:51:21.508.
	 Executed 43 tests, with 0 failures (0 unexpected) in 296.056 (296.065) seconds
Test Suite 'All tests' passed at 2026-09-10 10:51:21.508.
	 Executed 43 tests, with 0 failures (0 unexpected) in 296.056 (296.066) seconds
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

## 参照ツールの実出力

以下は最終受入実行のログからそのまま抜粋したもの。小さい代表例は全文、その後は各 fixture の
unzip -t の末尾 2 行と unzip -l の最終行、7zz t の Everything is Ok 以降を掲載する。
全ログは `build/verification/<fixture>/` の `unzip-t.log` / `unzip-l.log` / `7zz-t.log` /
`7zz-l.log` / `ditto-x.log` / `bsdtar-t.log`。7zz の warning 検査は全出力に適用する。

### delete-0: unzip -t / 7zz t の全文

```text
Archive:  /Users/nagash/Github/GyoshukuKit/build/verification/delete-0/archive.zip
    testing: entry-1.txt              OK
    testing: entry-2.txt              OK
    testing: entry-3.txt              OK
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-0/archive.zip.
```

```text

7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 646 bytes (1 KiB)

Testing archive: /Users/nagash/Github/GyoshukuKit/build/verification/delete-0/archive.zip
--
Path = /Users/nagash/Github/GyoshukuKit/build/verification/delete-0/archive.zip
Type = zip
Physical Size = 646

Everything is Ok

Files: 4
Size:       4002
Compressed: 646
```

ditto -x -k は exit 0、stdout / stderr とも空。全展開内容を照合した。

### delete-rename-source-changed

unzip -t / -l の抜粋:

```text
    testing: entry-3.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-rename-source-changed/archive.zip.
     3910                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 4
Size:       3910
Compressed: 646
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-cp932

unzip -t / -l の抜粋:

```text
    testing: ?�?�.txt                 OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-cp932/archive.zip.
       28                     2 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 2
Size:       28
Compressed: 274
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-cp932-unicode-extra

unzip -t / -l の抜粋:

```text
    testing: �?�?�.txt               OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-cp932-unicode-extra/archive.zip.
       16                     1 file
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Size:       16
Compressed: 236
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-0

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-0/archive.zip.
     4002                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 4
Size:       4002
Compressed: 646
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-2

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-2/archive.zip.
     3956                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 4
Size:       3956
Compressed: 646
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-4

unzip -t / -l の抜粋:

```text
    testing: entry-3.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-4/archive.zip.
     3910                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 4
Size:       3910
Compressed: 646
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-0-2-4

unzip -t / -l の抜粋:

```text
    testing: entry-3.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-0-2-4/archive.zip.
     1978                     2 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 2
Size:       1978
Compressed: 334
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-rename-append-true

unzip -t / -l の抜粋:

```text
    testing: entry-0.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-rename-append-true/archive.zip.
     3004                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       3004
Compressed: 742
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-rename-append-false

unzip -t / -l の抜粋:

```text
    testing: entry-0.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-rename-append-false/archive.zip.
     3004                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       3004
Compressed: 742
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-ditto-descriptors

unzip -t / -l の抜粋:

```text
    testing: longer-ditto-name.txt    OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-ditto-descriptors/archive.zip.
     1898                     2 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 2
Size:       1898
Compressed: 362
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-folder

unzip -t / -l の抜粋:

```text
    testing: folder/sub/file.txt      OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-folder/archive.zip.
       21                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Folders: 2
Files: 2
Size:       21
Compressed: 535
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-folder-descendants

unzip -t / -l の抜粋:

```text
    testing: renamed/sub/file.txt     OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-folder-descendants/archive.zip.
       21                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Folders: 2
Files: 2
Size:       21
Compressed: 541
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-nil-record

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-nil-record/archive.zip.
     3979                     4 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 4
Size:       3979
Compressed: 646
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-rename-metadata

unzip -t / -l の抜粋:

```text
    testing: entry-3.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/delete-rename-metadata/archive.zip.
     2967                     3 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 3
Size:       2967
Compressed: 532
```

ditto: exit 0、出力なし。全展開内容を照合。

### delete-all

unzip -t / -l の抜粋:

```text
Archive:  /Users/nagash/Github/GyoshukuKit/build/verification/delete-all/archive.zip
warning [/Users/nagash/Github/GyoshukuKit/build/verification/delete-all/archive.zip]:  zipfile is empty
warning [/Users/nagash/Github/GyoshukuKit/build/verification/delete-all/archive.zip]:  zipfile is empty
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 0
Size:       0
Compressed: 22
```

ditto（既知の exit 1）:

```text
ditto: Incorrect pkzip signature
```

### rename-shorter

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-shorter/archive.zip.
     4945                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       4945
Compressed: 782
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-equal

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-equal/archive.zip.
     4945                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       4945
Compressed: 802
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-longer

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-longer/archive.zip.
     4945                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       4945
Compressed: 834
```

ditto: exit 0、出力なし。全展開内容を照合。

### rename-japanese

unzip -t / -l の抜粋:

```text
    testing: entry-4.txt              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rename-japanese/archive.zip.
     4945                     5 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 5
Size:       4945
Compressed: 826
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-zip64-offset-up

unzip -t / -l の抜粋:

```text
    testing: tail.txt                 OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-zip64-offset-up/archive.zip.
4294967270                     2 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 2
Size:       4294967270
Compressed: 4294967618
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-zip64-offset-down

unzip -t / -l の抜粋:

```text
    testing: tail.txt                 OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-zip64-offset-down/archive.zip.
       19                     1 file
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Size:       19
Compressed: 151
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-zip64-fields

unzip -t / -l の抜粋:

```text
    testing: x                        OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-zip64-fields/archive.zip.
        3                     1 file
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Size:       3
Compressed: 127
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-signed-descriptors

unzip -t / -l の抜粋:

```text
    testing: entry-2                  OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-signed-descriptors/archive.zip.
       41                     3 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 3
Size:       41
Compressed: 473
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-zip64-count-down

unzip -t / -l の抜粋:

```text
    testing: entry-65534              OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-zip64-count-down/archive.zip.
        0                     65533 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 65533
Size:       0
Compressed: 7863982
```

ditto: exit 0、出力なし。全展開内容を照合。

### rebuild-zip64-count-up

unzip -t / -l の抜粋:

```text
    testing: added-2                  OK
No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/build/verification/rebuild-zip64-count-up/archive.zip.
        0                     65536 files
```

7zz t（exit 0、警告なし）の抜粋:

```text
Everything is Ok

Files: 65536
Size:       0
Compressed: 7864398
```

ditto: exit 0、出力なし。全展開内容を照合。

### KaitoKit / 原本不変の実測出力

```text
REFUSAL rawRecord が nil のため独立して移動できません。削除・改名による再構築を拒否します
KAITO REBUILD offset up: 4294967307, size=4294967251, CRC=d3e3469e; every payload byte and ditto output verified
KAITO REBUILD offset down: 0, ZIP64 field and EOCD absent
KAITO OFFSET DESCRIPTOR LIMIT: ZIP data descriptor overlaps the next record or central directory
REFUSAL ZIP32 descriptor の移動先に ZIP64 offset が必要です。KaitoKit 0.4.0 の幅の解釈が変わるため再構築を拒否します
REFERENCE rebuild-zip64-descriptor-refusal/original-cmp: exit 0; 
KAITO REBUILD ZIP64 down: count=65533, ZIP64 EOCD absent; every entry verified
KAITO REBUILD ZIP64 up: count=65536, ZIP64 EOCD present; every entry verified
```

### ditto の追加調査で観測した更新前の出力

original: exit 1

```text
ditto: entry-1: No such file or directory
ditto: Couldn't read pkzip signature.
```

known-sizes: exit 1

```text
ditto: entry-1: No such file or directory
ditto: Couldn't read pkzip signature.
```

signed-false: exit 0、出力なし。

signed-true: exit 1

```text
ditto: Couldn't read pkzip signature.
```

> **Final result**
>
> With writable caches, the final build and all 43 tests pass without compiler warnings or skips.
> The exact final tails and real-tool excerpts are preserved above. All completed acceptance
> fixtures pass unzip, warning-free 7-Zip, ditto and KaitoKit, with the documented empty-ZIP
> exception. Exploratory ditto failures and the explicit KaitoKit descriptor/offset refusal are
> reported separately and are not described as successful round trips.

## ローカルコミット

main 上で対象 12 ファイルの `git add` と、指定メッセージによる
`git commit -F build/commit-message.txt` を試みた。両方とも exit 128。
managed sandbox が `.git/index.lock` の作成を拒否した。

```text
fatal: Unable to create '/Users/nagash/Github/GyoshukuKit/.git/index.lock': Operation not permitted
```

`git add` 自体が拒否されるため、ステージ済みで残す代替手順も実行できなかった。
変更は作業ツリーに未ステージで残る。HEAD は開始時の
`ce155756d9d659ce3144be677c96d505f0967d1d`、branch は main のまま。push は行っていない。
指定 trailer で終わる日本語のコミットメッセージを、既存の ignore 対象である
`build/commit-message.txt` に保存した。Git の出力は `build/stage3-git-add.log` と
`build/stage3-git-commit.log` に保存した。最後の `git diff --check` は exit 0。

```text
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FLrigd1LKVPFcbdbFAzjzw
```

> **Local commit**
>
> Both staging and committing on main exit 128 because the managed sandbox denies .git/index.lock.
> Staging is therefore unavailable too: all 12 changed/new files remain unstaged, HEAD stays
> ce15575, and nothing was pushed. The Japanese message with the exact requested trailers is
> saved in build/commit-message.txt. Final git diff --check exits 0.
