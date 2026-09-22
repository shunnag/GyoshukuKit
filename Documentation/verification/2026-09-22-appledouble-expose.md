# GyoshukuKit 0.4.2 — AppleDouble sidecar の編集検証

## 環境と対象

- 実行日: 2026-09-22
- 作業場所: `/Users/nagash/Github/GyoshukuKit`
- ブランチ: `release/0.4.2`。開始時点で `main` と同じ `63d5c20`、作業ツリーはクリーン。
- 読み取り依存: 隣接する KaitoKit。Codex の作業時は `main` / v0.8.0（`fc36308`）、オーケストレータの最終検証は `release/0.8.1`（`85e9a71`、0.8.1 として tag 予定）。KaitoKit 側は変更していない。
- macOS 27.2（26B5091g）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64。
- ビルド・検証ログは既存の `.build` 配下を使用した。

通常の `swift build` はユーザー領域へのキャッシュ書き込みが制限され、
`error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output`
で失敗した。キャッシュを `.build` 配下に変更後も SwiftPM の manifest 用 sandbox が
`sandbox-exec: sandbox_apply: Operation not permitted` になったため、以降は次の環境変数と
共通引数で実行した。ビルド成果物の保存先や既存テストの内容は変更していない。

```sh
cd /Users/nagash/Github/GyoshukuKit
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
# swift build / swift test に付けた共通引数:
# --disable-sandbox --cache-path .build/swiftpm-cache \
# --config-path .build/swiftpm-config --security-path .build/swiftpm-security
```

## 修正内容と fixture

`Sources/` の `ArchiveReader.open` / `ReaderOptions(` は updater の入力、updater の追加後、
rewriter の入力の3箇所だけで、すべて `appleDoublePolicy: .expose` を指定した。
書庫内の sidecar と index を保ち、`.merge` による index の詰め直しや resource fork の擬似 entry を
編集に持ち込まない。rewriter の共通検査は `formatSpecific["fork"] == "resource"` を拒否する。

`Tests/Fixtures/appledouble/` の `finder.zip.b64`、`mac.tar.b64`、`SHA256SUMS` は KaitoKit 側の
同名ファイルと byte 単位で一致した。README も複製し、末尾に出自と生成スクリプトの場所を追記した。
base64 復号後の SHA-256 は複製した `SHA256SUMS` と一致する。

| 書庫 | SHA-256 |
| --- | --- |
| finder.zip | `0a7dfb5c9865a4d3ec8441bcf974d6c7d9955bdc92cc30b89accc2e6a6e24599` |
| mac.tar | `4b44049f32e7ca3f649b1a60bc43b2683f0c04063e4bb4581aefb9beefc7084d` |

新規テストは `#filePath` からリポジトリ内の fixture を参照し、SwiftPM の resources 宣言も
隣接 KaitoKit の直接参照も使用しない。

## 修正前の失敗再現

修正と新規テストを追加した後、2ファイルを `.build/verification/appledouble-expose/` に
`cp` で退避し、reader の3箇所の `.expose` 指定だけを一時的に除去した。
擬似 entry を拒否する rewriter の検査とテスト側の `.expose` 指定は残した。

```sh
cp Sources/GyoshukuKit/ArchiveUpdater.swift .build/verification/appledouble-expose/ArchiveUpdater.swift.expose
cp Sources/GyoshukuKit/ArchiveRewriter.swift .build/verification/appledouble-expose/ArchiveRewriter.swift.expose
trap 'cp .build/verification/appledouble-expose/ArchiveUpdater.swift.expose Sources/GyoshukuKit/ArchiveUpdater.swift; cp .build/verification/appledouble-expose/ArchiveRewriter.swift.expose Sources/GyoshukuKit/ArchiveRewriter.swift' EXIT
python3 - <<'PY'
import re
from pathlib import Path
for name, count in [('ArchiveUpdater.swift', 2), ('ArchiveRewriter.swift', 1)]:
    path = Path('Sources/GyoshukuKit') / name
    changed, replacements = re.subn(r',\n[ \t]+appleDoublePolicy: \.expose', '', path.read_text())
    assert replacements == count, (name, replacements)
    path.write_text(changed)
PY
swift test --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security \
  --filter AppleDoubleSidecarEditingTests/testFinderZIPUpdaterPreservesSidecarsAcrossRemoveAndAdd \
  > .build/verification/appledouble-expose/before-expose.log 2>&1
repro_status=$?
tail -20 .build/verification/appledouble-expose/before-expose.log
exit "$repro_status"
```

終了コードは **1**。1件実行、失敗1件、skip 0件。失敗行をそのまま記録する。

```text
/Users/nagash/Github/GyoshukuKit/Sources/GyoshukuKit/ArchiveUpdater.swift:80: error: -[GyoshukuKitTests.AppleDoubleSidecarEditingTests testFinderZIPUpdaterPreservesSidecarsAcrossRemoveAndAdd] : failed: caught error: "invalidArchive("KaitoKit の entry 数と EOCD が一致しません")"
Executed 1 test, with 1 failure (1 unexpected) in 0.155 (0.156) seconds
```

実行したシェルの終了時に `trap` の `cp` で両ファイルを復元した。
その後、両ファイルが退避した修正版と `cmp` で一致することと、`rg` で3箇所の指定が戻ったことを確認した。
`git checkout -- <file>` は使用していない。

