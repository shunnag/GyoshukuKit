# WriterOptions リファレンス

[README の設定一覧](../README.md#よく使う設定)を補う全項目の表です。[WriterOptions.swift](../Sources/GyoshukuKit/API/WriterOptions.swift)の公開設定に対応し、設定値は `Sendable` です。形式 ID・preset・互換性は[形式リファレンス](formats.md)を参照してください。

## 全オプション

| `WriterOptions` | 既定値 | 意味 |
|---|---|---|
| `compressionMethod` | `.deflate` | ZIP の `.stored` / `.deflate` / `.bzip2` / `.lzma` / `.zstd` / `.xz` / `.ppmd` |
| `sevenZipMethod` | `.lzma2` | 7z の `.lzma2` / `.lzma` / `.deflate` / `.bzip2` / `.ppmd` / `.copy`。追加・再圧縮・7z への rewriter に適用 |
| `sevenZipSolid` | `.off` | `.on(blockSize:filesPerBlock:)` で入力順に非空ファイルを一つの folder にまとめる。nil は[solid の既定上限](formats.md#solid-と-filter) |
| `sevenZipFilter` | `.none` | `.auto` / `.bcjX86` / `.arm64` / `.delta(distance: 1...256)`。圧縮前の変換 |
| `lhaMethod` | `.lh5` | LHA の `.lh5` / `.lh6` / `.lh7` / `.stored`。新規追加・LHA への rewriter に適用。updater が運ぶ既存 member の byte は保持 |
| `lhaLevel` | `6` | LHA の探索量 `1...9`。既定の LH5 出力 byte は従来と同じ。stored は探索しない |
| `deflateLevel` | `6` | ZIP / 7z Deflate / tar.gz / 単独 gzip の zlib level `0...9` |
| `bzip2Level` | `9` | ZIP / 7z BZip2 / tar.bz2 / 単独 bzip2 の block size level `1...9`（100,000〜900,000 byte） |
| `zstdLevel` | `3` | tar.zst / 単独 .zst / ZIP method 93 の自前 encoder preset `1...19`。参照 encoder の同じ数値と探索量・圧縮率は一致しない |
| `ppmdLevel` | `6` | ZIP / 7z PPMd の order / model memory preset `1...9`。[preset 表](formats.md#ppmd)を参照 |
| `ppmdOrder` | `nil` | preset の order を上書き。ZIP は `2...16`、7z は `2...32` |
| `ppmdMemoryMiB` | `nil` | preset のモデルメモリを MiB 単位で上書き。ZIP は `1...256`、7z は encoder が対応する `1...1024` |
| `lzmaLevel` | `nil` | tar.xz / 7z LZMA2 / ZIP XZ は nil なら従来の Apple preset-6。`0...9` は自前 encoder。ZIP / 7z LZMA と tar.lzma / tar.lz は常に自前で nil は6。単独 XZ / LZMA / lzip も同じ解決 |
| `lzmaExtreme` | `false` | 自前 LZMA の探索量を増やす。tar.lzma / tar.lz / 単独 LZMA・lzip は nil でも使い、他はレベル指定時だけ |
| `memoryLimit` | `nil` | 自前 LZMA / Zstandard と ZIP / 7z BZip2 の圧縮予約の予算（byte）。物理メモリの50%との小さい方を使い、nil は50%。自前 LZMA / Zstandard は一つも入らなければ `invalidOption("memoryLimit")`。BZip2 は逐次へ戻す。新しい LZMA / XZ 項目・folder窓は Apple codec の見積りも含めるが、2枠未満なら従来経路へ戻す。Apple の既存 block 経路と他の codec には適用しない |
| `useCompressionHeuristic` | `true` | jpg/png/zip 等、既知の圧縮済み拡張子を stored にする |
| `preserveOwnerIDs` | `false` | ディスク由来の uid/gid を保存。ZIP は 0x7875、tar は数値欄（既定0、uname/gname は常に空）。7z / LHA は true を拒否 |
| `preserveMacOSMetadata` | `false` | true はこの段階では `unsupportedOption` |
| `password` | `nil` | ZIP / 7z の暗号化出力。空文字列は `invalidOption("password")` |
| `zipEncryption` | `.aes256` | WinZip AES-256。`.zipCrypto` は従来の PKWARE 暗号 |
| `encryptsSevenZipHeaders` | `false` | 7z のファイル名を含む header も暗号化。パスワードが必要 |
| `compressionThreads` | `nil` | ZIP / 7z / LHA の項目・folder・memberと、圧縮 tar / 単独 gzip・bzip2・XZ・Zstandard・lzip・LZ4 の並列数 `1...64`。項目窓は最大16枠、メモリ予算でも制限する。ZIP / 7z BZip2 は大項目内を単一 stream spliceで並列化する。LZMA1 / PPMd の一つの stream と LZMA_Alone / Brotli / compress は逐次。ZIP 再暗号化の鍵導出にも使用。自動は CPU 数・物理メモリ GiB・16 の最小値（最低1） |
| `additionPlacement` | `.end` | rewriter の追加位置。`.beginning` で従来の先頭追加 |
| `carriedTarOwnerIDs` | `.keep` | rewriter で運ぶ tar の uid/gid を維持。`.reset` で 0 にする。ディスクからの追加には `preserveOwnerIDs` を使用 |

`memoryLimit` は byte 単位の正の値、`compressionThreads` は `1...64` です。範囲外は `WriterError.invalidOption`。solid の明示的な `blockSize` / `filesPerBlock` は正の値に限ります。設定は出力・作業ファイルを作る前に検証します。各 level は、その codec を選んでいない場合も範囲検査します。

## 並列処理と出力の待機

自動並列数は `max(1, min(CPU 数, 物理メモリ GiB, 16))` です。16-core / 128 GiBは16、10-core / 16 GiBは10になります。小〜中項目の窓は最大16枠で、メモリ予算によりさらに減らします。出力は追加順を保ちます。`compressionThreads: 1` は同期、2以上では後続の `add` / `finish` まで出力・エラー通知が遅れる場合があります。明示的に待つには `finishAdditions(progress:)` を使います。

ZIP LZMA / XZ / Zstandard / PPMd と non-solid 7z LZMA / PPMd は16 MiB以下の項目を並列化します。ZIP / 7z BZip2 は約5 block分以下を項目間、それより大きい項目内は block を並列化し、完全な単一 stream に splice します。大項目と filter なしの 7z Copy は従来の stream 経路です。ZIP XZ と7z LZMA2 / Deflate は大項目内の block も並列化します。LHA は1 MiB超〜16 MiBの member も項目間で並列化し、内部の1 MiB境界と履歴を保持します。

ZIP deflate（ZipCrypto を除く）/ tar.gz は最大 1 MiB ごとに raw deflate を圧縮し、直前の末尾 32 KiB を辞書に使います。
ZIP Deflate の小さい member は個別の `add(contentsOf:as:)` 呼出し間でも並列化し、出力は追加順です。
ZIP BZip2 / PPMd は一つの stream を完結させ、上記の項目間並列化（BZip2 は大項目内の splice も）を使います。ZIP XZ の既定は最大16 MiBの block を
`compressionThreads` で並列化し、一つの stream header・index・footer で包みます。一括 disk 追加も同じ経路です。
`maximumPendingInputBytes(for: .zip)` は項目窓と内側の圧縮待ちを含みます。正確な式は下の表を参照してください。大項目内の XZ block はその項目の追加終了時に全て出力します。小項目の窓は後続の追加や `finishAdditions` / `finish` まで残る場合があります。BZip2 の codec state は最大約7.6 MBと I/O buffer、
Apple XZ は thread ごとに約130 MiBと組立中16 MiBを使います。XZ の index は block 数に比例します。

ZIP の暗号化では salt が毎回変わります。圧縮失敗は後続の `add` / `finish` で通知されることがあります。
ZIP Deflate の入力上界は `compressionThreads × 1 MiB`（ZipCrypto は0）。tar.gz / tar.bz2 は未出力 chunk に組立中の入力も加え、公開 API の上界を `(compressionThreads + 1) × chunk size` とします。
Apple 経路の tar.xz の未出力 block は、並列数が2以上のとき64 KiB以下を並列数に数えず、合計で最大
`2 × compressionThreads + 1` 個です。並列数1は同時に一つだけを符号化します。
deflate / bzip2 の主なメモリは thread ごとに入力と出力（約2 × chunk size）と codec state、
Apple LZMA2 は16 MiBの片を使うと thread ごとに約130 MiBです。待機中の取消しは50 msごとに確認します。
Apple 経路の tar.xz の待機中の入力と組立中の入力の上界は、解決した並列数を `t` として `t × 16 MiB + 4 MiB` です。`t` が2以上なら、さらに `(t + 1) × 64 KiB` を加えます。
この入力の上界は codec state と出力を含みません。小さなファイルの多い tar.xz は従来より5–12%大きくなります。
tar.bz2 の chunk は内部 block size の5倍です。level 9 は4,500,000 byteごとの独立streamとなり、
thread ごとの入力・出力約9 MBとcodec state約7.6 MBで合計約16.6 MB（約15.8 MiB）を使います。

## Pending input の意味

`maximumPendingInputBytes(for:)` は検証済み options に対する、待機中の入力 byte の上界です。codec state・圧縮出力・XZ index を含む RSS の上限ではありません。solid / filter 付き 7z は disk 上の未圧縮 spool も数えます。圧縮出力は1 MiBまでメモリ、それを超えると unlink 済み disk spool に保持します。

以下で `t` は対応経路が解決した並列数、`p` は LZMA2 の片サイズ、`e` は項目窓（2枠以上なら `窓の枠数 × 16 MiB`、逐次なら0）、`b` は BZip2 内側並列（2以上なら `(内側並列数 + 1) × 8 MiB`、逐次なら0）です。

| 形式・方式 | 入力の上界 |
|---|---|
| ZIP Stored / ZipCrypto Deflate | 0 |
| ZIP Deflate | `compressionThreads（自動解決後）× 1 MiB` |
| ZIP LZMA / Zstandard / PPMd | `e` |
| ZIP BZip2 | `max(e, b)` |
| ZIP XZ | `max(e, (t + 1) × p)` |
| tar / LZMA_Alone / Brotli / compress | 0 |
| tar.gz / tar.bz2 | `(compressionThreads（自動解決後）+ 1) × chunk size` |
| tar.xz（自前） | `t × p + 4 MiB` |
| tar.xz（Apple） | `t × 16 MiB + 4 MiB`、tが2以上ならさらに `(t + 1) × 64 KiB` |
| tar.zst / tar.lz / tar.lz4 | `t × 片` / `t × member 上限` / `t × 4 MiB` |
| 通常の7z LZMA2 / Deflate | `t × p` / `compressionThreads（自動解決後）× 1 MiB` |
| non-solid 7z LZMA / PPMd / BZip2 / filterなしCopy | `e` / `e` / `max(e, b)` / 0 |
| 7z solid / filter | folder窓の入力上界。BZip2 は `b` と、内側並列時に `folder枠数 × 8 MiB` も加算 |
| LHA（圧縮並列数が2以上） | `max(e, compressionThreads（自動解決後）× (1 MiB + 辞書履歴))`。逐次・stored は0 |

`maximumPendingInputBytes(for: .sevenZip)` は通常の LZMA2 が `解決した並列数 × 片サイズ`、Deflate が `compressionThreads × 1 MiB`、
LZMA / PPMd が項目窓の入力上界、BZip2 が項目窓と内側 splice buffer の大きい方です。filterなしの Copy は0です。
solid / filter の値は disk上の folder入力も数え、BZip2 は内側bufferも加えます。codec stateや圧縮出力を含むRSS上限ではありません。

7z solid の窓は `枠数 × block 上限`、filter付き non-solid は `枠数 × 16 MiB` です。解決したblock上限が256 MiBを超える場合とfilterなしCopyは一枠の逐次経路を使います。分割しない単一ファイルが block 上限を超える場合、実 spool に必要な容量はそのファイルのサイズです。

folder一枠の予約は `I/O + 最大片数 × codec状態` です。LZMA1 / PPMd / Copyは最大片数1、LZMA2 / Deflateは `min(要求並列数, ceil(folder上限 / 片サイズ))` です。I/Oは入力16 MiB・出力spool 1 MiB・4 × 256 KiBです。全folderの割当codec数も `min(要求並列数, floor(予算 / codec状態))` 以下に保ちます。BZip2の既存splice予約は維持します。
入力上界の式は同じですが、folder枠数の増加により値が増える場合があります。物理16 GiB・要求12・既定level・予算8 GiBでは、64 MiB solidのLZMA2は320→768 MiB、LZMA1は384→768 MiB、PPMd level 9の明示64 MiB solidは192→768 MiBです。filter付きnon-solidのLZMA2は80→192、LZMA1は96→192 MiBです。PPMd level 9は既定block上限384 MiBによる同期経路を維持し、既定solidは384 MiB、filter付きnon-solidは16 MiBのままです。自動並列数も最大8→16となるため、他形式の既定入力上界も各経路のメモリ制限内で増えます。

`maximumPendingInputBytes(for: .lha)` は圧縮並列数 `t > 1` のとき `max(項目窓の入力上界, t × (1 MiB + 辞書履歴))`、
逐次またはstoredなら0です。出力・codec表はこの入力byte数に含みません。

## LZMA のレベルとメモリ予算

`WriterOptions(lzmaLevel: 9, lzmaExtreme: true)` は tar.xz / ZIP XZ / 7z LZMA2 の自前 encoder を選びます。
片ごとに辞書を reset し、辞書が16 MiBを超えるレベル8・9では xz の block size 規則に合わせて3倍の片を使います。
ZIP LZMA は entry ごと、7z LZMA は folder ごとに一つの stream を符号化し、片に分けず項目・folder間を並列化します。
ZIP 14 は EOS と general purpose bit 1 を付けます。7z は folder の既知サイズを使い EOS を省略します。

自前 LZMA2 の実際の並列数 t は `t × (encoder memory + 2 × 片サイズ)` が
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)` 以下になる最大数に制限します。
要求した並列数を上限とし、1個分も入らなければ書庫を作る前に `WriterError.invalidOption("memoryLimit")` を返します。
メモリ不足で宣言辞書を縮小しません。自前 tar.xz は小さい block も t 個の枠に数えます。
入力の上界は自前 tar.xz が `t × 片 + 4 MiB`、通常の7z LZMA2 が `t × 片`、
ZIP XZ が `(t + 1) × 片` と項目窓の入力上界の大きい方です。solid / filterはfolder窓の上界を使います。

| `lzmaLevel` | 辞書 MiB | LZMA2 encoder MiB | 片 MiB | LZMA2 1 thread の予算 MiB | raw LZMA1 の同期予算 MiB |
|---|---:|---:|---:|---:|---:|
| 0 | 0.25 | 5 | 16 | 37 | 19 |
| 1 | 1 | 10 | 16 | 42 | 25 |
| 2 | 2 | 17 | 16 | 49 | 32 |
| 3 | 4 | 31 | 16 | 63 | 46 |
| 4 | 4 | 47 | 16 | 79 | 62 |
| 5 / 6 | 8 | 91 | 16 | 123 | 106 |
| 7 | 16 | 179 | 16 | 211 | 194 |
| 8 | 32 | 355 | 96 | 547 | 370 |
| 9 | 64 | 643 | 192 | 1027 | 658 |

64-bit の通常 preset を MiB 単位で切り上げた値です。extreme のレベル0〜3は BT4 に替わり、
それぞれ1 / 4 / 8 / 16 MiB増えます。raw LZMA1 の予算は range buffer の最大16 MiBと I/O を含みます。
短い入力では encoder の実確保が減りますが、検証・並列数解決は表の完全な辞書で行います。
Apple の nil レベル経路は従来の byte と16 MiB境界を維持し、この予算で並列数を変えません。

## lzip と LZ4

lzip の並列数は `t × (raw LZMA1 encoder memory + 2 × member 上限)` が
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)` 以下になるよう制限します。
既存の LZMA 経路と同じく、辞書を縮めず、一つも入らなければ `invalidOption("memoryLimit")` を返します。
level 0 / 6 / 9 の member 上限は16 / 24 / 192 MiBです。
`maximumPendingInputBytes(for:)` の入力上界は lzip が `t × member 上限`、LZ4 が `t × 4 MiB`、
LZMA_Alone / Brotli / compress は0です。codec 内部の辞書・bufferと出力はこの値に含みません。

## Zstandard のメモリ予算

Zstandard はレベル1...12が4 MiB、13...19が8 MiBの片です。
実際の並列数 t は encoder の見積りと入力・出力二片、framing の余白がメモリ予算に入る最大数です。
`maximumPendingInputBytes(for: .tarZstd)` は組立中を含め `t × 片`。ZIP Zstandard は entry 内では単一 frame の逐次出力ですが、項目窓を使う場合の入力上界は `e` です。
