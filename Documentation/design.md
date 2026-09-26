# GyoshukuKit 設計書(2026-09-10 初版)

## 1. 位置づけ

解凍(KaitoKit)と凝縮(GyoshukuKit)を対にする。KaitoKit が読み取り専用で
あることは意図的な設計であり、書き込みをそこへ足すと、読み取りしか必要としない
利用者(cooViewer など)にまで writer の byte が届いてしまう。別リポジトリに
することで、その影響を文言ではなく構造として断つ。

KaitoKit と同じ性格を引き継ぐ。

- 純 Swift。追加の外部依存なし。zlib、libbz2、Apple Compression、CommonCrypto / CryptoKit / Security をサポートされた
  形で使う。システムの libarchive は使わない —— SDK に `archive.h` が無く
  (実測)、prototype を手書きして依存するのは性格に合わない。加えて libarchive
  には in-place update が無く、書庫内編集のためにどのみち自前の updater が要る。
- 攻撃者が制御する値は読んだ場所で検証する。書く側でも同じで、宣言サイズや
  entry 数を信用して確保しない。
- 実装の正しさは**参照実装との差分テスト**で担保する。書いたものを `unzip -t`、
  `7zz t`、`bsdtar` で読み、さらに **KaitoKit で読み直す往復**を必ず行う。
  解凍と凝縮が対である以上、この往復が最も素直な回帰テストになる。

## 2. 依存の向き

```
GyoshukuKit ──依存──> KaitoKit
```

一方向だけ。KaitoKit は GyoshukuKit を知らない。

書庫の**更新**(追加・削除・改名)は、生き残る entry を再圧縮せずに運ぶために
既存書庫を読む必要がある。その堅い parser は KaitoKit が既に持っているので、
二つ目の ZIP parser は書かない。開発中は `.package(path: "../KaitoKit")`、
release では tag 参照へ切り替える。

## 3. API の形

KaitoKit の `ArchiveReader` と対称にする。

```swift
// 新規作成
let writer = try ArchiveWriter.create(url: destination, format: .zip, options: WriterOptions())
try writer.add(contentsOf: sourceURL, as: "docs/readme.txt")
try writer.addDirectory("docs/")
try writer.finish()

// 既存 ZIP への追加(段階 1 後半)
let updater = try ArchiveUpdater.open(url: archive)   // 内部で KaitoKit の reader を使う
try updater.add(contentsOf: fileURL, as: "new.txt")
try updater.add(data: Data("追加".utf8), as: "memo.txt", modificationDate: nil, permissions: nil)
try updater.addDirectory("empty/")
try updater.commit()        // clone を完成させて atomic replace

// 既存 ZIP の削除・改名(段階 3、0.3.0)
let editing = try ArchiveUpdater.open(url: archive)
try editing.remove(entriesAt: [0, 2])
try editing.rename(entryAt: 1, to: "docs/新しい名前.txt")
try editing.commit()        // index は open 時の値。削除予約で詰め直さない

// 非圧縮 tar は原本を保ち、指定した新規 output へ必要な範囲だけ書く。
let tar = try TarUpdater.open(url: archive, output: destination)
try tar.rename(entryAt: 0, to: "renamed.txt")
try tar.add(contentsOf: fileURL, as: "new.txt", ownerIDs: ArchiveOwnerIDs(user: 501, group: 20))
try tar.commit(progress: { progress in /* completedBytes / totalBytes */ })
```

`ArchiveEditing` は日付・所有者指定の `addDirectory(_:modificationDate:ownerIDs:)` と
`add(contentsOf:as:ownerIDs:)` も要求する。従来の conformer 向けの既定実装は、指定値が
あれば `unsupportedOption` を返す。ZIP / tar は明示 ID を全子孫へ適用し、7z / LHA は拒否する。
`ArchiveRewriter` の既定は既存項目の後ろへ追加する `.end`。add は名前と追加元の署名を予約し、
出力を作らず commit で運んでから追加する。追加元の最上位 inode・mode・size・mtime を再検査し、
directory の子孫は commit で探索する。`.beginning` は従来の add 時に書く動作を保つ。

`ArchiveWriter` / `ArchiveUpdater` は thread-safe にしない。KaitoKit と同じく、
一つの instance の操作は呼出側が直列化する。値型の設定は `Sendable` にする。

`WriterOptions` は圧縮方式と level、暗号化、名前の encoding、timestamp の
粒度、macOS metadata を書くかどうかをまとめる。既定値は「相手が Windows でも
困らない」側に倒す(§5)。

## 4. 形式ごとの段階

| 段階 | 形式 | 作成 | 追加 | 削除・改名 |
|---|---|---|---|---|
| 1 | ZIP / ZIP64 | ○ | ○(旧 CD の byte をそのまま運ぶ) | ○(段階 3、KaitoKit 0.4.0 の rawRecord を使用) |
| 2 | tar | ○ | ○(TarUpdater、終端の手前へ) | ○(TarUpdater、変更 header と位置の動く範囲だけ) |
| 2 | tar.gz / .bz2 / .xz | ○ | ○(CompressedTarUpdater) | ○(変更を含む区切りだけ再符号化) |
| 3 | 7z | ○(non-solid・AES-256 / header 暗号化を選択可能) | 作り直し | 作り直し |
| 4 | LHA / LZH | ○(`-lh5-`) | ○(LHAUpdater、末尾へ) | ○(header と位置の動く member だけ) |
| — | RAR | × license が禁じる | × | × |
| — | CAB / RPM / ISO / xar | × | × | × |

圧縮 tar は session reader の復号済み image と区切りの地図から編集する。
継げる区切りが無い入力は最初の変更で全体を G1 の配置に符号化する。
従来の追加位置・所有者設定と open 時に拒否される入力は ArchiveRewriter を使う。
UI 側は進捗と取り消しを必ず出す。

### LHA の並列 LH5（P4-G-a）

`ArchiveWriter.create` は `options.resolvedCompressionThreads` を LHAWriter に渡す。
rewriter もこの経路を使う。1 は従来の同期処理、2 以上では 1 MiB 以下の member を
`OrderedChunkPipeline` に渡し、CRC と入力の読み切りは呼出側で行う。directory も投入順を保つ。
入力を確保する前に容量を待ち、同時に保持する入力を並列数までに抑える。

