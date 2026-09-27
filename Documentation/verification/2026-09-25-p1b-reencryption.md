# P1b / S7: ZIP 再暗号化（2026-09-25）

GyoshukuKit `feature/2026-09-24-review` / `e907e1d` に対する未コミット差分。
P1b-final.md の GyoshukuKit 部分と P1-ORDER-final.md の接点を実装した。
Package.swift、KaitoKit、KaitoFinder は編集していない。commit / tag / release は行っていない。

## 検証するソースと環境

macOS 27.2 (26B5091g)、arm64、Apple Swift 6.4 (swiftlang-6.4.0.34.1)、Swift 言語モード 6。
開始時の sibling KaitoKit は clean な `24311ac5370a8adb54bcb1cbf2c55e961cf5168b`。
実装中に別作業による tar SPI 関連の未コミット変更を検出したため、進行中の live-tree 全件試験を
SIGINT（exit 130）で止め、最終検証を次の sibling 配置へ移した。

```text
/private/tmp/gyoshuku-s7-verification/
  GyoshukuKit/  # 今回の作業ファイルをコピー（.git / .build は除外）
  KaitoKit/     # git archive 24311ac の展開。未コミット変更を含まない
```

manifest の変更や依存の差し替えはせず、既存の `../KaitoKit` path 選択をそのまま使う。
最終の manifest / source / test 102 ファイルが作業ツリーと一致することを照合した。
相対 path、NUL、内容を path 順に連結した SHA-256 は
`5a887e49fe51735ac53ac945b9c4001b1f9b9d3c6540f1936fb33539e32e2b61`。

使用した実ツールは `/opt/homebrew/bin/7zz` 26.03、`/usr/bin/zip`、`/usr/bin/unzip` 6.00、
`/usr/bin/python3` 3.9.6、`/usr/bin/bsdtar` 3.5.3（libarchive 3.7.4）、`/usr/bin/ditto`。
ツール不在を skip にする分岐は追加していない。

