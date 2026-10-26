# GyoshukuKit セキュリティ・堅牢性監査の指示書（2026-10-26）

この文書は**検査の手順書**であり、検査結果ではない。結果は
`Documentation/verification/2026-10-26-security-audit.md` に、本プロジェクトの検証記録の形式
（`YYYY-MM-DD-<topic>.md`、日本語、生データは同じ stem の兄弟ファイルか subdirectory に置く）で書く。

**この検査は KaitoKit 0.17.0 のリリース判定の前提条件**である。KaitoKit 側（`../KaitoKit`、branch
`fix/security-audit-2026-10-26`）の修正は、KaitoFinder・GyoshukuKit・cooViewer の 3 プロジェクトの検査が
終わるまでリリースしない。

## 1. 背景: KaitoKit 側で何が見つかったか

2026-10-26 に外部の AI エージェントが KaitoKit の監査報告（34 指摘）を提出し、独立検証（81 エージェント）で
次が確定した（詳細は `../KaitoKit/Documentation/verification/2026-10-26-security-audit.md`）。

- 本物だったのは **鍵導出の CPU 枯渇** 2 件（7z: salt が異なる folder ごとに予算未課金の導出 ≈ 0.42 秒/回で
  無制限 / StuffIt X: 導出が二次で 225 byte の書庫が 425 秒）。いずれも password を渡した時だけ発生。
- **展開 metadata の意味論** 2 件（setuid/setgid を既定で復元 / resource fork entry が既存ファイルの mode と
  mtime を書き換え）。
- bidi 制御文字による表示偽装、CLI の argv に password。
- 誤り 3 件、既に文書化済みの設計判断が複数、到達不能 2 件。

**GyoshukuKit は書き込み側なので、同じ観点を裏返して使う**（第 4 節）。

## 2. 検査の方法（ここが本題）

1. **主張を鵜呑みにしない。** 本書の問いも含め現物のコードで確認する。行番号は HEAD で検証する
   （本書は 2026-10-26 の `6a0941a` / version 0.13.0 時点）。
2. **再現できたものだけを「実証済み」と呼ぶ。** 細工入力を自分で作り、実際に走らせ、`/usr/bin/time -l` の
   実測と実出力を記録に貼る。
3. **既に守られていないかを先に探す。** 各領域の「既にある緩和策」を読み、再報告しない。この repository は
   **防御が厚く、反証になる答えが多い**ことを期待してよい（特に第 4.3 節）。
   「設計判断として文書化済み」「到達不能」は正しい結論であり成果である。
4. **重大度は「既定設定で誰が引き起こせるか」で決める。** GyoshukuKit は library なので、
   「悪意ある**入力書庫**」「悪意ある**ディスク上のファイル**」「呼出側の異常な option」を区別する。
5. **提案は最小の変更に絞る。** 「文書化だけ」「対応不要」も正当。公開 API（`WriterOptions` など）に
   触れる提案は SemVer 影響を書く。
6. **過大評価を自分で疑う。** 元の監査は「高」2 件を挙げて両方外した。重大度を上げる前に反証を一度書く。

## 3. 前提: KaitoKit 0.17.0 候補の変更とこのプロジェクトへの影響

| 変更 | GyoshukuKit への影響 |
|---|---|
| `maxSevenZipEntryKDFWork`（既定 `4 × 2^24` rounds、reader 単位） | **要確認（第 4.4 節）**。自分が書いた書庫を読み戻せなくなる自傷が無いか |
| `maxStuffItXKDFWork`（既定 `2^22`） | StuffIt X を書かないなら無関係。読取側で触るかを確認 |
| `ExtractionOptions.preserveSetUserIDBits` | **無関係**。`ExtractionOptions` は Sources / Tests に 1 箇所も無い（grep で確認してから記録） |
| resource fork entry の metadata | **無関係**（同上） |

依存の pin: `Package.swift:12-20` は、隣に `../KaitoKit` があればその path 依存、無ければ
`.upToNextMinor(from: "0.16.0")`（= 0.17.0 未満）。`Package.swift:9-10` が理由を書いている（`@_spi` 利用と、
公開 API に KaitoKit 型が出るため）。したがって **CI と下流には 0.17.0 は見えないが、ローカルの
`swift build` / `swift test` は既に `../KaitoKit` の checkout（現在 audit branch）に対して動く**。
検査開始時に `git -C ../KaitoKit log --oneline -1` を記録せよ。