大きい member は従来と同じ 1 MiB と直前 8 KiB の履歴に分ける。各 worker が返す完全な byte と
端数 bit を投入順に padding なしで継ぐ。LH5 の辞書・Huffman block の区切りは従来どおりで、
どの並列数でも直列時の byte と一致する。raw を先に出力し、縮めば spool から置き換える。
完成 byte の累計が原本サイズ以上になった区切りで残りの符号化を破棄し、raw の保存を続ける。

`add` の後に符号化が残る場合、失敗・取消しは後続の add / finish / internal の endMembers で通知し、
従来の abort で出力を削除する。大きい member の前と終了時に member の pipeline を drain する。
internal の `endLHAMembers()` は終端・fsync・close なしで追加の終わりを返す。
`recordsMembers` を有効にしたときだけ、実際の出力時点の header 絶対位置・header/data 長・method と
canonical な名前の byte（directory の 0xFF を `/` に変換し filename を連結）を保存する。
LHAUpdater はこの追加 writer を既存の `SplicedArchiveOutput` と組み合わせる。

### LHA の更新（P4-G-b）

`LHAUpdater.open(url:output:options:)` は原本を readonly で開き、descriptor から clone した snapshot を
KaitoKit で読む。clone 非対応時は原本を直接読み、新規 output を先頭から書く。公開・属性の復元は呼出側が行う。
KaitoKit の全件解析、共有 `validateRepresentability`、独立した level 0/1/2 の header walk と
`LHARawLayout` SPI の照合、原本の identity 検査を行う。walk は 4 KiB の窓で読み、payload を読み切らずに飛ばす。
境界の表を二重に保持せず、照合後の計画では SPI を使う。取消しは 1,024 member ごとに検査する。

| 条件 | open の経路 |
|---|---|
| R0 `.beginning` | `requiresRewrite("additionPlacement")`。LHA は `carriedTarOwnerIDs` を見ない |
| R7 分割巻名 | `requiresRewrite("split volume name")` |
| R8 SPI 不在、walk 不可（OS-9 `K` の不足宣言長を含む）、SPI/公開 entry との不一致 | `requiresRewrite` |
| R10(a) nameEncoding が nil/shiftJIS 以外 | `requiresRewrite` |
| R10(b) nameEncoding が nil で rawName に非 ASCII byte がある（宣言付きも含む） | `requiresRewrite` |
| L1 SFX、L2 0 byte 以外の終端 | `requiresRewrite` |
| L3 終端の後ろに非 0 byte、または後続が 64 KiB 超 | `requiresRewrite` |
| L4 非公開 member、L5 level 3、L6 incomplete entry | `requiresRewrite` |
| L7 directory が lhd 以外、packed/original size が 0 以外 | `requiresRewrite` |
| L8 lh7 + OS 0x20（LHArk）、L9 packed size が UInt32 超 | `requiresRewrite` |

`rewriteReason(reader:)` は SPI と公開値による構造判定だけを共有し、設定・分割巻名・独立した walk は判定しない。
MacBinary envelope のある `m` member、symlink、pm2、表せない名前などの門番は rewriter と同じで、
`RewriterError.unrepresentable` のまま返す。KaitoError と非 LHA の `UpdaterError.invalidArchive` も経路変更に使わない。
`UpdaterRouteError` は `requiresRewrite` と `outputVerificationFailed` の二つだけを持ち、
`TarUpdaterError` はその typealias として既存の catch を保つ。

予約は `EditPathReservations` を使う。index と entryNames は open 時のままで、削除後に同名の追加ができる。
root `.` は予約名が空でも運び、正規化後に同じ名前へ改名した member の byte は保つ。
違う名前への改名時点で `LHARecords.Entry` の header を作り、失敗は transaction 全体を失敗にする。
改名しない member は header・payload・名前の raw byte・時刻・拡張をそのまま運ぶ。

改名した member は level 2、OS `U`、attribute 0x20、拡張 0x00/01/02/50/54 になる。
comment、DOS 属性、Windows 時刻、64 bit size、code page、uid/gid、所有者名、未知の拡張は落ちる。
時刻は KaitoKit が解いた modificationDate の Unix 秒へ切り捨て、欠ければ現在時刻を使う。
level 0/1 の DOS 時刻は現在 timezone の解釈、0x41 の秒未満は失う。
permission は OS `U` の値、その他は 0644/0755。method・payload・data CRC16・元サイズは保つ。

追加・改名は宣言なし CP932 で書く。R10(b) は、追加した名前だけが文字コード推定の入力となる場合を避ける。
`SP/p4rev/enc` の実験では、単独の第 2 水準漢字名 12 件のうち 9 件が別 encoding と推定された。
既存の CP932 名があれば同じ 12 件は正しく読めた。宣言付き非 ASCII 名も R10(b) の対象になる。
既存 CP932 名の削除によって、編集後の書庫が次回 R10(b) に当たる場合はある。

変更時は生存 member、追加 block、0 の 1 byte の順に並べ、後続の 0 も落とす。全削除は `[0]`。
KaitoKit がこの空書庫を識別するには、読取 URL の拡張子を `.lha` / `.lzh` にする。
無変更 commit は後続の 0 も含め全 byte を保つ。位置が同じ source segment は clone のままにし、
移動範囲だけ copy する。追加後の予約で位置が変われば共有部品の scratch へ退避して再配置する。
出力、spool、dup descriptor の所有と削除は既存の FAT/exFAT の fresh fstat/lstat 規則を使う。

commit の照合は V1（改名 header の byte・CRC・解釈）、V2（source segment 境界の header）、
V3（追加 block の独立 walk と記録、dup descriptor 上の KaitoKit 全復号/CRC16）、V4（長さと終端）、
V5（共有部品による、書いた source 範囲の 4 MiB ごとの memcmp）。追加だけでは既存 prefix を読み戻さない。
運んだ payload は復号しない。呼出側の公開前の全 header 解析・projection 照合は別に残す。
進捗 total は書込み（再配置の往復を含む）+ V2/V5 読取 + 追加 block 長で、計画後は固定する。
V2/V5 は `SplicedArchiveOutput.verificationReadObserver` 一つに報告する。V1/V4 と V3 の実読取量は足さない。
callback の throw・取消し・再入は失敗とし、自分の出力だけを削除する。