通常の `swift build` はユーザーの Clang module cache へ書けず失敗した。
以後は次の環境変数と `--disable-sandbox` を使用した。ユーザーキャッシュと既存の unused public import の警告は残る。

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-s7-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/gyoshuku-s7-swift-cache
swift build --disable-sandbox
swift test --disable-sandbox --filter ZipReencryptionTests
swift test --disable-sandbox --filter ZipReencryptionInteropTests
swift test --disable-sandbox --filter ZipReencryptionBoundaryTests
swift test --disable-sandbox --filter 'ZipReencryptionInteropTests|ZipReencryptionBoundaryTests'
swift test --disable-sandbox --filter 'ZipReencryption|EncryptionTests|ZipDeleteRenameTests|ZipRebuildBoundaryTests|ZipRebuildEquivalenceTests|ZipMixedCommitTests|ZipUpdaterOutputModeTests|ZipCommitProgressTests|ZipModernMethodEditingTests|ZipUpdaterTests|ZipUpdaterIntegrityTests|ArchiveEditingScaleTests|ZipRenamePrivacyTests'
swift test --disable-sandbox
```

開発中のコンパイル修正と試験 helper の引数修正を含め、上記の subset は反復実行した。
初回の外部ツール試験では下記の 7zz / bsdtar の挙動も確認した。
live-tree の focused run は 116 件、skip 3、失敗 0（387.415 秒）。その後に V0 の local サイズ / AES
照合の明示化、変換 0 件＋編集、Unicode Path extra の改名の試験を追加した。
この実行だけを最終結果とはせず、固定した sibling layout で全件を実行した。

## 最終結果

次のコマンドは `/private/tmp/gyoshuku-s7-verification/GyoshukuKit` で、上記の環境変数を指定して実行した。

| コマンド | 結果 | ログ（`/private/tmp/`） |
|---|---|---|
| `swift build --disable-sandbox` | 成功、7.83 秒 | `gyoshuku-s7-isolated-build.log` |
| `swift build --disable-sandbox --scratch-path .build-release -c release --jobs 2` | testing 無しの library build 成功、67.54 秒 | `gyoshuku-s7-isolated-release.log` |
| `swift test --disable-sandbox` | **353 件、skip 5、失敗 0、543.390 秒** | `gyoshuku-s7-isolated-full.log` |
| `swift test --disable-sandbox --filter ZipReencryptionBoundaryTests` | 10 件、skip 3、失敗 0、9.829 秒 | `gyoshuku-s7-isolated-boundary-final.log` |

全件のうち新設は 31 件（実行 28、opt-in skip 3）。残る skip 2 は既存の大容量 tar 試験と
ZIP-SCALE probe。最後の boundary 再実行は、未実行の大容量 fixture の ZIP64 EOCD made-by を
canonical な値にそろえた後のコンパイルと通常境界試験の確認で、製品コードの差分はない。

`git diff --check` は成功。Sources の public / SPI 検索では、新しい公開宣言は
`reencryptExistingEntries(currentPassword:)` と `UpdaterError.reencryptionFailed` のみ。
新しい unchecked Sendable はない。Package.swift と branch / HEAD（`e907e1d`）は変えていない。

## A2–A10 と相互運用の範囲

| 条件 | 試験と確認内容 |
|---|---|
| A2 | writer の stored / deflate × plain / ZipCrypto / AES 入力 × 3 出力、7zz の 5 方式 × 5 暗号状態 × 3 出力、Info-ZIP、ditto、modern、混在、UTF-8 password で保存 payload を入力と byte 比較。observer で pass A / V2 の D2 の件数を確認。圧縮器や spool を呼ぶ経路はない。 |
| A3 | 以下の 123 出力で KaitoKit の全 entry の展開 SHA-256、保存 byte、外部ツールを照合。7zz の legacy method 20 は下記の制約があり、A3 の「全て exit 0」は満たせない。 |
| A4 | 固定 salt で設定 AES / 解除 / AES password 変更が writer の全 ZIP byte と一致。stored → ZipCrypto は local / CD が writer と一致し payload の復号結果も一致。directory の mtime / atime と symlink の時刻は writer の直前に固定する。 |
| A5 | flags、local / CD の version・CRC・方式・サイズ・AES field、extra 順・未知 extra・comment・made-by・属性・時刻、署名有無の descriptor、CD だけの ZIP64、local ZIP64 の小さい entry、CD と local の順序差、隙間、65,535 byte の extra 上限、Unicode Path 改名、salt の非重複を検査。 |
| A6 | wrong / missing password、ZipCrypto verifier の偶然一致、HMAC 改変、出力 payload・CD CRC・AES 版・local CRC / 方式・終端改変、各処理段の取消し、途中 progress の throw、sourceChanged、材料の salt 不一致、導出後の入力 salt 改変、V3 だけが検出する AE-2 encryption-key の誤り。output / snapshot cleanup と原本 byte / inode を確認。未対応 method 96 の成功・拒否、無検査 carry、UTF-8 比較、状態エラー、空・directory のみ・変換 0 件＋編集も検査。 |
| A7 | 改名・削除・追加を異なる順で予約して全 byte 一致。追加は新 options、変換対象外。変換だけは rebuild、大きさが変わる追加付きは stagedRebuild、AES → AES の同サイズ＋追加は rebuildThenAppend。P1-G 既存試験を変更せず実行。 |
| A8 | 65,535 / 65,536 件の設定 ZipCrypto を全件 KaitoKit と 7zz で検証。新設の 4 GiB 上下・converted/carry descriptor 境界・300 MiB の 1 MiB read 上限は opt-in（下記）。 |
| A9 | 平文 directory 100 件＋末尾 AES file の解除で、commit 中の入力 inode の read は末尾 record 以後だけ。出力側の V0–V3 の read は inode で区別。 |
| A10 | 9 MiB stored の変換で total が固定、completed が単調、最後に一致、途中 callback throw で原本維持。導出 1 / 8 thread の byte 一致、observer が commit thread に留まることも確認。変換なしの従来 write-byte 進捗試験を維持。 |

相互運用の 123 出力は、7zz 75、writer 18、Info-ZIP と ditto 6、modern 21、plain/AES 混在 1、
日本語を含む NFC → NFD password の変更 2。7zz 入力の方式は Copy / Deflate / Deflate64 / BZip2 / LZMA、
暗号状態は plain / ZipCrypto / AES128 / AES192 / AES256。writer の corpus は 0 / 19 / 20 / 21 byte、
圧縮データ、directory、symlink。Info-ZIP は `zip -e -y -P` の bit 3 付き入力、ditto は descriptor と
`__MACOSX/._…` を含む。modern は xz、xz-aes、xz-zipcrypto、zstd20/93、zstd-aes20/93。

出力を `7zz t -p…`、方式 0/8/9 の plain / ZipCrypto は `unzip -t -P…`、その他は `unzip -l`、
方式 0/8/12/14 の plain / ZipCrypto は Python `testzip()` で確認する。
bsdtar は stdin から全 entry の `-tvf -`、方式 0/8 の file を `--passphrase … -xOf -` で比較する。

### 外部ツールの制約を出力変更で回避しない

- 7zz 26.03 は method 20 の Zstandard を入力 fixture と変換出力の両方で `Unsupported Method`、exit 2 で拒否する。
  `zstd20` / `zstd-aes20` の 6 出力はこれを失敗 oracle として確認する。残り 117 出力は warning / Headers Error なしで exit 0。
  method 20 を 93 へ書き換えて通すことはしない。KaitoKit は両番号を読み、保存 byte と展開 SHA-256 は一致する。
- Apple の bsdtar は既定で AppleDouble を metadata として結合し、entry を隠す。暗号化した sidecar では展開エラーにもなる。
  元の ditto fixture でも既定の listing は全 entry を表示しない。`--options 'zip:!mac-ext'` を付けて
  KaitoKit の `.expose` と同じ entry 群を列挙・展開する。`zip:mac-ext=0` は無効化にならないことも実測した。

## 未実行・後続の確認

新設した次の 3 試験は `GYOSHUKU_LARGE_ZIP_TESTS=1` のときだけ実行する。今回は未実行。
既存 P1-G の 4 GiB 境界試験は通常 suite の一部として実行しており、これらの代用とはしない。

```sh
GYOSHUKU_LARGE_ZIP_TESTS=1 swift test --disable-sandbox --filter ZipReencryptionBoundaryTests
```

- `testLargeAESSizeCrossingAndRemoval`: +28 byte による保存サイズ 4 GiB 越境、local / CD ZIP64、解除後の byte 復元。
- `testLargeConvertedDescriptorCrossesButCarriedDescriptorRefuses`: 変換する descriptor の越境成功、carry directory の拒否と原本一致。
- `testLarge300MiBPayloadReadsAtMostOneMiB`: 300 MiB payload の入力 read が 1 MiB 以下。

この 3 試験の sparse fixture 4 種類は別途生成し、`7zz l -slt` の metadata 検査だけを実行した
（全て exit 0、`/private/tmp/gyoshuku-s7-sparse-layout.log`）。暗号化・復号の大容量実行を行ったという意味ではない。

KaitoFinder の A11–A16、アプリの probe、100k / 500k の password 操作の速度比較は S8 / オーケストレータの作業。
APFS では clone 後の変更 block だけを書き、APFS 以外では copy＋書き直しで書庫全体を約 2 回書く。
非 APFS の実測は行っていない。計画書の P1b 対象には KaitoKit も加える必要がある（この作業では sibling を編集しない）。
