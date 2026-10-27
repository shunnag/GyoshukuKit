# セキュリティ・堅牢性監査の検証（2026-10-26）

`Documentation/2026-10-26-audit-instructions.md` の指示書に沿って実施した。HEAD は `6a0941a`（version 0.13.0）、
`../KaitoKit` は branch `fix/security-audit-2026-10-26`（検査開始時 `32205fc`、検査中に 0.17.0 候補の修正が入った。
第 6 節）。

**体制**: 6 領域に 1 エージェントずつ（読解と read-only コマンドのみ。ビルド・計測・commit は禁止）、
確認された所見ごとに敵対的反証 2 観点（`spec-conformance` と `arithmetic`）で合計 36 エージェント。
実測は orchestrator が逐次実行した（並列計測は数値が汚れるため）。

## 1. 判定表

重大度は「既定設定で誰が引き起こせるか」で決めた。`判定` 欄は反証後の最終判定。

| ID | 主張 | 判定 | 実リスク | 重大度 | 対応 |
|---|---|---|---|---|---|
| 4.2-C | GyoshukuKit が書けて KaitoKit が読めない名前がある（path 要素数） | **正しい（実証済み）** | 自分が書いた書庫を自分の reader で読めない。悪意ある入力は不要で、呼出側が長い名前を渡すだけ | 低（相互運用の自傷） | **修正** |
| 4.2-G | 長い名前で `reserveEntryName` の prefix 構築が O(n²) | 正しい | 同上の名前でのみ到達 | 低 | 4.2-C の guard で同時に解消 |
| G-3 | tar の拡張 header payload を宣言長ぶん丸ごと確保し、独立の上限が無い | 部分的 | KaitoKit の open が先に 16 MiB で拒むため順序依存の間接的な上限しかない | 低 | **修正**（walk 自身に上限） |
| GK43-6 | `.gyoshuku-source-<UUID>` の mode が原本のまま（clone 3 箇所のうちここだけ 0600 に絞らない） | 正しい | world-readable な原本を編集中、同じ mode の複製が利用者の directory に現れる | 低 | **修正** |
| GK43-1 | in-place 編集の公開が原本の set-ID bit を復元する | 正しい（仕様） | 原本に無い bit は増えない。macOS は Mach-O 以外の set-ID を honor せず、`.sfxPrefix` は拒否済み | なし | 文書化 |
| GK43-4 | `replaceItemAt` 後に所有者が編集者に変わる | 正しい（仕様） | group 書込可 directory で他人の書庫を編集すると所有者が黙って変わる | 低 | 文書化 |
| GK43-7 | `.gyoshuku-source-*` が SIGKILL で残る | 正しい（仕様） | 自動掃除は他 process の作業中の実体を消す危険があるため library では行わない | 低 | 文書化 |
| GK43-10 | in-place 公開に quarantine が外れる窓がある | 正しい | その窓で process が死ぬと公開済み書庫が quarantine を失う | 低 | 文書化（任意の hardening として記録） |
| G-1 / G-2 | LHA / RAR 入力は stream 生成時に圧縮 member 全体を malloc し、`maxEntrySize` が唯一の門番 | 正しい | 上限を外しているのでピーク RSS が入力ファイル長に比例（増幅率 1:1） | 低 | 文書化 |
| G-4 | 敵対的 LHA が `ArchiveRepresentability` に stream を無制限に開かせる | 部分的 | `maxEntryCount` 100 万が唯一の縛り。復号は伴わない | 低 | 文書化（検査順の入替は将来の最小案として記録） |
| G-6 | scratch の容量上限が無く ENOSPC が唯一の上限 | 正しい（仕様） | `design.md:431-432` が明記した製品判断 | 低 | 文書化 |
| GK-4.4-C3 | 敵対的 distinct-salt 7z は password 付きの編集 3 経路で `limitExceeded` に倒れる | 正しい | 編集できない入力が増えるだけ（正規書庫は無影響） | 低 | 文書化 |
| GK-4.4-C4 | `ArchiveRewriter` が `limitExceeded` を `invalidArchive` に写す | 正しい | `RewriterError` の payload に `KaitoError` の説明が入るので情報は落ちない | なし | 対応不要（反証 1/2・呼出側の実害が未確認） |
| GK-4.4-C5 / C6 | carry folder が入力の salt を継承する / 暗号化の予約なしの部分削除で混在 password の 7z ができる | 正しい（設計判断） | `design.md:1157` に記載済み | 低 | 文書化済み（再報告しない） |
| GK-4.4-C8 | `ZipReencryption` が entry ごとの鍵素材を検証終了まで保持（100 万 entry で約 82 MB） | 部分的 | `maxEntryCount` でのみ縛られる | なし | 対応不要 |
| GK-4.4-C1 | GyoshukuKit が書いた 7z が 0.17.0 の KDF 予算に引っかかる | **誤り** | saltSize 0 なので folder 数に関係なく導出 1 回（実測で確認） | — | — |
| GK-4.4-C2 | 編集出力の self-check が 0.17.0 の予算で失敗する | **誤り** | `decode` 集合が carry folder を除外する（`SevenZipUpdater+SelfCheck.swift:63-66`） | — | — |
| GK-4.4-C7 | 鍵素材の zero 化は書き込み側では意味がある | **誤り** | `WriterOptions` が値型で配布され copy-on-write のため権威ある単一 buffer が無い（KaitoKit 側と同じ結論） | — | — |
| GK-4.4-C9 | `testingRandomBytes` TaskLocal が production で到達可能 | **到達不能** | internal で `@_spi` も無く、`withValue` の呼出は Tests のみ | — | — |
| 4.2-A | set-ID をマスクしないことが文書化されている | **誤り** | マスクしないのは事実だが、文書に記載が無かった | 低 | **文書化**（本検査で追加） |
| 4.2-B / 4.2-D / 4.2-F | symlink target 逐語格納 / 制御文字と bidi を通す / 変換時の set-ID 継承 | 正しい（仕様） | 書き込み library として展開側に委ねるのが正しい | なし | 文書化 |
| 4.2-E | `addDirectoryChildren` の深さ無制限再帰で stack を使い切る | **誤り** | PATH_MAX が先に効き、到達できる深さは 446（相対 path の実測で確認） | — | — |
| G-5 | 「すべての open 箇所で上限を外している」 | 部分的 | 9 箇所は外しているが `CompressedTarUpdater` は呼出側の reader を使う | なし | 記録のみ |
| G-7〜G-11 | 全部読む API を呼ぶ / 宣言 100 GiB が 100 GiB の確保になる（4 経路） | **誤り** | `stream` のみを使い、4 経路すべて固定 buffer（4 MiB / 256 KiB / 片）で宣言サイズは確保に入らない | — | — |
| G45-1〜G45-8 | PPMd の model memory が `memoryLimit` を無視 / `compressionThreads: 1024` で thread 爆発 / 宣言だけ巨大な member の buffer ほか | 誤り・仕様・到達不能 | 公開 doc（`WriterOptions.swift:144-145`、`:158`）が非対称の意図を明記。clamp は `resolve` で効く | なし〜低 | 対応不要 |
| CI-01〜CI-12 | `tested-tree` artifact gate の抜け穴ほか 12 件 | 誤り・仕様・対応不要 | gate の最終判定は content-addressed（tree hash に ci.yml 自身を含む）で、例外は必ず full run に倒れる。外部 PR は 0 件（`gh pr list` で確認） | なし | コメント 1 行 |