tl-S11 の危険は残る。level 2 の長さの下位 byte が 0 だと KaitoKit は終端と見る。
非 0 の後続を L3 で拒否できるが、rewriter も見えなかった後ろの member は復元しない。
新しい header は `LHARecords` の既存の padding 規則でこの形を作らない。

## 5. 既定値の方針

- ZIP は general purpose **bit 11** を立てて UTF-8 名を書き、NFC へ正規化する。
  既存の CP932 書庫を更新するときは、既存 entry の名前バイトと flag を
  **そのまま**運ぶ(混在は正当)。
- ZIP の `version made by` は host 3 (UNIX)。でないと POSIX mode と symlink が
  尊重されない。
- data descriptor は**書かない**(seek して local header を patch する)。ただし
  **読む側は必須** —— `ditto` は deflate entry すべてに bit 3 を立てる。
- tar は macOS metadata(`._` AppleDouble、`SCHILY.xattr`)を**既定で書かない**。
  Apple の bsdtar は既定で書き、それが Mac 製書庫が Windows で嫌われる主因。
- 新規 tar とディスク追加の uid/gid は既定 0、uname/gname は空。`preserveOwnerIDs` はディスク追加だけに効く。
  運ぶ tar の ID は `carriedTarOwnerIDs: .keep` で数値を維持する。rewriter の `.reset` は 0 にする。
  TarUpdater は header の ID・uname/gname・pax・sparse 表現を byte 単位で運び、名前も正規化しない。
  追加・改名と衝突判定には従来の NFC 正規化を使う。`additionPlacement` の既定は `.end`。
- 圧縮は zlib の deflate、既定 level 6(Info-ZIP と同じ)。Apple の Compression
  framework は `COMPRESSION_ZLIB` が level 5 相当に固定で選べない(実測)。

## 6. 更新の安全性

### 圧縮 tar の区切り単位の更新（P3-G G2）

`CompressedTarUpdater.open(reader:output:format:options:)` は KaitoKit の
`recordsTarEditLayout` を立てた session reader を受け取り、原本の URL は受け取らない。
`assess(reader:)` は snapshot と地図だけを見て初回の全体符号化の見込みを返す。
open は P2 の `TarLayout` と K1 の member/header/global/EOF 境界を照合し、
従来の設定と R0–R8・R10 を拒否する。ここでは出力も一時ファイルも作らない。

変更の意味は `TarEditPlan` と追加用 factory を共有する。hard link の付け替え・実体化、
pax/sparse header 群の変更、comment の global header、所有者と未変更名の byte を保つ。
変更 commit は新しい EOF と record fill を作り、変更なしは圧縮 byte もそのまま複写する。
`TarImageSource` は旧 image と追加/literal の区間を二分探索し、image 全体を複写しない。
追加/literal だけの保存領域は出力の隣に O_EXCL・0600 で作って直ちに unlink し、
固定の予備容量や空き容量の事前検査は設けず、実際の書込みエラーを伝えて後始末する。
出力 volume 上で追加と literal だけを保存するため、出力本体と同じ容量方針にする。

運ぶ chunk は新 image の一つの連続する source 区間に収まるものだけとする。
gzip はさらに直前 32 KiB も同じ source 区間に収め、BFINAL を途中へ運ばない。
残りの橋を G1 の `TarChunkLayout` で切る。上限は gzip 1 MiB、bzip2 は
5 × level × 100,000 B、xz は `ParallelXZCompressor.defaultBlockSize`（16 MiB）。
大きい member は header 群と本文を分け、終端は独立する。橋に隣接する S/16 未満の
chunk を片側一つ吸収し、間が小さい chunk だけの橋同士も併合する。
gzip の CRC は libz の `crc32_combine`、xz の block/Index/footer は G1 の `XZFraming` を使う。
bzip2 は運ぶ stream の元の level を維持する。CRC64 の xz、地図の無い容器、
運べる chunk の無い計画は fullEncode になる。

進捗の total は橋の image byte、運ぶ圧縮 byte、自己照合の圧縮/framing 読取 byte の合計。
圧縮長を先に求めて total を固定し、その後に出力を作る。並列数 × chunk 上限の定数倍の
cache に符号化結果を残し、収まらない fullEncode の chunk は書出し時に再符号化する。
追加の圧縮 spool は作らない。この事前符号化中も Task の取消しを確認するが、
最初の進捗通知は total が確定した後になる。callback の throw・再入も失敗として扱う。

自己照合は V0（区間・座標・gzip 窓）、V1（橋だけを並列に復号して新 image と比較）、
V2（header/trailer、bzip2 EOS、xz block/Index/footer）、V3（出力と原本の同一性）を行う。
V4 は copy engine が読んだ圧縮 byte の CRC32 を open 時の digest と比較し、
mtime を戻した同一 inode の変更も `sourceChanged` にする。読取りは一回で、
出力の運んだ payload は自己照合で読み直さない。検証読取は既存の
`SplicedArchiveOutput.verificationReadObserver` に報告する。

`commit(progress:)` は戦略、自己照合後の出力 identity、統計、
`.reused(output:base:)` / `.encoded(output:)` の segment 列を返す。
呼出側はこれを一対一で KaitoKit の `CompressedTarSplice` へ写し、**公開前に K5
`openSplicedCompressedTar` を呼ぶこと**。全体の open で検証し直してよいのは
K5 の `.baseNotSpliceable` の場合だけで、それ以外の失敗は公開しない。
K5 は運んだ出力の digest・gzip 窓・橋の復号・容器の終端を独立に検証する。
GK の自己照合だけでは、書いた後の運ぶ payload の破損を検出しない。

原本は snapshot の descriptor の同一性を open・commit 開始・fsync 後に検査する。
原本のパスが別 inode へ置換されたかは呼出側の責任で、GK は保持した inode を読む。
作った output は `ArchiveOwnedFile` の fresh fstat/lstat 照合で所有を確認し、
失敗時も別の inode は消さない。FAT/exFAT の空 file の仮 inode を保存しない。
成功した出力は 0600・fsync・close 済みで、公開・属性復元は呼出側が行う。
圧縮率の極端に高い小さな書庫では、数十 byte の区切り差でも相対サイズ差が 1% を
超える場合がある。検証記録では byte 差と比率を両方示す。

試験・互換性・AC9 の TSV は [G2 検証記録](verification/2026-09-26-p3g2-compressed-tar-updater.md) に記す。

### 非圧縮 tar の最小書き換え（P2-G）

