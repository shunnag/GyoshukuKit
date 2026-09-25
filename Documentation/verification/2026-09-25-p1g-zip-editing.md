# P1-G: ZIP 編集の計画・直接出力・進捗（2026-09-25）

対象は GyoshukuKit `feature/2026-09-24-review` / `c0df9fb` の未コミット差分。
P1-G-final.md と ORDER-P2-P3.md §5 の D7・AC7 修正を実装した。
KaitoKit は sibling の `ba42ed8`（作業ツリー clean）。KaitoKit・KaitoFinder・ArchiveRewriter・Benchmarks・Package.swift は編集していない。

## 環境とコマンド

macOS 27.2 (26B5091g)、arm64、Apple Swift 6.4 (swiftlang-6.4.0.34.1)、Swift 言語モード 6。
この sandbox ではユーザーの module cache に書けないため、全コマンドで次を指定した。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox
swift build --disable-sandbox -c release
swift test --disable-sandbox
swift test --disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none
```

`swiftbuild` の release テスト用 dSYM 生成は sandbox で Operation not permitted になったため、
テストと規模比較だけ debug-info-format を none にした。基準・新実装で同じ設定を使う。
通常の release library build（testing 無し）はその指定なしで成功した。
`@_spi(ZipRawLayout) internal import KaitoKit` は SPI を使う2ファイルだけ、他は public import のまま。
Swift の unused public import 警告と、sandbox のユーザーキャッシュ警告は残る。

## 受け入れ条件

| AC | 実行内容・結果 |
|---|---|
| 1 | Debug build、testing 無しの release build 成功。Debug 全件 320件、失敗0、skip 2。release 全件322件、失敗0、skip 2。最後の engine 差分は43件を再実行して失敗0。 |
| 2 | 既存全件を実行。変更した既存試験は ZipDeleteRenameTests の seam 3件だけ。read-bound と門番・integrity・境界・privacy・modern method・AppleDouble・名前衝突を維持。 |
| 3 | LegacyZipRebuild は c0df9fb の型名だけを変えた oracle。再構築と従来の段階 append→reader→rebuild の両方で全 byte を比較。下記 corpus を実行。 |
| 4 | canonical / ZIP64 判定の照合と、offset が同値・0・0xFFFFFFFE の再符号化との一致。limit・改名・marker で fast path を拒否。 |
| 5 | 同長改名1件・1,000件は inPlacePatch、書込みはそれぞれ2回・2,000回で header / CD 範囲内。冗長 ZIP64、終端の sentinel / 拡張 / made-by、隙間、CD 名長差、追加時の一般経路も oracle と一致。 |
| 6 | 混在4順序、縮小・拡大・W と交差する start==lb・4 GiB 上下。アプリ順は rebuildThenAppend、後から位置を変える順は stagedRebuild。追加破損は GK の完全比較でも、それを迂回した KaitoKit の検査でも失敗し原本を維持。 |
| 7 | output / replace の byte 一致、原本の byte・inode・mtime、0600、flags 0、xattr / quarantine、close、snapshot descriptor の読取、sourceChanged、invalidPath、inode を差し替えたファイルを消さない cleanup、変更なし・空 ZIP。uchg / uappnd は EPERM、EACCES / EIO / EPERM / ENOSPC は fallback せず、ENOTSUP / EXDEV は byte 一致。形式共通 helper を ZIP でない bytes と .tar 名でも確認。 |
| 8 | 6 strategy の進捗。単調、total の補正なし、writeObserver と完全一致、通知数上限。開始・途中・最後の callback throw で output / snapshot を片付ける。 |
| 9 | 両 mode の32 KiB時点の取消しと、計画 index 2 の取消し。CancellationError、原本の byte / inode 維持。 |
| 10 | remove 後に名前表なし。remove→rename、add→remove→rename、rename→remove→rename、重複・file/directory 衝突。既存 EditPathReservationsTests も実行。 |
| 11 | validate の CD 読取は宣言範囲を1回。46 B の CD pread なし。metadata 上限を超えれば invalidArchive。 |
| 12 | git diff と未追跡 Sources の public / SPI 検索を実施。追加 public は output 引数、CommitProgress、commit(progress:)。Testing SPI は strategy と状態のみ。新しい unchecked Sendable なし。 |
| 13 | 同じ KaitoKit を参照する git archive c0df9fb と、新実装の release ZIP-SCALE を比較（下記）。 |
| 14 | design.md §6・§7、CHANGELOG、doc comment を更新。コミット・tag・release はしていない。 |
| 15 | 未実行。KaitoFinder の xcodebuild / P0b 100k全形式・500k zip/tar/tar.gz は仕様どおりオーケストレータの受け入れ作業。ライブラリの数字でこの条件を代用しない。 |

### Byte-identity corpus

- 小型19種類 × 15操作 = 285比較: GK stored / deflate / ZipCrypto / AE-1 / AE-2、手組み10種類、Python非seekable force_zip64、Info-ZIP、Info-ZIP＋0x7075派生、ditto。
- 手組みは冗長 CD ZIP64、sentinel、CDだけの幅広 descriptor、CD順≠local順、record間・末尾の隙間、comment・extra の0 padding、Unicode Path、local/CDの名長差を含む。
- 操作は先頭・中央・末尾・複数・全件削除、同長・短縮・延長・日本語・フォルダ改名、削除＋改名、混在4順序。
- 追加 stored / deflate / 固定saltのAES（AE-1とAE-2）、mtime固定の実directoryは全 byte 一致。追加 ZipCrypto は乱数を固定せず、構造と復号結果を比較。
- 65,536件の ZIP64 2比較、4 GiB の上下を跨ぐ混在2比較（4 MiB chunkでファイル全体を比較）。
- この Mac の `/usr/bin/zip -v` は Unicode support を示さず、実際の生成物にも0x7075がなかった。通常の生成物をそのまま試験し、公開のbyte表に従って0x7075だけを追加した派生も別に試験した。ditto の descriptor と force_zip64 の local ZIP64 はそれぞれ保持する。

### 変更していない read-bound 試験の実測

| commit | source から読んだ byte |
|---|---:|
| 同長改名（未移動） | 52 |
| 末尾削除（未移動） | 0 |
| 先頭削除（64 MiB の生存 payload） | 67,108,916 |
| 異長改名（64 MiB × 2 payload） | 134,217,832 |

APFS の未移動同長改名の free-space 消費は0 byte。
混在の未移動末尾削除＋追加も commit の source 読取0 byte。
移動する混在は生存 record の量＋1 MiB未満、17-byte buffer の隙間あり入力でも隙間を読まない。

## 全件・規模比較の最終結果

| 実行 | 結果 | ログ |
|---|---|---|
| 最終コードの Debug build | 成功（2.91秒） | `.build/p1g-build-final.log` |
| 最終コードの Release library build（testing 無し） | 成功（65.22秒） | `.build/p1g-release-build-final.log` |
| Debug 全件 | 320件、skip 2、失敗0、513.332秒 | `.build/p1g-full.log` |
| Release 全件 | 322件、skip 2、失敗0、442.827秒 | `.build/p1g-release-full.log` |
| 最後の engine 差分に対する release 試験 | 43件、skip 0、失敗0、16.268秒 | `.build/p1g-final-engine.log` |

全件実行の skip は `CompressedTarWriterTests.testEntryLargerThanFourGiBThroughPublicWriterAndIndependentReaders`
（GYOSHUKU_LARGE_TAR_TESTS 未指定）と `ZipUpdaterScaleProbeTests.testScale`（以下で別実行）。
Debug 全件の後に読取範囲・形式共通 snapshot helper の2試験を追加したため、release は322件になった。
release 全件の後に canonical CD の buffer 内 memcpy / offset patch と chunk 単位の取消しを仕上げ、
以下の範囲を最終実装に対して再実行した（43件）。

```sh
swift test --disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none \
  --filter 'ZipRebuildEquivalenceTests|ZipCentralFastPathTests|ZipInPlaceRenameTests|ZipMixedCommitTests|ZipUpdaterOutputModeTests|ZipCommitProgressTests|ZipCommitCancellationTests|ZipDeleteRenameTests'