## 4. 検査領域（優先順）

### 4.1 上限を外した読取経路

GyoshukuKit は**すべての open 箇所**で `maxEntrySize` と `maxTotalUncompressedSize` を `.max` にしている
（`Sources/GyoshukuKit/Zip/Update/ArchiveUpdater.swift:71` ほか）。書き込み側として正当な判断だが、
KaitoKit の triage では「上限があるから無害」と退けた主張がいくつもあった。ここではその上限が無い。

起点: `Zip/Update/ArchiveUpdater.swift:71`（`readerOptions`）、`:147`（source ZIP の open）、
`Editing/ArchiveRewriter.swift:105`、`SevenZip/SevenZipEditModel.swift:108`、`SevenZip/SevenZipUpdater.swift:70`、
`SevenZip/SevenZipUpdater+SelfCheck.swift:48`（**出力**を password 付きで開き直す）、`Tar/TarUpdater.swift:67`、
`Editing/ArchiveRepresentability.swift:23`、`:84-92`。

答えるべき問い:
- 2 つの上限が無い状態で、敵対的な書庫を編集するときに RAM と scratch を縛るのは何か。残っている上限を
  形式ごとに名前で挙げる（`maxEntryCount` 100 万、`maxMetadataSize` 16 MiB、`maxTotalMetadataSize` 256 MiB、
  `maxDictionarySize`、`maxInMemorySize` 1 GiB、`inMemorySingleFileLimit` 64 MiB）。
- 丸ごと memory に載る経路はあるか。ZIP の stored record copy、tar member copy、7z folder の再 encode、
  LHA member splice の 4 つで証明する。**100 GiB と宣言された 1 entry が 100 GiB の確保にならないこと**。
- KaitoKit の `read` / `data`（全部読む API）を呼ぶ箇所はあるか、`stream` だけか。
- `ArchiveRewriter.open` → `validateRepresentability` は MacLHA 候補で entry ごとに stream を開く
  （`ArchiveRepresentability.swift:84-92`）。敵対的 LHA は stream をいくつ開かせられるか。
- `appleDoublePolicy: .expose` を全箇所で設定している。`fork == "resource"` の疑似 entry を拒否しない
  updater はあるか（rewriter は `:23` で拒否している）。

再現案: 中央 directory が `uncompressedSize = 2^63` と宣言し payload が 10 byte の ZIP を作り、
`ArchiveUpdater` で 1 file 追加して commit。peak RSS と出力サイズを測る。metadata 上限が許す最大 entry 数の
7z で add+commit し、wall と RSS を記録して「上限の中での最悪値」を数値にする。

既にある緩和策: 上限撤去は各箇所に日本語コメントで意図が書かれている（`ArchiveUpdater.swift:70`）。
他の `ReadLimits` は KaitoKit 既定のまま。

### 4.2 書庫に書き込む metadata（KaitoKit の指摘の裏返し）

KaitoKit は setuid/setgid を**復元する**ことを問われた。GyoshukuKit は**何を書庫に入れるか**を決める側である。
ディスクの `st_mode` は**マスクせず**格納し（setuid/setgid/sticky が書庫に入る）、symlink target は
**検査せず逐語**格納する（絶対 path も `../` 脱出も入る）。

起点: `Writer/ArchiveWriter.swift:422`（directory）、`:477`、`:484`（regular file）、`:719`（batch）、
`:424-431`（S_IFLNK）、`:509-517`（`symlinkTarget` 逐語）、`Tar/TarRecords.swift:87`（set-ID が tar の mode
field に届く）、`Editing/ArchiveRepresentability.swift:100-107`（変換時に `posixPermissions & 0o7777` を継承）、
`Writer/ArchivePath.swift` 付近の `normalizedPath`。

答えるべき問い:
- 「ディスクの setuid/setgid/sticky は**マスクせず**書庫に入る」は `Documentation/` のどこかに書いてあるか。
  無ければ、(a) 文書化する、(b) KaitoKit の新しい `ExtractionOptions.preserveSetUserIDBits` と対称になる
  `WriterOptions` の switch を足す、のどちらが妥当かを論じる（**対称性は設計の論点であり、脆弱性ではない**）。