TarUpdater は P1-G の `ArchiveSourceSnapshot` を共有し、原本を O_RDONLY で開く。
immutable / append flags を拒否し、descriptor clone が ENOTSUP / EXDEV のときだけ sequential に戻す。
KaitoKit の open と全件の表現可能性検査に加え、`TarLayout` が独立して tar を走査し、
member の名前・種別・保存長を照合する。走査は任意の ByteSource と座標だけで動き、
4 KiB の header cache と拡張 payload の範囲読取を使う。旧 GNU sparse・非 comment 大域 pax・
hdrcharset・不安定な名前 encoding・sparse hard link などは open で `requiresRewrite` になる。
`.beginning` と `.reset` も open で拒否し、rewriter へ戻す判断を mutate 前に確定できる。

`TarEditPlan` は生存 member 順の source / literal 区間を作る。変更しない header/body と comment の
大域 pax はそのまま、改名では必要な name / prefix / link / checksum と pax record だけを変える。
削除された hard link の参照先は生存 holder へ付け替え、holder が無ければ最初の link を実体化する。
変更した commit は 1,024 B の EOF と 10,240 B record までの fill を新しく書く。変更 0 件は尾部も含め原本と一致する。

形式共通の `SplicedArchiveOutput` が clone、新規 output、4 MiB copy、追加 block の再配置、scratch、
truncate、fsync、close、inode に限定した cleanup を所有する。TarUpdater は計画と終端・形式照合を渡す。
同じ位置の source は clone 上で書かない。sequential の初回 add は先に prefix を埋め、予約の変更で
追加位置や prefix が変わった場合だけ同じ directory の scratch へ追加を退避する。
generated 区間と最初の fsync 後の finalPatch も形式共通の契約として用意し、後続の updater が再利用する。

V1 は変更 header、V2 は source 境界 header、V3 は追加群、V4 は終端と長さ、V5 は書いた source と
出力の全 byte を照合する。V5 は 4 MiB ごとの直接 pread 比較で、未移動の clone 範囲は読まない。
V2/V5 の読取を一つの `SplicedArchiveOutput.verificationReadObserver` に報告する。
共通 `CommitProgress` の total は計画後に固定し、commit 中の書込み（再配置の往復を含む）と
V2/V5 の読取を数える。初回 add の書込みは含めない。単調に通知し、最後は 0 を含め completed == total。
callback の throw・再入・取消しは失敗として、自分の inode の output / snapshot / scratch を削除する。

試験・互換性・計測値は [P2-G 検証記録](verification/2026-09-25-p2g-tar-updater.md) に記す。

### 段階 1 の追加

1. 同一ボリュームの `.itemReplacementDirectory` へ **APFS clone** する
   (`FileManager.copyItem`。実測 300 MB で 0.002 s)。最初の add まで遅延する。
2. clone の旧 CD offset から新しい local record を書く。既存の local record は
   元の位置のままであり、再圧縮も descriptor の探索も行わない。
3. open で検証して保持した **旧 CD の byte をそのまま**コピーし、新しい CD を
   続ける。旧 local offset が動かないので、旧 CD の再符号化や部分修正は不要。
   旧 entry 数・CD size・CD offset を合算した EOCD を作り、必要なら ZIP64 EOCD と
   locator を新たに書く。旧 ZIP コメントも保持し、末尾を truncate・同期する。
4. `FileManager.replaceItemAt` で差し替え、**直後に POSIX permission を復元**する
   (実測:replacement 側の mode が勝つ)。`replaceItemAt` は Finder tag と
   xattr と作成日は保つが `com.apple.quarantine` は落とすので、付いていれば戻す。

原本は一度も in-place 編集しない。commit 前の失敗・破棄では clone を削除する。
成功後の commit は no-op。失敗後の instance は再利用できない。原本の inode・size・
mtime・mode が open 時と変わった場合は置換を拒否する。device も比較する。
Finder tag や LaunchServices の `com.apple.lastuseddate#PS` 更新でも変わるため ctime は除外する。
通常ファイルの読取前後と tar hard link の内容 signature も同じ方針にする。ただし排他 lock は取らず、
同一書庫への他プロセスの操作も呼出側で直列化する。
置換後の metadata 復元が失敗した場合はエラーを返すが、内容の置換は既に完了している。

### 段階 3 の削除・改名(0.3.0)

生き残る local record 全体を新しい位置へ運ぶには、KaitoKit が検証した範囲が必要になる。
open で `@_spi(ZipRawLayout) zipRawRecordLayout(at:)` を使い、CD を一括で読み、独立した
walk の offset・件数・終端と ZIP64 extra の解釈を照合する。CD の bytes と検証済み範囲を保持し、
commit は同じ record を再解析しない。nil の生存 entry は理由付きで拒否する。
CD の一括確保は KaitoKit と同じ metadata 上限以内に限定する。validate 自体は取消しを検査しないが、
KaitoKit の解析は取消し済みの Task で CancellationError を投げる。
local と central の extra field 長は異なるので local を CD から再構成しない。
この場合は offset が動き、ZIP64 extra も増減するため CD 全体を再出力する。
追加だけにこの再構成や descriptor 探索を持ち込まない。

削除・改名は open 時の index で予約する。削除の重複は無害、同じ index の再改名は最後の
予約名を使う。削除済み entry の改名は拒否し、削除予約した名前は後の追加・改名で再利用できる。
子孫の削除・改名、symlink target の変更は暗黙に行わない。

先に local、次に CD の順で出力を計画する。生存 record は CD 順に、source と出力がともに
厳密に連続する copy だけを併合し、4 MiB の buffer で運ぶ。隙間と未移動の payload は読まない。
改名する local header は一度だけ読み、同長かつ未移動なら header を patch、他は header の後に
payload から `recordRange.upperBound` までをコピーする。descriptor の長さは算出しない。
ZIP64 extra・sentinel・disk start が不要で、reader とサイズが一致する canonical な CD は、
元の byte をコピーして local offset だけを patch する。他は従来の再符号化を行う。
同長改名だけで、全 record が未移動、CD の手前に隙間がなく、全 CD が canonical、
改名後も CD の名前の byte 長が同じ、かつ終端が従来の再生成結果と完全一致するときは、
local と CD の改名箇所だけを patch して同期する。CD 全体の再出力と truncate は行わない。
改名時だけ UTF-8 / NFC / bit 11 を使い、旧 Unicode Path extra は長さを保った padding にする。
その本文は CRC・旧名を含めてゼロで埋める。重複・未知 version の field も同様に扱う。
他の名前を持つ既知の extra（0x0008 / 0x2605 / 0x334D / 0x4F4C / 0x554E）や
非ゼロの未解析末尾がある場合、metadata を黙って捨てず改名を拒否する。
CD の各 ZIP64 size / offset は独立判定する。central だけで wide descriptor を宣言していた
entry は、値が小さくなっても空の ZIP64 marker を残して KaitoKit の幅の解釈を維持する。
逆に ZIP32 descriptor に offset 用 ZIP64 extra が初めて必要になる移動は拒否する。
KaitoKit 0.4.0 がこの extra も wide 判定に使うためで、descriptor の独自変換はしない。