```

oracle の複製一致、`rebuilt`・`extraFields`・`renamedExtra`・writer の名前予約処理が元のままのことも
c0df9fb の source とスクリプトで比較した。`git diff --check` は成功。

### ZIP-SCALE

基準は `git archive c0df9fb` を `/private/tmp/gyoshuku-p1-baseline-jaybcpoe/GyoshukuKit` に展開し、
同じ親の `KaitoKit` を元の sibling ba42ed8 へリンクした。Package.swift は基準側も変更せず、
公開 API だけを使う ZipUpdaterScaleProbeTests.swift をコピーした。
両版とも `release -Xswiftc -enable-testing -debug-info-format none` で事前ビルドし、
計測は同じ設定に `--skip-build` を付けて行う。


各版1回、100,000件 × 1 byte、stored、同じ機械で基準→新実装の順に実行。単位は ms。
1分 load average は基準の前後3.37→3.16、新実装2.58→2.54（いずれも4未満）。

| 操作 | open 基準→P1-G | remove 基準→P1-G | mutate 基準→P1-G | commit 基準→P1-G |
|---|---:|---:|---:|---:|
| delete_start | 171.877 → 97.678 | 43.081 → 0.008 | 43.081 → 0.008 | 698.569 → 82.810 |
| delete_end | 168.917 → 94.956 | 42.111 → 0.011 | 42.111 → 0.011 | 394.156 → 10.948 |
| rename_same_length | 166.929 → 95.242 | 0.000 → 0.000 | 41.664 → 41.902 | 413.234 → 8.156 |
| replace_file | 166.895 → 98.906 | 40.958 → 0.004 | 85.559 → 49.117 | 716.320 → 15.072 |

両版とも probe 1件、失敗0、skipなし。改名の remove_ms=0 は remove を呼んでいないことを表す。
この比較はライブラリ単体の AC13。アプリの AC15 の合否とは分ける。

```sh
GYOSHUKU_ZIP_SCALE_ENTRIES=100000 swift test --disable-sandbox -c release \
  -Xswiftc -enable-testing -debug-info-format none --skip-build --filter ZipUpdaterScaleProbeTests
```

ログ: `.build/p1g-baseline-scale.log`、`.build/p1g-scale.log`。
uptime 全体（1分・5分・15分）:

```
19:54  4 users, load averages: 3.37 7.73 7.44
19:54  4 users, load averages: 3.16 7.54 7.37
19:55  4 users, load averages: 2.58 6.83 7.12
19:55  4 users, load averages: 2.54 6.75 7.09
```