## 2. 実証した事実（実測値）

計測は Mac mini M4（macOS 27.2、Xcode 27.0）で、**修正前の clean checkout**（GyoshukuKit `6a0941a` +
KaitoKit `main` `143003a`）に対して行った。計測器は使い捨ての SwiftPM package（`ArchiveWriter` で書き、
`KaitoKit.ArchiveReader` で読み戻して印字するだけ）。

### 2.1 自傷: 書けるが読めない名前（4.2-C）

```
[components/1023] 書込み成功 bytes=4222 要素数=1023
[components/1023] format=zip entries=1   ← 読取成功
[components/1024] 書込み成功 bytes=4226 要素数=1024
[components/1024] format=zip entries=1   ← 読取成功
[components/1025] 書込み成功 bytes=4230 要素数=1025
[components/1025] KaitoKit 読取 ERROR: Read limit exceeded: ZIP path component count
[components/2000] 書込み成功 bytes=8130 要素数=2000
[components/2000] KaitoKit 読取 ERROR: Read limit exceeded: ZIP path component count
```

`String(repeating: "a/", count: 1024) + "f.txt"` は 1,025 要素・2,053 byte で、`normalizedPath` の 5 条件
（`Writer/ArchiveWriter.swift:619-622`）をすべて通る。KaitoKit は 4 形式すべてで `maxPathComponentCount`（既定 1,024）
で拒否する（`ZipCentralDirectoryParser.swift:220-222`、`TarEntryPublisher.swift:29-33`、
`SevenZipReader.swift:519-527`、`LHAEntryPublisher.swift:93-96`）。空要素は落ちるので境界はちょうど 1,024。