削除だけでは名前予約表を作らない。ZIP の open 時の entry が 2,048 件以上なら、追加・改名の
名前検査を合計 4 回まで `LiveNameCheck` の走査で行う。最初の走査で元の名前を UTF-8 の平らな
snapshot に一度だけ写し、削除・改名した index の除外配列、改名後の名前、追加済みの名前を
別に照合する。ASCII で空成分のない名前は byte と `/` の境界で比較し、それ以外だけ NFC の
比較 key を持つ。改名の予約表は空成分を残し、writer の必要 directory は空成分を除くという
従来の違いも保つ。改名は祖先 file、同名、子孫の順、追加は同名、子孫、祖先 file の順に拒否する。
5 回目以降は必要な側の既存の表を作り、改名は `EditPathReservations` を差分更新する。
削除がないときの生存名一覧は元の順で作り、改名した index だけを差し替える。
少数の改名の後に表へ切り替えても、全件に対する改名辞書の検索を加えない。
2,048 件未満では初回から従来の表を使う。TarUpdater・CompressedTarUpdater には適用しない。

writer の正規化・名前の予約は internal `reserveEntryName(_:directory:)` 一か所に置き、
`addEntry` が呼ぶ。ZIP updater だけが internal `existingPathCheck` を設定し、走査中は元の名前を
writer の集合に入れない。budget を使い切った次の追加で既存名を補い、hook を外す。
後続の一括追加も同じ関数を同じ順に呼び、budget・例外・集合の更新順を共有する。

追加が混在するときは、最初の add の前に詰めた位置を予測して、その位置へ追加 record を書く。
writer の仮想 offset は旧 CD offset を基準にし、従来の local header の version も保つ。
commit で追加 pipeline を drain し、生存 record を移動してから CD と終端を一度だけ書く。
writer が上書きした範囲 W と交差する生存 record は、同じ位置に残る場合も source から復元する。
追加の後に予約を変えて予測位置が変わった場合だけ、出力の段階 snapshot を作り、追加 block を
そこから最終位置へコピーする。全 N 件の段階 reader と二度目の raw walk は不要になる。
追加 M 件は出力 descriptor で header の完全一致と連続性を確認し、その block と仮想の CD・終端を
提示する ByteSource を KaitoKit で開いて raw name・サイズ・local/payload 範囲・descriptor 不在を照合する。
追加 payload の CRC は従来どおりここでは展開検証しない。

計画は 4,096 件ごとと計画直後、実行直前、コピー・書込み chunk ごと、公開直前に取消しを確認する。
CD 側の改名拒否は実行中の I/O エラーより先に判定する。混在時も既存 N 件と追加 M 件を別々に検査するため、
従来の段階 reader が N+M 件に課していた entry 数・metadata の上限による拒否はなくなる。
呼出側による公開前の全体検証は維持する。今日 commit が成功する入力の出力 byte は変えない。

### 作業ファイルへの直接出力と進捗

`ArchiveUpdater.open(url:output:options:)` の output は既存であってはならず、親は呼出側が用意する。
省略時の原本置換は従来どおり。指定時は原本を O_RDONLY | O_NOFOLLOW で開き、immutable / append の
UF/SF flags があれば何も作らず EPERM を返す。開いた descriptor から `fclonefileat` で output の隣に
source snapshot を作り、flags を 0 にする。以後の門番・reader・validate・rebuild・CD 読取はこの descriptor
だけを使う。ENOTSUP / EXDEV だけは原本への直接読取へ戻り、他の clone エラーは失敗にする。
この処理は形式に依存しない internal の `ArchiveSourceSnapshot` で、拡張子を指定できる（後続の tar 用）。

最初の add または commit で snapshot の descriptor から output を clone し、snapshot がない場合は
原本を copyItem する。変更がなくても output は作る。作成前後と commit の開始・終了直前に原本の
同一性を確認し、snapshot があればその同一性も確認する。output は flags 0、mode 0600 にして開き、
fstat と lstat の dev/ino を照合する。成功時は fsync・close 済みで返す。xattr・quarantine・作成日は
clone のまま保持し、mode・属性の復元と公開の rename は呼出側が行う。output mode では
replaceItemAt と itemReplacementDirectory を使わない。取消し・失敗・破棄時は、自分が作った output と
snapshot の dev/ino が一致する場合だけ消す。成功時も snapshot を消す。ZipCrypto spool は隣に作り直後に unlink する。

`commit(progress:)` は同期的に `CommitProgress(completedBytes:totalBytes:)` を通知する。
追加 pipeline の drain 後に計画から total を決め、実行前の 0、4 MiB 以上進んだ時、最後の完了値を通知する。
この段階では total は commit 中の移動・patch・CD・終端の書込み byte であり、drain 中の追加 data は含まない。
callback を呼出しの外に保持せず、throw は取消しと同じく原本を保って作業ファイルを片付ける。

### 編集を断る三つの門番

読み取りは従来どおり行い、**編集だけ**を断る。理由を呼出側へ返す。

- **SFX prefix 付き ZIP** —— prefix があると central directory の offset 基準がずれる。
- **EOCD の後ろに trailing data がある ZIP**。
- **`EOCD.cdOffset` が `PK\x01\x02` を指さない ZIP** —— 実測で見つけた実在の罠。
  `ditto`(Finder の「圧縮」)は 4 GiB 超の entry を ZIP64 なしで書き、
  uncompressed size / compressed size / EOCD の CD offset を mod 2^32 で切る。
  その状態で data descriptor を算術で探すと deflate stream の途中を指し、
  編集が静かに壊す。詳細は KaitoFinder の
  `Documentation/verification/2026-09-10-ditto-zip64.md`。