## 回帰テストの確認範囲

追加した `AppleDoubleSidecarEditingTests` は次の4件。

1. `testFinderZIPUpdaterPreservesSidecarsAcrossRemoveAndAdd`:
   Finder ZIP の12 entry と sidecar、格納順の index を確認する。`folder/plain.txt` だけを削除して
   commit し、sidecar を含む他の名前と本文の SHA-256 が変わらないことを確認する。
   さらに reopen して `added.txt` を追加・commit し、`.expose` reader と `unzip -t` で検証する。
2. `testFinderZIPUpdaterPreservesSidecarsWhenRemovingAndAddingTogether`:
   同じ削除と追加を1回の commit で行い、staged reader を使う再構築経路でも名前・本文を保持する。
   こちらも `unzip -t` が終了コード0で成功する。
3. `testMacTARRewriterPreservesSidecarNamesAndPayloadHashes`:
   macOS tar を `.tar` へ書き直し、`._folder`、`folder/._rsrc.txt`、`folder/._plain.txt`、
   directory 用・子孫用の sidecar を含む10 entry の名前と、全通常ファイル本文の SHA-256 を比較する。
4. `testRewriterProbeRefusesMergedResourceForkEntries`:
   ZIP と tar の既定 `.merge` reader の一覧を `probe(entries:format: .zip)` に渡し、
   resource fork の擬似 entry を指定の `RewriterError.unrepresentable` と案内文で拒否する。
   同じ入力を `.expose` で開いた一覧は受理する。

ZIP / tar の出力には `..namedfork` を含む entry がないことも確認する。

## 修正後のビルド・全件テスト

3箇所の `.expose` を復元した状態で、次のコマンドを順番に実行した。
各コマンドは出力をログに保存し、終了コードを確認してから末尾を表示した。

```sh
swift build --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security \
  > .build/verification/appledouble-expose/build.log 2>&1
tail -3 .build/verification/appledouble-expose/build.log

swift test --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security \
  > .build/verification/appledouble-expose/all-tests.log 2>&1
tail -5 .build/verification/appledouble-expose/all-tests.log

swift test --disable-sandbox --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config --security-path .build/swiftpm-security \
  --filter AppleDoubleSidecarEditingTests \
  > .build/verification/appledouble-expose/filtered-final.log 2>&1
tail -20 .build/verification/appledouble-expose/filtered-final.log
```

| 検証 | 終了コード | 実行件数 | 失敗 | skip |
| --- | --- | --- | --- | --- |
| `swift build` | 0 | — | — | — |
| `swift test` 全件 | 0 | 241 | 0 | 1 |
| 新規4件の再実行 | 0 | 4 | 0 | 0 |

ビルド結果:

```text
[5 / 10] GyoshukuKit
[8 / 11] GyoshukuKit
Build complete! (0.70秒)
```

全件の XCTest 集計（約7分53秒）:

```text
Test Suite 'All tests' passed at 2026-09-22 09:02:58.103.
Executed 241 tests, with 1 test skipped and 0 failures (0 unexpected) in 473.009 (473.045) seconds
```

skip は既存の `CompressedTarWriterTests.testEntryLargerThanFourGiBThroughPublicWriterAndIndependentReaders`
だけで、理由は `Set GYOSHUKU_LARGE_TAR_TESTS=1 for the 4 GiB streaming check`。
既存テストの期待値・規約は変更していない。
ログ末尾には別の Swift Testing runner の `0 tests` も表示されるため、件数は上記 XCTest 集計から記録した。

新規テストの再実行結果:

```text
Test Suite 'AppleDoubleSidecarEditingTests' passed at 2026-09-22 09:03:28.710.
Executed 4 tests, with 0 failures (0 unexpected) in 0.238 (0.239) seconds
```

ZIP の独立した整合性検査も両経路で成功した。

```text
REFERENCE appledouble-zip-remove-then-add/unzip-t: exit 0;     testing: added.txt                OK | No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/.build/verification/appledouble-zip-remove-then-add/finder.zip.
REFERENCE appledouble-zip-remove-and-add/unzip-t: exit 0;     testing: added.txt                OK | No errors detected in compressed data of /Users/nagash/Github/GyoshukuKit/.build/verification/appledouble-zip-remove-and-add/finder.zip.
```

## 差分確認

`git diff --check` は成功。`git status --short --untracked-files=all` と `git diff --stat` で、
変更は Package.swift、2つの編集実装、CHANGELOG、README の依存版表記、新規テスト、
fixture 4ファイル、本検証記録の計11ファイルに限られることを確認した。
新規6ファイルは未追跡のまま残しており、通常の `git diff --stat` には既存5ファイルだけが表示される。
KaitoKit の `git status --short` は空で、commit / push は行っていない。

## オーケストレータによる独立検証

通常のシェル（sandbox なし）で、KaitoKit `release/0.8.1`（`85e9a71`）を隣接 checkout として `swift build` と `swift test` を実行した。
build 成功、XCTest 241 件、skip 1（既存の 4 GiB tar）、失敗 0。Package.swift の tag 参照は `from: "0.8.1"` に上げた
（0.8.1 は 0.8.0 のリリースレビュー修正 R1〜R14 を含む。GyoshukuKit 自身は `.expose` で開くため R6〜R8 の AppleDouble merge の修正には
依存しないが、利用側が解決する KaitoKit を修正済みの版に揃える）。