- `/etc/passwd` や `../../../Library/LaunchAgents/x.plist` を指す symlink を含む書庫を GyoshukuKit に
  作らせられるか（コードは何も検査していないので答えは yes のはず）。それは書き込み library として正しいか。
  正しいなら文書化し、正しくないなら誰が検査すべきかを書く。
- `normalizedPath` は `..` / `.` / 空要素 / NUL（非 tar では `\` と `:`）を拒否するが、**C0 制御文字と
  bidi override（U+202A-202E / U+2066-2069）は通す**。GyoshukuKit に UI は無いので通すのが正しいか、
  それとも書き込み時に拒否すべきか。KaitoFinder / cooViewer 側の判断と整合させる。
- `normalizedPath` は名前全体の長さ（65535 byte）だけを見て**要素数**を見ない。KaitoKit の reader は
  `maxPathComponentCount` 1024 を課す。**自分が書いた書庫を KaitoKit が読めなくなる組合せ**を作れるか
  （作れるなら自傷であり、優先度が上がる）。
- `addDirectoryChildren` は深さ制限なしの再帰。数千段の tree で stack を使い切るか、crash か throw か。
- 変換時に、信頼できない source の set-ID を新しい書庫に継承すべきか。

再現案: `chmod 4755` したファイルを zip/tar/7z/lha それぞれに追加し、KaitoKit で読み戻して
`posixPermissions` を印字する。`ln -s /etc/passwd evil` と `ln -s ../../../x escape` を含む directory を
追加し、`tar -tvf` と KaitoKit の `formatSpecific["linkPath"]` で格納内容を確認し、**隔離した directory で**
`/usr/bin/tar` に展開させて何が起きるかを見る。U+202E を含む名前のファイルを追加し、`unzip -l` / `7zz l` /
KaitoKit の表示と生 byte を記録する。

既にある緩和策: symlink は追従しない（lstat + `O_NOFOLLOW`、`ArchiveWriter.swift:400-404`、`:465-468`）。
lstat→open の race は `DiskSignature.matches` で検出（`:487-490`）。

### 4.3 一時ファイルと原子的置換（ここは反証を期待してよい）

書き込み側固有で KaitoKit に対応物が無い領域。**既に規律が厚い**ので、監査の価値は「本当に全部そうか」の
確認と、置換時の mode / 所有者の意味論にある。

起点: `SegmentedOutput/ScratchFile.swift:14-30`、`Zip/ZipCryptoEncryptor.swift:39-58`、
`Compression/EntryCompressionConfiguration.swift:156-185`、`SegmentedOutput/ArchiveSourceSnapshot.swift:12-45`
（`.gyoshuku-source-<UUID>` は**unlink しない**）、`SegmentedOutput/SegmentedArchiveOutput.swift:60-77`、
`SegmentedOutput/OwnedOutputFile.swift:24-42`、`:68-74`、`SegmentedOutput/ArchiveOwnedFile.swift:57-83`。

答えるべき問い（上から順に価値が高い）:
- `publishReplacement` / `publish` は `source.mode`（`identity.mode & 0o7777`、**元の書庫の 04000/02000/01000 を
  含む**）を復元する。**setgid の書庫を編集すると、編集者所有の setgid ファイルができるか**。
  → `chmod 2755` した `.zip` に add+commit して `stat -f '%Sp %u %g'` を見れば 1 コマンドで決着する。
- `replaceItemAt` の後、新ファイルは現在の利用者所有になる。group 書き込み可能な directory で他人所有の書庫を
  編集すると所有者が黙って変わる。許容できるか、文書化すべきか。
- `replaceItemAt` と `setAttributes` の間は 0o600（元より狭い）。**狭くなる方向にしかならないこと**を確認し、
  `setAttributes` 失敗時に world-readable で残らないことを示す。
- 新規作成（`ArchiveWriter.create` / `SingleStreamWriter.createTemporary`）は 0o666（umask で通常 0644）、
  編集経路は 0o600。password 付きの**新規**書庫が 0644 なのは意図かどうか（payload は暗号化済みなので
  おそらく是）。非対称は文書化する。
- `.gyoshuku-source-<UUID>` は unlink されず、SIGKILL で利用者の directory に残る。回収の仕組みはあるか、
  名前から出自が判るべきか。

再現案: 編集中にディレクトリを別プロセスから tight loop で `ls -la` して、出力の隣に作られる path・作成時の
mode・unlink までの遅延を記録する。300 MiB の入力で ZipCrypto 暗号化を走らせ、`lsof -p <pid>` で spool が
unlink 済み inode としてだけ見えることを示す。

### 4.4 暗号パラメータと鍵材料（自傷の確認が最重要）

**先に確認して、済んだら進むこと**: ZIP AES の PBKDF2 1000 回 / HMAC-SHA1 は WinZip AE-2 の仕様
（`Documentation/design.md:806-808`）、7z の cyclesPower 19 / saltSize 0 は 7-Zip 自身の出力と byte 一致
（`:872-878`）。**どちらも「弱い選択」として報告してはならない。** 確認したら次へ。

起点: `Support/EncryptionPrimitives.swift:20-40`、`:42-67`、`:11-18`（`SecRandomCopyBytes`）、`:9`
（`testingRandomBytes` TaskLocal — production で到達不能であることを確認）、
`SevenZip/SevenZipAESEncryptor.swift:17-18`、`:62-76`、`Zip/ZipAESEncryptor.swift:13-23`、
`SevenZip/SevenZipEditPlan.swift:121-125`（入力の `aesProperties` を逐語継承）、
`SevenZip/SevenZipUpdater+SelfCheck.swift:48-49`。

答えるべき問い:
- **自傷の確認（最重要）**: GyoshukuKit が書いた 7z は KaitoKit 0.17.0 の `maxSevenZipEntryKDFWork` に
  引っかかるか。手計算: 1 導出 = `1<<19` rounds、予算 `4*(1<<24)` = 128 導出相当。salt が空なので全 folder が
  同じ cache key になる → 1 回で済むはず。**コードで確認し、実際に多数 folder の暗号化 7z を書いて
  読み戻す。**
- **継承の確認**: `SevenZipEditPlan` は入力の `aesProperties` を逐語保持する。つまり**編集後の書庫は、
  入力書庫の salt と cyclesPower を引き継ぐ**。salt が folder ごとに異なる敵対的な入力を編集した出力を、
  `SevenZipUpdater+SelfCheck` が password 付きで開き直したときに予算超過で失敗するか。失敗するなら
  「敵対的入力を編集できなくなる」という挙動変化であり、KaitoKit 側の既定値の妥当性の判断材料になる。
- zero 化は一切していない（`WriterOptions.password` は String、`Factory.key` と
  `ZipReencryption.outputKeys` は Data、`ZipReencryption.swift:422` の `defer` は再代入のみ）。
  KaitoKit 側では「copy-on-write のため in-place zero 化は無効」と結論した。同じ結論になるか、
  それとも書き込み側では意味があるか。
- `ZipReencryption` は AES entry ごとに 66 byte の鍵 + 16 byte salt を検証 pass の最後まで保持する。
  `maxEntryCount` 100 万で約 82 MB の生きた鍵材料になる。実際に縛るものはあるか。

再現案: 非 solid で 300 folder の暗号化 7z を書き、KaitoKit 0.17.0 で読み戻しながら
`SevenZipAESKeyCache` の導出回数を数える（`SevenZipAES.swift:50` の TaskLocal を使う）。
`Tests/Fixtures/sevenzip-edit/z_aes.7z` の AES coder properties を書き換えて folder ごとに salt が違う入力を
作り、add+commit → self-check が通るかを見る。

### 4.5 書き込み側の資源上限

起点: `API/WriterOptions.swift:143-146`（`ppmdMemoryMiB`）、`:157-164`（`memoryLimit`）、`:112`
（`compressionThreadsRange = 1...1024`）、`Compression/EntryCompressionConfiguration.swift:41-43`、`:92-94`、
`:119-126`（`max(1, ...)` なので 1 model は常に確保）、`:5-7`（`inputLimit` 16 MiB）、
`SegmentedOutput/ScratchFile.swift:36-44`（空き容量検査は testing TaskLocal のときだけ）。

答えるべき問い: PPMd の model memory が `options.memoryLimit` を無視して `physicalMemory/2` を使うのは意図か
（bzip2 は `min` を取っている）。`compressionThreads: 1024` は clamp 後に何になるか、thread 爆発や GCD の
枯渇になり得るか。宣言だけ巨大な member が丸ごと buffer されないことを形式ごとに証明する。
scratch が利用者のディスクを埋めて ENOSPC で落ちるのは意図した契約か（KaitoKit の reader には
`stagingFreeSpaceReserve` がある）。

再現案: `EntryCompressionConfiguration` の testing TaskLocal（`:6`、`:8`）で小さい予算を模擬する
（**この project 自身の作法**なので、小さい機械を用意する必要はない）。`truncate` で疎な 64 GiB を作り、
ZIP64 と tar に追加して peak RSS と scratch を測る。

### 4.6 CI と供給連鎖

**GyoshukuKit 固有の点が 1 つある**: heavy job を走らせるかを、**前の pull_request run の artifact**
（`tested-tree`）を download して決める gate。ほかは KaitoKit と同じ判断なので再導出しない。

起点: `.github/workflows/ci.yml:44-137`（gate）、`:653-668`（artifact の upload は pull_request のみ）、
`:68-70`、`:130-133`（fail-open）、`:79-84`（KaitoKit の tag 一覧の sha256）、`:36-39`（permissions は read のみ）、
`:28-29`（daily schedule）、`:153`、`:480`（unpinned brew）。

答えるべき問い: pull_request run は PR の merge ref の workflow を実行するので、**ci.yml を編集した PR が
artifact の内容を支配できるか**。gate は例外時に必ず full run に倒れるか（`full=true` の二重書き込みと
last-write-wins を追う）。**KaitoKit の新しい tag が skip を無効化するか**（0.17.0 の公開が古い合格で
隠れないこと）。この repository に外部 PR が来たことがあるか（`gh pr list --state all --json author` で
事実で決める）。unpinned brew と tag-pin の action は「記録するが再報告しない」。

## 5. 必須の横断チェック

1. `git -C ../KaitoKit log --oneline -1` を記録する。
2. KaitoKit 0.17.0 の 4 変更それぞれに「影響あり / 無関係（根拠）」を明示する。
3. **4.4 の自傷の確認を数値で出す**。GyoshukuKit が書いた / 編集した書庫が KaitoKit 0.17.0 で読めなくなる
   組合せが存在するかは、リリース判定に直接効く。
4. 4.2 の「KaitoKit が読めない名前を書けるか」も同様に結論を出す。

## 6. 成果物の形式

判定表（`ID | 主張 | 判定 | 実リスク | 重大度 | 対応`）、実証済み各件の再現コマンドと実出力、
退けた項目とその根拠（「仕様どおり」「文書化済み」「到達不能」）、自分の検査の限界。
修正する場合は修正前に失敗する回帰テストを添える。公開 API を変える提案は SemVer 影響を明記する。

## 7. 禁止事項

- `git commit` / `push` / branch 作成をしない。
- インストールをしない（`brew` も含む）。必要なら記録に「必要」と書いて止まる。
- 第三者の書庫実装 source を読まない（`Documentation/design.md` の clean-room 規則）。黒箱実行は可。
- repository を汚さない（細工ファイルは `$TMPDIR` 以下）。KaitoKit の検査では別エージェントが repo root に
  試験書庫を 6 個残した。
- `../KaitoKit` を書き換えない。audit branch の内容を変えると KaitoKit 側の検証と食い違う。

## 8. 完了条件（リリース判定）

- 全領域の判定が書かれている。
- 重大度 高 / 中 が残っていない（残るなら修正済みか裁定待ちと明示）。
- 4.4 の自傷確認と 4.2 の相互運用確認に結論が出ている。

## 9. 想定工数と最初の 30 分

全体で 4〜6 日相当（並列化すれば 25〜40 エージェント session）。KaitoKit より小さい理由は、
形式 parser を持たないこと・攻撃面が 10 箇所の open と呼出側 option に限られること。

最初の 30 分: (1) `git -C ../KaitoKit log --oneline -1` と自 repo の HEAD を記録。
(2) `Documentation/design.md` の暗号パラメータの節（:806-814、:872-880）を読み、4.4 の「報告してはならない
2 件」を確認。(3) `ArchiveUpdater.swift:70-71` と `ArchiveRepresentability.swift` を読む。
(4) 4.3 の `chmod 2755` の 1 コマンド実験を先にやる（結果次第で優先度が変わる）。