### 2.2 ディスクの mode をマスクせず格納する（4.2-A）

```
[modes/zip] - name="setuid.bin" mode=4755 kind=file     [modes/zip] - name="sticky.bin" mode=1644 kind=file
[modes/tar] - name="setuid.bin" mode=4755 kind=file     [modes/tar] - name="sticky.bin" mode=1644 kind=file
[modes/7z]  - name="setuid.bin" mode=4755 kind=file     [modes/7z]  - name="sticky.bin" mode=1644 kind=file
```

`chmod 4755` / `chmod 1644` したファイルを追加すると、3 形式すべてで set-ID と sticky がそのまま格納され、
KaitoKit で読み戻せる。これは書き込み library として正しい（展開側が決める）が、文書に記載が無かった。
KaitoKit 0.17.0 は既定で**file の** set-ID を落として展開する（`ExtractionOptions.preserveSetUserIDBits`）。

### 2.3 symlink target を無検査で逐語格納する（4.2-B）

```
[symlink/tar] - name="absolute" kind=symlink link="/etc/passwd"
[symlink/tar] - name="escape"   kind=symlink link="../../../Library/LaunchAgents/x.plist"
```

絶対 path も `../` 脱出もそのまま入る。symlink を追従しないこと（`lstat` + `O_NOFOLLOW`、
`ArchiveWriter.swift:400-404`、`:465-468`）と、lstat→open の race を `DiskSignature.matches` で検出すること
（`:487-490`）は既に実装済みで、再報告していない。

### 2.4 名前の制御文字を通す（4.2-D）

```
[bidi/0] 書込み成功 name="invoice\u{202E}cod.exe"  → KaitoKit で読み戻せる
[bidi/1] 書込み成功 name="tab\tname.txt"           → 同
[bidi/2] 書込み成功 name="newline\nname.txt"       → 同
```

UI を持たない library としては通すのが正しい。ただし**改行を含む名前が実際に作れる**ことは、
KaitoFinder の確認ダイアログへの行注入（同日の KaitoFinder 検査 4.6-F1）と cooViewer の警告文への行注入
（同 4.4-F1 / F6 / F10）の入力が現実に存在することを意味する。表示側で畳むのが正しい層である。

### 2.5 到達できる directory の深さ（4.2-E の反証）

相対 `mkdir d && cd d` の反復で `stop at depth 447 abslen 1025 errno 63`（`ENAMETOOLONG`）。
walk 可能な深さは 446 で、「数千段の再帰で stack を使い切る」には到達しない。

## 3. 修正（0.14.0 で commit 済み。第 7 節に検証を追記した）

