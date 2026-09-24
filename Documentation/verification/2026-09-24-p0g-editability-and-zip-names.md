# P0-G: 編集可否と ZIP 改名後の旧名（2026-09-24）

対象は GyoshukuKit `feature/2026-09-24-review` の c24cb65 からの作業差分。
依存は `Package.swift` が選ぶ隣接 `../KaitoKit`。KaitoKit / KaitoFinder のファイルは変更しない。

## 編集可否の判定

`ArchiveRewriter.open` と新しい `probe(reader:format:)` は、同じ検査順・拒否理由を使う。
拒否は出力や作業ディレクトリを作る前の `RewriterError.unrepresentable(entry:reason:)`。

| 入力 | 公開情報と判定 |
|---|---|
| 未対応 LHA method | `formatSpecific["headerLevel"]` / `["method"]`。隣接 KaitoKit の `LHAReader.makeDecompressor` が扱う method だけを受理する。`-pm2-` と未知 method は拒否する |
| 未対応 7z coder | KaitoKit が `methodDescription` の coder 列に出す `7z method 0x…` を拒否する。既知 coder の allowlist は複製しない |
| MacLHA | `osID == "m"`、level 1/2、directory 以外だけ `reader.stream(entry).remaining` と header の `uncompressedSize` を比較する。異なる場合は MacBinary envelope が失われるため拒否する |

MacLHA の `m` 印は通常の本文にも付くため、一覧だけでは MacBinary と区別できない。
`probe(entries:format:)` はこの候補も受理し、一覧だけで検査できる他の条件は全て維持する。
MacBinary envelope は検出できないため、既存書庫を編集する呼出側は開いた reader に
`probe(reader:format:)` を別途実行する。`open` も保存前の防御として同じ envelope 検査を行う。
reader 版では通常の本文、空ファイル、MacBinary を unwrap しない level 0 / Unix member を受理する。
resource fork が空でも、envelope を落とす member は拒否する。
MacLHA の判定は KaitoKit に任せ、独自の MacBinary parser は製品コードに追加しない。

KaitoFinder の capability 判定は `ArchiveCapabilities.swift` の単一書庫・分割書庫双方で、
次の呼出しへ切り替える必要がある。この作業では KaitoFinder は変更しない。

```swift
let reader = try ArchiveReader.open(url: url, options: ReaderOptions(appleDoublePolicy: .expose))
try ArchiveRewriter.probe(reader: reader, format: outputFormat)
```

既存の reader が `.expose` なら再解析せずその reader を渡せる。MacLHA は独立 member なので、
この確認で別の active stream を無効化しない。7z の solid stream は開かない。
投影済み entry 一覧を使う保存時の検査や、追加予約の検査は `probe(entries:format:)` を使い続けられる。
これらの一覧に reader がなくても、通常の MacLHA member が拒否されることはない。
両 API とも、全本文の復号・CRC、パスワード、
`WriterOptions`、原本の同一性を保証する検査ではない。

## ZIP の名前が残る経路

local header と CD の全ての 0x7075 を 0xFFFF に変え、本文全体（version・CRC・旧名）を
ゼロで埋める。field 長は変えない。重複、未知 version、長さ 0 の field も同様に扱う。
同長改名では payload の位置と record 長が変わらず、圧縮 payload / descriptor は従来どおり保持する。