## 7. KaitoKit の raw record API と ZIP layout SPI

ZIP updater は `@_spi(ZipRawLayout) internal import KaitoKit` で `ZipRawRecordLayout` と
`ArchiveReader.zipRawRecordLayout(at:)` を使う。公開の rawRecord と同じ local・descriptor 検査を保ち、
String 辞書と entry 全体の等値比較を作らず、範囲 2 つと descriptor・central/local ZIP64 の有無を受け取る。
この型は KaitoKit 側の public init を必要とせず、GK 内では internal な検証済み layout に写す。

試験用 `@_spi(Testing)` は `ArchiveUpdater.CommitStrategy`（unchanged / appendOnly / inPlacePatch /
rebuild / rebuildThenAppend / stagedRebuild）と `lastCommitStrategy` だけを公開する。
KaitoKit 0.11.0 が SPI を提供するため、release commit で Package.swift の URL 依存を `from: "0.11.0"` に
上げる必要がある。開発中は sibling の KaitoKit を使い、manifest の自動選択規則は変えない。

従来の public rawRecord API（0.4.0）は引き続き利用できる。

削除・改名で生き残る entry を再圧縮せずに運ぶには、生 record の範囲が要る。
`ZipReader` は `localHeaderOffset` / `dataOffset` / `compressedSize` を private に
持っているため、追加の公開 API を KaitoKit 0.4.0 で提供する。

```swift
public struct RawEntryRecord: Sendable {
    public let recordRange: Range<UInt64>   // そのまま運ぶ範囲(data descriptor 含む)
    public let payloadRange: Range<UInt64>  // 検証用。圧縮データ本体だけ
    public let formatSpecific: [String: String]
}
public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord?
```

**終端の算出は KaitoKit にやらせる**のが要点。ZIP の data descriptor は
signature の有無と ZIP64 かどうかで 0 / 12 / 16 / 20 / 24 byte と変わる。
呼ぶ側にこの算術をやらせると writer と reader で解釈がずれる。

これは段階 1 の**追加**では不要で、**削除・改名**に入るときに必要になる。
GyoshukuKit 側でこの accessor を利用し、KaitoKit の source は変更しない。

## 8. 暗号化出力（2026-09-15）

`WriterOptions.password` は nil なら平文。空文字列は `invalidOption("password")`、
tar / tar.gz / LHA の指定は `unsupportedOption("password")` にする。
`encryptsSevenZipHeaders` の既定は false、パスワードなしの true は invalidOption。
ZIP の既定は `ZipEncryption.aes256`、互換性のため `.zipCrypto` も選択可能。
writer / updater / rewriter は同じ検証関数を使い、出力作成前に検証する。

### ZIP WinZip AES-256

通常ファイルだけ（空ファイルを含む）を暗号化する。directory / symlink は平文の stored。
圧縮方式は既存の拡張子 heuristic と stored / deflate 設定を使い、両 header の method を 99、
version needed を 51、flag を bit 0 + bit 11 にする。0x9901 の 7 byte 本体は、vendor version、
`AE`、strength 3、実際の圧縮 method。20 byte 未満を AE-1 と実 CRC、以上を AE-2 と CRC 0 にする。
これはこの writer の選択方針で、AE-1 / AE-2 の wire format は公開仕様に従う。

UTF-8 パスワード + 16 byte のランダム salt を PBKDF2-HMAC-SHA1（1000 回）へ渡す。
66 byte の結果を AES key 32 byte、HMAC key 32 byte、password verifier 2 byte に分割する。
payload は salt / verifier / ciphertext / HMAC-SHA1 の先頭 10 byte の順。compressed size は全体
（圧縮結果 + 28 byte）。CTR は 1 始まりの 128 bit little-endian counter を CommonCrypto の
ECB で暗号化し、chunk 境界の鍵流の端数を次回へ持ち越す。HMAC の対象は ciphertext のみ。
ZIP64 予約長の計算にも暗号化 overhead を含め、local header は seek して patch する。

### ZIP ZipCrypto

PKWARE traditional encryption の 3 個の UInt32 鍵を UTF-8 パスワードで初期化する。
bit 3 がない場合、12 byte の encryption header の末尾は CRC の最上位 byte なので、
データを書き始める前に CRC が必要になる。圧縮 / store と CRC 計算を先に行い、圧縮結果だけを
出力の隣の `mkstemp`（mode 0600）へ保存する。CRC と packed size の確定後に local header、
11 byte の乱数 + CRC 上位 byte を暗号化した header、spool を暗号化した payload の順に出力する。
compressed size は spool + 12 byte。deinit による失敗時の削除と、成功時の明示的な close / unlink
を持ち、一時ファイルの I/O エラーは `WriterError.io` にする。

両 ZIP 方式とも **data descriptor は書かない**。既存の seek / patch と updater の layout 契約を
維持するためで、ZipCrypto の spool はそのために必要になる。AES は spool を使わない。

### 7z AES-256 と header

非空 stream ごとに non-solid folder を作る。実測した `7zz a -p... -mhe=off -mhc=off` と
同じ decoder 順で AES（06 F1 07 01）を coder 0、LZMA2（21）を coder 1 に置く。
bind pair は input 1 ← output 0、packed input は暗黙の 0。unpack sizes は AES 出力である
圧縮結果の真の長さ、LZMA2 出力であるファイル長の順で、substream CRC は元ファイルの CRC。

AES property は `53 0F` + 16 byte IV（NumCyclesPower 19、salt なし）。UTF-16LE パスワードと
8 byte little-endian counter を 0 から 2^19 - 1 まで連結して SHA-256 へ入力し、鍵を得る。
同じ鍵は書庫内で再利用できるが IV は毎回乱数で生成する。AES-256-CBC は PKCS#7 を使わず、
最後の block の不足だけを zero pad する。真の圧縮長を AES の unpack size に記録する。
空ファイル・directory は従来の EmptyStream / EmptyFile 表現を使う。