1. **4.2-C / 4.2-G**: `Writer/ArchiveWriter.swift` の `normalizedPath` の guard に
   `components.count <= ReadLimits().maxPathComponentCount` を追加。前例は
   `SevenZip/SevenZipHeaderSerializer.swift:17`・`:143`（既に `ReadLimits().maxMetadataSize` を書き込み側の上限として使う）。
   `WriterError` に case は足していない（SemVer 影響なし）。
2. **G-3**: `Tar/TarLayout.walk` に `headerMetadataLimit`（既定 `ReadLimits().maxMetadataSize`）を足し、
   拡張 header payload の宣言長を検査する。internal API なので SemVer 影響なし。
3. **GK43-6**: `SegmentedOutput/ArchiveSourceSnapshot.swift` の clone 直後に mode を 0600 へ絞る。
   `FileIdentity.checkUnchanged`（`ArchiveOwnedFile.swift:24-30`）が `mode == info.st_mode` を比較するため、
   fchmod と identity の取得順序を整合させている。

いずれも**修正前に失敗する回帰テスト**を添えた。

## 4. 文書化した事実（コード変更なし）

`Documentation/design.md` と `Documentation/usage.md` に次を追記した。

- in-place 置換は新しい inode を公開する。mode は原本から復元する（高位 bit を含む）が所有者は引き継がず、
  原本への hard link は切れる（GK43-1 / GK43-4）。
- ディスク上の mode を書庫へそのまま格納する（set-ID と sticky を含む）。symlink target も検査せず逐語格納する。
  展開時の扱いは読取側の方針に従う（4.2-A / 4.2-B）。
- 異常終了で `.gyoshuku-source-*` / `.gyoshuku-staged-*` / `.gyoshuku-rewrite-*` が残る。自動掃除は行わない（GK43-7）。
- 入力書庫の AES salt が folder ごとに異なる場合、復号を伴う編集は KaitoKit の鍵導出予算を folder ごとに消費する。
  0.17.0 候補の既定（`16 × 2^24` SHA-256 rounds、**reader と password の組ごと**）では cyclesPower 19 で
  distinct salt 512 個・24 で 16 回が上限なので、それを超える敵対的入力は編集できない。GyoshukuKit と 7-Zip が
  書いた書庫は saltSize 0 で導出 1 回なので無影響（GK-4.4-C3 / C1、第 5 節の実測）。
- LHA / RAR 入力は stream 生成時に圧縮 member 全体を memory に載せ、上限を外しているためピーク RSS が
  入力ファイル長に比例する（G-1 / G-2）。
- scratch は ENOSPC が唯一の上限である（G-6。`design.md:431-432` の既存方針を補強）。
- `.github/workflows/ci.yml` の gate コメントに、一致判定が tree hash（ci.yml 自身を含む）であることを 1 行追加（CI-01）。

## 5. KaitoKit 0.17.0 の 4 変更に対する影響（必須の横断チェック）

| 変更 | 影響 | 根拠 |
|---|---|---|
| `maxSevenZipEntryKDFWork`（既定 `16 × 2^24`、reader × password 単位） | **自傷なし**。自分の出力は saltSize 0 で導出 1 回。敵対的 distinct-salt 入力の編集だけが拒否され得る | `SevenZip/SevenZipAESEncryptor.swift:17-18` が無条件に `0x53, 0x0F`（cyclesPower 19 / saltSize 0 / ivSize 16）。orchestrator の実測で 7-Zip 製 200 folder でも導出 1 回 |
| `maxStuffItXKDFWork`（既定 `2^22`） | **無関係** | StuffIt X を書かず、読取側でも触らない（`grep` で 0 件） |
| `ExtractionOptions.preserveSetUserIDBits` | **無関係** | `ExtractionOptions` は Sources / Tests に 1 箇所も無い |
| resource fork entry の metadata | **無関係** | 同上（KaitoKit の展開器を使わない） |