他の拡張は [PKWARE APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) と
[Info-ZIP の拡張領域資料](https://sources.debian.org/src/zip/3.0-6/proginfo/extrafld.txt)を確認した。
名前を持つ ZipIt long (0x2605)、Info-ZIP Mac3 (0x334D)、Xceed (0x4F4C / 0x554E)、
形式が未定義の拡張文字コード領域 (0x0008) は、安全な更新方法を実装していないため改名を拒否する。
名前以外の metadata も混在し得るので、field 全体を黙って捨てない。
CD で KaitoKit が許容する未解析の末尾も、非ゼロなら改名を拒否する。
これらは local / CD の片側だけにあっても、追加後の staging 経路でも拒否し、原本を保持する。
対象 entry の削除は record と CD 項目を取り除けるため可能。

削除した record はコピーせず、後続 record を詰め、CD / EOCD の後ろを truncate する。
追加後の `appended.zip` も同じ `ZipRebuild.write` を通る。作業ファイルは既存の `cleanup` で削除する。
rewriter は最終名で header を新規生成し、元の ZIP extra をコピーしない。
改名前の中間予約名も出力しない。

entry / archive comment、Unicode Comment (0x6375)、Unix / ASi のリンク先、
任意の private extra、ファイル本文は独立した内容として保持する。そこに利用者が記録した名前まで
探索・削除する機能ではない。子孫・sidecar・リンク先の改名も従来どおり呼出側の明示操作が必要。

## 回帰検証

- 手組みの LHA level 1/2 MacBinary（data + resource、data のみ、resource のみ）を、
  reader 版 probe と open が拒否し、entries 版は受理する。出力 7 形式、上書き / 別出力を検査し、
  原本・出力先の不変も確認する。
- `-pm2-` / `-lh9-`、未知 7z coder 単独 / Copy との chain を両 probe と open が拒否する。
- 通常 MacLHA、unwrap されない envelope、7z Copy は全出力形式で probe / open / commit と再読取まで通す。
- MacLHA の `m` member でも未対応 method と名前衝突は、entries 版を含む全ての入口で拒否する。
- ZIP の短縮・同長・長い改名、削除、追加の有無、updater / rewriter の組合せで、
  出力全 byte を検索して旧名（UTF-8 / CP932）、中間予約名、削除内容が残らないことを確認する。
  Info-ZIP `unzip -t/-l`、7zz `t/l -slt`、ditto 展開、bsdtar 一覧、KaitoKit の全 entry 読取で照合する。
- 既存の `testCP932RenameInvalidatesUnicodePathExtraWithoutMovingEqualLengthPayload` に全 byte の
  oracle を追加した。変更を許すのは名前・UTF-8 flag・0x7075 の ID と本文ゼロ埋めだけ。
  timestamp、未知 extra、comment、payload の期待値は緩めていない。他の既存 byte-exact 期待値は変更していない。

実行場所は GyoshukuKit の root。Apple Swift 6.4、Swift language mode 6。
ホーム配下の module cache は書込み制限があるため `/tmp` を使い、SwiftPM の sandbox は無効化した。
OS 側の実行環境の制限は変更していない。依存を含む build 成果物は GyoshukuKit の `.build` に置く。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift test --disable-sandbox --filter 'ArchiveRewriter(Probe|SourceProbe)Tests'
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift test --disable-sandbox --filter 'ZipRenamePrivacyTests|ZipDeleteRenameTests.testCP932RenameInvalidatesUnicodePathExtraWithoutMovingEqualLengthPayload'
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift build --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift test --disable-sandbox
git diff --check
```

初回 P0-G の絞込み実行はそれぞれ 6 件 / 3 件、失敗 0。ZIP の末尾拒否テストはその後に追加して全件実行に含めた。
build は成功。ログは `/tmp/gyoshuku-p0g-{probe-tests,zip-tests,build,full-tests}.log`。
初回 P0-G の全件は **297 件、失敗 0、skip 1 件、494.253 秒**。skip は既存の
`CompressedTarWriterTests.testEntryLargerThanFourGiBThroughPublicWriterAndIndependentReaders`
（`GYOSHUKU_LARGE_TAR_TESTS=1` の明示指定が必要）だけ。
ZIP64 の 4 GiB / 65,536 entry、同長改名の I/O / APFS 検査は全件実行に含まれ、成功した。
`git diff --check` も成功。コミットは作成していない。

初回の `swift test --filter 'ArchiveRewriter(Probe|SourceProbe)Tests'` は module cache の書込み拒否で停止した。
cache を移した最初の実行には新テストのコンパイルエラーがあり、修正後に同じ絞込みコマンドを再実行した。

## Correction 1: entries 版と reader 版の責務

entries 版は reader がないことを理由に MacLHA を拒否しない形へ修正した。
既存書庫の capability 判定で reader 版を実行し、投影済み一覧による保存時検査と追加予約は
entries 版で行う。`open` の envelope 検査と他の検査、ZIP の修正は維持する。
回帰テストは両版の責務を分けて検証し、MacLHA の名前衝突・未対応 method の拒否も確認する。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift build --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/gyoshuku-p0g-module-cache swift test --disable-sandbox
git diff --check
```

ログは `/tmp/gyoshuku-p0g-correction1-build.log` と `/tmp/gyoshuku-p0g-correction1-tests.log`。
build は成功。全件は **298 件、失敗 0、skip 1 件、477.923 秒**。
skip は初回と同じ明示指定が必要な大型 tar テストだけ。`git diff --check` も成功した。
兄弟リポジトリは変更せず、コミットは作成していない。