`SevenZipWriter.lzmaChunkSize` は **16 MiB**、I/O 用の `chunkSize` は **256 KiB** と分離する。
短い read が返っても最大 16 MiB まで入力を集めてから Apple の LZMA buffer API を一度呼ぶ。
各片の LZMA2 辞書 reset を残して終端 byte だけを取り除き、最後に一度だけ終端を書く。
圧縮出力も 256 KiB ごとに分割して暗号化・書込を行う。一つの folder 内で decoder が reset する
正当な stream であり、平文・暗号出力とも spool は不要。

Apple の encoder は 8 MiB の辞書を使う。16 MiB 以下のファイルは従来の whole-file buffer API と
同じ一回の圧縮なので、圧縮 payload と圧縮率は変わらない。16 MiB を超えるファイルだけ境界で
辞書の蓄積が失われる。256 KiB ごとに辞書を捨てる初期案はソースコードで出力が約倍増したため撤回した。
主な作業メモリの上限は一ファイルにつき **約 16 MiB の入力 + その圧縮出力**。別途 encoder の辞書・
framing の一時領域・256 KiB の I/O buffer があるが、いずれもファイル全体の長さに比例して増えない。
header metadata のメモリは entry 数と名前長に比例する。

header 暗号化を指定したときは通常の Header を AES-only folder に通し、その ciphertext を
全ファイルの packed data の後ろへ置く。NextHeader は `kEncodedHeader`（17）の StreamsInfo とし、
PackPos は署名の 32 byte 後を起点にした暗号化 header の位置、folder unpack size / CRC は平文 header。
StartHeader と NextHeader の CRC / offset / size は最後に確定する。名前の UTF-16LE byte は平文では残らない。

乱数は `SecRandomCopyBytes`、失敗は `WriterError.io(operation: "random", code: status)`。
AES / PBKDF2 / HMAC は CommonCrypto、7z KDF の SHA-256 は CryptoKit。依存は追加しない。
KaitoKit の内部暗号型を公開・共有せず、公開パラメータに従って GyoshukuKit 内で実装する。

### 編集と検証

updater の `options.password` は通常は追加分だけに適用し、既存 record は byte のまま運ぶ。
削除・改名だけなら ciphertext と既存 password を維持する。ZIP 全体をそろえる場合は
`reencryptExistingEntries(currentPassword:)` を一度予約する。圧縮データを作り直す必要はない。
他形式の rewriter は `password` で入力を復号し、`options.password` で出力を暗号化する。

XCTest は KaitoKit、ZIP AES / 7z AES の 7zz、ZipCrypto の unzip を oracle にする。
header byte・AE-1/AE-2 境界・誤パスワード・HMAC 改変・spool の成功/失敗時 cleanup・
更新前後の record・再暗号化・300 MiB の chunk 読取・xattr 更新を検査する。
40 MiB の固定 seed の擬似ソースコードを平文・暗号 7z の両方で KaitoKit / 7zz に往復させ、
同じ入力を Compression framework の `compression_encode_buffer` で一括圧縮した結果に対して
packed size が ±5% に収まることを確認する。参照圧縮は製品 compressor を呼ばない。
5 / 16 MiB では short read を混ぜても一括圧縮と payload が byte 単位で一致することを確認する。
実行済みの範囲と sandbox 制限は[検証記録](verification/2026-09-15-encryption.md)へ分けて記録する。