依存の pin: `Package.swift:12-20` は隣に `../KaitoKit` があれば path 依存、無ければ `.upToNextMinor(from: "0.16.0")`
（= 0.17.0 未満）。したがって **CI と下流には 0.17.0 は見えない**（**検査時点の事実**。0.17.0 の公開後、
GyoshukuKit 0.14.0 で範囲を `.upToNextMinor(from: "0.17.0")` に上げた）。0.17.0 の型や既定値に依存する回帰テストは、
0.17.0 が tag 公開され `Package.swift` の範囲を上げるまでローカルでしか検証できない。
CI の gate は KaitoKit の tag 一覧の sha256 を取り込むので、**0.17.0 の公開は skip を無効化する**（CI-04 で確認）。

## 6. 検査の限界

- エージェントはビルド・計測・GUI 駆動を禁止されていたため、所見の多くは「コード読解で確定」である。
  実測したのは第 2 節の 5 件（orchestrator が実行）と、エージェントが read-only で行った `sysctl` / `mkdir` の深さ測定のみ。
- `swift test` の全 suite は修正適用後に orchestrator が実行した（結果は本記録の末尾に追記する）。
- **検査中に `../KaitoKit` の作業ツリーが変わった**（予算の既定が `4 × 2^24` → `16 × 2^24`、意味論が reader 単位 →
  reader × password）。第 1 節の判定は新しい現物に合わせてある。
- 現実の 7z writer が folder ごとに異なる salt を書くか（= 0.17.0 の既定が正当な書庫を壊すか）は
  **未検証**（GK-4.4-C11）。GyoshukuKit と 7-Zip は saltSize 0 であることを実測で確認したが、他の実装は
  clean-room 規則により source を読めないため黒箱でも確認できていない。
- `ZipReencryption` の鍵素材の実ピーク（100 万 entry で約 82 MB）は計算値で未実測。
- 4.3 の `replaceItemAt` が新 inode の gid を原本の gid に戻すかは未実測（JXA から呼べないため）。

## 7. 検証（0.14.0）

本記録の修正 3 件は GyoshukuKit 0.14.0 として公開した。

- ローカル: `swift test` 全 suite **921 tests / 49 skipped / 0 failures**（KaitoKit 0.17.0 を解決した状態）。
  修正後に path 成分 1,024 個は書けて読め、1,025 個と 2,000 個は書込み時に `WriterError.invalidPath` で
  拒否されることを Mac mini で実測した（第 2.1 節の修正前の出力と対になる）。
- CI: PR #21（監査修正）と #23（KaitoKit 0.17.0 追従）で全 check pass。
  build-and-test 2 shard が約 1 時間、macos-26-runtime 2 shard も約 1 時間。
- タグ前レビュー: 4 観点（修正の正しさと回帰 / 公開挙動と SemVer / 文書と版の整合 / CI と依存の pin）に
  1 エージェントずつ、所見ごとに敵対的反証 2 観点で計 26 エージェント。**コードの blocker は 0 件**で、
  3 件の修正はいずれも正しいと確認された（guard の境界がちょうど 1,024 で reader 4 形式と一致すること、
  `headerMetadataLimit` が拡張 header 5 型すべてに効くこと、`fchmod` 後に identity を取り直すことで
  `ArchiveOwnedFile`（fd を保持しない struct）と `ArchiveFileSource(duplicating:)` の fd 寿命が壊れないこと）。
  生存した所見は文書とリリース体裁で、0.14.0 の release commit で反映した:
  path 成分の上限を `### 修正` から `### 変更`（動作変更）へ移し、`Documentation/formats.md` の名前の拒否一覧に
  成分数の規則を追記し、README / `design.md` / `installation.md` の版の記述を揃えた。
- 残した follow-up（0.14.0 では直さない）: `ArchiveSourceSnapshot` の clone 直後から `fchmod` までの窓では
  複製が原本の mode のまま存在する。完全に閉じるなら `ArchiveRewriter` と同じく 0700 の directory 内に
  clone する形に寄せる。