参照: [WinZip AES 仕様](https://www.winzip.com/en/support/aes-encryption/)、
[7z format](https://github.com/ip7z/7zip/blob/main/DOC/7zFormat.txt)、
[XZ の LZMA2 decoder の reset 処理](https://github.com/tukaani-project/xz/blob/master/src/liblzma/lzma/lzma2_decoder.c)。

### ZIP の再暗号化（P1b）

予約は `adding` 状態で一度だけ受け付け、remove / rename / add との順序に依存しない。
commit の `checkUnchanged` 後、生存する既存 entry だけを計画する。通常ファイルは options の
plain / ZipCrypto / AES-256、directory と symlink は平文にする。同じ方式・同じ UTF-8 byte の
password なら運ぶだけで、実際の password は検証しない。入力の全件検証は呼出側が行う。
空書庫や変換 0 件の予約は P1-G の経路・出力 byte・strategy・進捗を変えない。

`ZipRecordLayout` は KaitoKit SPI の encryption / storedCRC32 / compressionMethod も保持する。
`ZipPlannedAction.convert` は keep・canonical CD・同長改名 patch・descriptor marker の対象外。
変換 entry は descriptor を捨てるため ZIP32 descriptor の offset 越境拒否も不要になる。
運ぶ entry には従来の拒否を残す。追加分は writer が暗号化し、変換しない。追加位置の予測が
変換でずれたときは stagedRebuild、一致すれば rebuildThenAppend、追加なしは rebuild になる。

`OrderedChunkPipeline` は `WriterOptions.resolvedCompressionThreads` 件の窓で導出だけを並列化する。
入力は KaitoKit の `ZipAESKeyMaterial.derive`、出力は GK の PBKDF2-HMAC-SHA1（1,000 回）。
reader・出力・salt の乱数・TaskLocal observer は commit の thread だけで扱う。
乱数の試験注入は P1-G と同じ `testingRandomBytes`（AES salt 16 byte、ZipCrypto header 11 byte）。
出力の材料 66 byte / salt 16 byte は連続した Data に保存し、検証後に解放する。

AES の AE-2 から平文 / ZipCrypto へ変える場合だけ、pass A で展開 CRC を先に計算する。
payload は `zipStoredPayloadStream(at:aesKey:)` から最大 1 MiB ずつ復号し、既存の encryptor へ渡す。
圧縮器や ZipCrypto spool は呼ばない。小さい record は header から認証 tag まで一度に組み立てる。
local / CD の元の名前・時刻・属性・comment・未知 extra を保ち、暗号欄とサイズだけを組み直す。
0x0001 は先頭、0x9901 は既知 field の末尾、解析できない末尾は最後に置く。改名時は既存の
Unicode 名の無効化と不透明 extra の拒否を適用する。AES → AES は AE の版を保つ。

fsync・close 後、公開前に出力を読み直す。V0 は門番・entry 数・名前・種別・方式・サイズ・CRC・
暗号状態と、GK による local / CD の照合。P1-G の追加 record 検査も残す。V1 は全変換 entry の
復号した保存 payload の長さと CRC。V2 は ZipCrypto 入力・AE-2 の pass A 対象・平文 → AE-2 で
展開を検証し、CRC のない AE-2 は入力 CD の CRC と照合する。V3 は AES 出力の先頭・末尾を含む
等間隔の最大 16 件を password から導き直して保存 byte を照合する。AE-2 の encryption key だけが
誤っても HMAC / verifier が正しければ材料経由の読取は成功するため、V3 は省略しない。

入力の wrongPassword / passwordRequired だけはそのまま返す。V2 が失敗した ZipCrypto 入力は
通常の stream で読み直し、照合 byte が偶然合った誤 password を区別する。出力検証の失敗は
`reencryptionFailed` に包み、取消しは `CancellationError` のまま返す。変換中の I/O は従来どおり。
`CommitProgress` は書込み + pass A / V1 / V2 / V3 の保存長 + 導出 1 回 65,536 の仕事量。
total は計画時に固定し、完了時の一致を確認してから公開する。失敗と取消しは作業ファイルを削除する。

実測と A2–A10 の範囲は [P1b 検証記録](verification/2026-09-25-p1b-reencryption.md) を参照。

## 9. やらないこと

- **RAR の作成**。license が
  「cannot be used to develop RAR (WinRAR) compatible archiver」と明示している。
- **SFX の作成**。macOS では成立しない —— data を追記した Mach-O は正しく署名
  できず、ad-hoc 署名の実行ファイルは Gatekeeper に拒否され、quarantine が付けば
  Apple Silicon では SIGKILL される。作っても相手の Mac で動かない。
- **sparse file の検出**。bsdtar は自動で行うが、結果は改名された entry と
  GNU.sparse.* pax record で、規約を知らない reader を混乱させる。GUI 利用者が
  踏むことはまず無い割に writer の複雑さがほぼ倍になる。

> **GyoshukuKit design (2026-09-10, first edition)**
>
> GyoshukuKit is the compression half of a pair whose extraction half is KaitoKit.
> KaitoKit is read-only by design, and adding writing to it would push writer code
> into consumers that only ever read; a separate repository makes that separation
> structural rather than asserted. It inherits KaitoKit's character: pure Swift,
> no additional external dependencies, only OS-bundled zlib, libbz2, Apple Compression
> and CommonCrypto / CryptoKit / Security
> through supported APIs — deliberately not the system libarchive, which ships no
> `archive.h` in the SDK and has no in-place update anyway.
>
> The dependency runs one way only, GyoshukuKit to KaitoKit, because updating an
> archive means reading the existing one to carry surviving entries across without
> recompressing them, and KaitoKit already has the hardened parser for that.
>
> The API mirrors `ArchiveReader`: an `ArchiveWriter` for creation and an
> `ArchiveUpdater` for add, remove and rename, committed through a temporary file
> and an atomic replace. Neither is thread-safe, matching KaitoKit's contract.
>
> Formats arrive in four stages — ZIP, then tar and the compressed tars, then 7z,
> then LHA. `CompressedTarUpdater` edits gzip, bzip2 and xz tar archives from a
> session reader's decoded image and chunk map. It carries reusable compressed
> chunks unchanged and encodes the changed regions. Inputs without usable framing
> receive a full encode into the member-aligned layout on their first edit.
> The caller must verify the output with KaitoKit's K5 before publication; a full
> verification open is the fallback only when K5 reports `baseNotSpliceable`.
>
> Defaults are chosen so a recipient on Windows is not inconvenienced: UTF-8 names
> with bit 11 and NFC normalization, UNIX host byte so POSIX modes and symlinks
> survive, no data descriptors written but always parsed because `ditto` emits
> them, no macOS metadata in tar by default, and no owner names leaked.
>
> Stage-one append clones the archive with APFS, leaves old local records at
> their original offsets, writes new local records at the old CD offset, then
> copies the old CD bytes verbatim and emits the new CD and combined end records.
> ZIP64 appears whenever the combined values require it. No descriptor scanning
> or existing-name re-encoding is needed. Commit uses `replaceItemAt`, immediately
> restores POSIX permissions and restores quarantine when originally present.
> Stage three (0.3.0) uses KaitoKit 0.4.0 raw records for deletion and renaming,
> rebuilding the complete CD with new offsets and independent ZIP64 fields.
> Indices remain stable from open, and subtree policy belongs to the caller.
> Equal-length local renames patch headers; different lengths re-emit headers
> while copying stored payloads and descriptors. Only authored names gain UTF-8/NFC.
> Mixed additions are completed in the clone and read from a separate snapshot
> during rebuilding. Cancellation and failure discard the working copies.
> A ZIP32 descriptor gaining an offset-only ZIP64 extra is refused because
> KaitoKit 0.4.0 would reinterpret the descriptor width; the original remains intact.
> Editing is refused — while reading still works — for SFX-prefixed ZIPs, ZIPs
> with trailing data after the EOCD, and ZIPs whose declared central-directory
> offset does not point at a `PK\x01\x02` signature, the last being a measured
> trap: `ditto` writes entries above 4 GiB with no ZIP64 at all and truncates
> three separate values mod 2^32.
>
> Remove and rename use the KaitoKit 0.4.0 accessor, `rawRecord(of:)`,
> exposing the byte range of an entry's stored record with the data-descriptor
> arithmetic done on KaitoKit's side so writer and reader cannot disagree. Stage
> one does not need it. GyoshukuKit does not change KaitoKit's source.
>
> Password output supports ZIP WinZip AES-256 or ZipCrypto, plus non-solid 7z
> AES-256-CBC and optional encrypted headers. ZIP still writes no descriptors;
> ZipCrypto spools compressed bytes to learn the CRC first, while AES streams.
> 7z bounds its LZMA2 input to 16 MiB while I/O and encryption stay at 256 KiB.
> Files up to 16 MiB retain the whole-buffer compression ratio; larger files reset
> the dictionary at chunk boundaries. A 40 MiB corpus guards packed size within
> 5% of whole-buffer Apple compression. Updaters encrypt additions by default and can explicitly
> re-encrypt existing ZIP payloads without recompression. Rewriters separate input and output
> passwords. File-change checks exclude ctime to allow Finder tag and xattr updates.
>
> Three things are deliberately never done: writing RAR, whose licence forbids it;
> creating self-extracting archives, which cannot be validly signed on macOS and
> would be killed by Gatekeeper on the recipient's Mac; and sparse-file detection,
> which roughly doubles writer complexity for a case a GUI archiver's users
> essentially never hit.
