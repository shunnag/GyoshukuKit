# 形式・方式・互換性

[README の対応表](../README.md#対応機能)を補う、方式 ID・preset・framing・出力制限のリファレンスです。全設定は [WriterOptions](options.md)、編集経路は[使用ガイド](usage.md#更新と再構築)を参照してください。

## ZIP

ZIP の書き込み方式は次の七つです。updater の新規追加と ZIP への rewriter も同じ設定を使います。

| 方式 | method | encoder |
|---|---|---|
| `.stored` | 0 | 無圧縮 |
| `.deflate`（既定） | 8 | system zlib の raw deflate |
| `.bzip2` | 12 | system libbz2 の単一 bzip2 stream |
| `.lzma` | 14 | 自前の単一 raw LZMA1 stream、EOS 付き。展開要求 version 6.3 |
| `.zstd` | 93 | 自前の content checksum 付き単一 Zstandard frame。展開要求 version 6.3 |
| `.xz` | 95 | Apple または自前 LZMA2 と XZFraming の完全な単一 XZ stream |
| `.ppmd` | 98 | 自前の単一 PPMd var.I rev.1 stream。2 byte parameter word、restoration は restart。展開要求 version 6.3 |

macOS Archive Utility / ditto と `/usr/bin/unzip` は method 12 / 14 / 93 / 95 / 98 を展開できません。
互換性のため Deflate を既定に保ち、BZip2 / LZMA / Zstandard / XZ / PPMd は KaitoKit や 7-Zip を使う場合の opt-in にします。
AES-256 では header の method は99、0x9901 に実際の圧縮 method（0 / 8 / 12 / 14 / 93 / 95 / 98）を記録します。ZipCrypto も圧縮後の byte を暗号化します。

ZIP の空ファイル・ディレクトリ・symlink は常に stored です。通常ファイルの payload は
256 KiB 単位で読み書きし、作業メモリをファイルサイズに比例させません。central directory 用の
メタデータは entry 数と名前長に比例します。

ZIP の名前は UTF-8 で書き、bit 11 を常に立てます。
ZIP の mtime / atime は秒単位で、extended timestamp の符号付き 32 bit Unix 秒の範囲外は
`invalidDate` です。DOS 日付にはローカル時刻を使い、表現範囲へ丸めます。

UNIX host、POSIX mode、symlink、local / central で長さの違う timestamp extra、
ZIP64 に対応します。local header を seek で patch し、data descriptor は書きません。
ZIP64 の central / EOCD はフィールドごとに sentinel を選びます。local の例外では
両サイズを 0x0001 に載せ、両サイズ欄を sentinel にします。

Zstandard の method / version と互換検証は [Zstandard](#zstandard)、圧縮の待機・メモリは[並列処理](options.md#並列処理と出力の待機)を参照してください。

## 7z

7z の書き込み方式は `SevenZipCompressionMethod` で選びます。既定は非空ファイルごとに一つの non-solid folder です。

| 方式 | method ID | encoder |
|---|---|---|
| `.lzma2`（既定） | `21` | Apple または自前 LZMA2、dictionary property 1 byte |
| `.lzma` | `03 01 01` | 自前の単一 raw LZMA1 stream、EOS 無し。lc/lp/pb + 辞書 LE32 の5 byte properties |
| `.deflate` | `04 01 08` | system zlib の raw deflate、`deflateLevel` |
| `.bzip2` | `04 02 02` | system libbz2 の単一 bzip2 stream、`bzip2Level` |
| `.ppmd` | `03 04 01` | 自前の単一 PPMd var.H stream。order byte + model memory LE32 の5 byte properties |
| `.copy` | `00` | 無圧縮。入力 byte をそのまま保存 |

Copy / Deflate / BZip2 の coder に properties は置きません。7z は ZIP の拡張子 heuristic を使わず、
指定方式を全ての非空 stream に適用します。updater の追加と solid folder の再圧縮、7z への rewriter も
`sevenZipMethod` を使います。運ぶ既存 folder の coder と packed byte は保持し、AES の設定・変更・解除も再圧縮しません。
Deflate は最大1 MiBの block を直前の末尾32 KiBの辞書で圧縮し、一つの raw deflate stream に連結します。
LZMA / PPMd は folder ごとに一つの stream を保ち、複数 folder を並列圧縮します。Copy は filterなしなら同期出力です。
BZip2 は小 folder を項目間、大 folder は内部 block を並列圧縮して単一 streamへspliceします。

### Solid と filter

`sevenZipSolid: .on()` は入力順を保ち、空ファイルと directory を件数・サイズに数えません。
サイズの既定上限は `min(4 GiB, max(64 MiB, 辞書 × 2))`、件数は1,000,000です。
Apple LZMA2 と他の方式の基準辞書は8 MiB、自前 LZMA / LZMA2 は選択 level の辞書、PPMd は model memory を使います。
ファイルは分割せず、上限を超えるものは単独の folder にします。全方式と AES・header 暗号化を併用できます。
一つの block の入力を出力の隣の unlink 済み一時ファイルへ流し、確定したサイズで圧縮します。
一時ディスクには未出力folderの入力と、メモリの1 MiBを超えてspillした圧縮出力を保持します。
folder窓は最大16枠で、blockSizeが256 MiBを超える場合とfilterなしCopyはfolder間を逐次処理します。
ファイルを分割しないため、上限を超える単一入力のspool容量も必要です。
solid の `maximumPendingInputBytes` はメモリ使用量ではなく、disk 上に待つ folder窓の入力上界です（BZip2 は内側bufferも含む）。

`.auto` は先頭64 KiB内の magic / CPU を調べ、x86・x86_64 PE / 単一 Mach-O に BCJ、
arm64 PE / 単一 Mach-O / ELF64 に ARM64 を使います。universal Mach-O と未判定の入力は変換しません。
non-solid はファイル別、solid は filter の種別が変わるたびに block を区切ります。
filter の状態と命令位置は同じ folder のファイル境界を越えて続きます。Delta の距離は1〜256です。
updater の追加は設定に従う新しい folder を末尾へ置き、既存 folder の一部削除では元の filter と開始位置を保ちます。
既定の `.off` / `.none` の出力 byte は従来と同じです。

```swift
let options = WriterOptions(
    sevenZipSolid: .on(blockSize: 128 << 20, filesPerBlock: 10_000),
    sevenZipFilter: .auto
)
```

## PPMd

PPMd の preset は次の通りです。ZIP と7zで variant と order が異なります。

| `ppmdLevel` | ZIP var.I order | 7z var.H order | model memory（MiB） |
|---|---|---|---|
| 1 | 3 | 3 | 1 |
| 2 | 4 | 4 | 2 |
| 3 | 5 | 4 | 4 |
| 4 | 6 | 5 | 8 |
| 5 | 8 | 6 | 16 |
| 6（既定） | 8 | 6 | 16 |
| 7 | 10 | 8 | 32 |
| 8 | 12 | 12 | 64 |
| 9 | 16 | 16 | 192 |

`WriterOptions(compressionMethod: .ppmd, ppmdLevel: 9, ppmdOrder: 7, ppmdMemoryMiB: 3)` は
order 7・3 MiB の ZIP を書きます。7z は `sevenZipMethod: .ppmd` を使います。
モデルは ZIP の entry / 7z の folder ごとに一つ、solid では block 内の file 境界を越えて保持します。
指定した model memory と固定 I/O buffer を使い、入力長に比例してメモリを増やしません。
`compressionThreads` による片の並列化は行わず、`memoryLimit` は PPMd に適用しません。
entry / folder 間は並列化しますが、一つのモデルは片に分割しません。
モデルのメモリが尽きると restart します。AES・7z header 暗号化・全 filter を併用できます。
7zz の ZIP 一覧は `PPMd` のみを表示し、7z は `PPMD:o6:mem24` のように表示します。
`mem24` は2^24 byte、2の冪でない192 MiBは `mem192m` です。

## LHA

LHA は `WriterOptions(lhaMethod: .lh7, lhaLevel: 9)` のように方式と探索量を選べます。
`.lh5` / `.lh6` / `.lh7` は8 / 32 / 64 KiB辞書を使い、縮まないファイルは `-lh0-` にします。
`.stored` は圧縮を試さず全ファイルを `-lh0-` で逐次保存します。ディレクトリは常に `-lhd-`、名前はCP932です。
圧縮する場合は1 MiBまでのmemberをメモリで処理し、それより大きいmemberは1 MiB入力と方式ごとの辞書履歴で
分割します。block間のbitを継続し、同じ設定なら逐次・並列の出力byteは一致します。

| `lhaLevel` | 一致探索の候補数（chain depth） | 探索 |
|---|---|---|
| 1 / 2 / 3 | 8 / 16 / 32 | 貪欲 |
| 4 / 5 / 6（既定） | 64 / 128 / 256 | 貪欲 |
| 7 | 512 | 貪欲 |
| 8 / 9 | 1024 / 2048 | 1 byte先に長い一致があればliteralを先に置くlazy matching |

最大一致長は全levelで256 byte、Huffman blockは32,768 commandです。level6は従来の探索を維持します。
64-bit環境でthreadごとの主なbufferは入力1 MiB + 履歴8 / 32 / 64 KiB、hash表512 KiB、
chain表64 / 256 / 512 KiB、command表512 KiBと圧縮出力約1.1 MiBで、合計の目安は約3.2 / 3.4 / 3.7 MiBです。
Foundationの一時コピー・Huffman木の作業領域は別に必要です。storedは通常のI/O bufferだけを使います。

項目窓を含む入力上界は[設定リファレンス](options.md#pending-input-の意味)を参照してください。

圧縮候補は作成直後unlinkするmode0600のspoolへ書き、raw bytesは未完成出力に保持します。
作業用ディスクには一時的にraw bytesと圧縮候補の空きが必要です。取消し・途中失敗・容量不足時は
spoolを閉じ、未完成出力を無効化して削除します。256 MiB入力でのwriter単体peak RSSは約14 MiBでした。
再現できる測定条件と限界は[横断検証](verification/2026-09-17-release-hardening.md)に記録します。
方式の辞書サイズと最大一致長は [LHa for UNIX header.doc](https://github.com/jca02266/lha/blob/master/header.doc.md)、
methodの対応と検査・抽出コマンドは [Lhasa 利用者文書](https://github.com/fragglet/lhasa/blob/master/doc/lha.1) を参照します。

## 圧縮 tar

tar.xz はレベル未指定時に Apple Compression、tar.bz2 は macOS の libbz2 をプロセス内で使います。
TarWriter の 256 KiB の入力をストリーム圧縮し、書庫全体をメモリへ保持しません。
XZ は `lzmaLevel: 0...9` の自前経路、bzip2 は `bzip2Level: 1...9` を選択できます。
所有者・リンク・タイムスタンプ・取消し・失敗時の cleanup は通常の tar と共通です。

tar.gz は従来の header を持つ単一 gzip member、tar.bz2 は最大 `5 × bzip2Level × 100,000` byte の
完全な bzip2 stream の連結です。通常の tar member は途中で切らず、先頭で gzip の同期点・bzip2 stream を区切り、
上限を越える member は header 群と本文を分けて片にします。tar の終端は独立した区切りです。
thread 数を変えても圧縮 byte 列は変わりません。
tar.xz は header 群・本文・詰め物を合わせて4 MiB以下の member を最大4 MiBの block に詰めます。
4 MiBを越える member は header 群と本文を別の block にし、本文と大きな header 群を片に分けます。
nil レベルは最大16 MiB、自前 encoder は[LZMA の片サイズ](options.md#lzma-のレベルとメモリ予算)です。
tar の終端は独立した block です。既存書庫の編集では、変更した区間だけにこの規則を使います。

`ArchiveFormat` の `.tarZstd` / `.tarLZMA` / `.tarLzip` / `.tarLZ4` / `.tarBrotli` / `.tarCompress` は、
通常の `TarWriter` の出力を次の framing で包みます。拡張子はライブラリが決めず、呼出側が指定します。

| 形式 | framing と分割 | レベル |
|---|---|---|
| tar.zst | RFC 8878 の checksum 付き独立 frame の連結。member 境界を優先し、最大 `max(4 MiB, level の window)`。大きい header 群・本文を分割し、終端を独立 frame にする | `zstdLevel` 1...19、既定3 |
| tar.lzma | 13 byte の LZMA_Alone header（未知サイズ）と EOS、逐次単一 LZMA1 stream | `lzmaLevel` 0...9、nil は6、extreme 対応 |
| tar.lz | lzip v1 の独立 member。tar member 境界を優先し、最大 `max(16 MiB, 3 × 辞書)`、終端は独立 member。CRC32・入力長・member 長を照合できる | `lzmaLevel` 0...9、nil は6、extreme 対応 |
| tar.lz4 | content checksum 付き単一 LZ4 frame、4 MiB の独立 block を並列化 | 単一レベル |
| tar.br | Apple Brotli の逐次単一 stream | Apple の固定 level 2、指定なし |
| tar.Z | block mode LZW、maxbits 16、逐次単一 stream | 指定なし |

lzip の member 上限・メモリ予算は[設定リファレンス](options.md#lzip-と-lz4)、区間更新と全体再構築の選択は[編集経路](usage.md#新しい圧縮-tar-の更新経路)を参照してください。

## 単独ストリーム

gzip は1 MiB block、bzip2 は `5 × level × 100,000` byte の独立 stream、XZ は通常16 MiBの block
（自前の大辞書では3 × 辞書）、Zstandard は固定 `max(4 MiB, window)` の独立 frame、lzip は圧縮 tar と同じ独立 member、LZ4 は4 MiB blockを並列化します。
レベルは tar の対応形式と同じ設定を使います。単独 gzip も tar.gz と同じく FNAME なし、MTIME 0、OS=3です。
ファイル名や日時を stream に保存しません。空 .Z は仕様上 header のみで、BSD uncompress / gzip が拒否する
既知の制限があります。KaitoKit と7zzは空を復元できます。

通常ファイルのみを受け付ける API と原子的公開・取消しは[単独ファイル](usage.md#単独ファイル)を参照してください。

## Zstandard

ZIP は entry ごとに単一 frame を書き、入力サイズに比例するメモリを使いません。
[APPNOTE §4.4.5](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) の現行 method 93を使い、
要求 version の表に Zstandard の明記がないため、writer は6.3を選びます。
7-Zip 26.03で非暗号・AES・ZipCryptoの `t / x` を確認しました。ZIP内の並列frame連結は使いません。

level ごとの片サイズ・メモリ予算・pending input は[設定リファレンス](options.md#zstandard-のメモリ予算)を参照してください。

## 暗号化

ZIP のパスワードは UTF-8、7z は UTF-16LE を使います。ZIP は空ファイルも暗号化し、
ディレクトリと symlink は暗号化しません。AES は 20 byte 未満を AE-1（CRC あり）、
20 byte 以上を AE-2（CRC 欄は 0）で書き、作業ファイルを使わず stream に暗号化します。
ZipCrypto は CRC の確定が必要なので、出力の隣で mode 0600 の一時ファイルを排他的に作成し、
書込前に unlink した descriptor へ圧縮結果を spool します。暗号化してコピーした後や失敗時に
descriptor を閉じます。圧縮中に名前付きの平文 spool を残しません。

7z は非空 stream ごとに選択方式で圧縮してから AES-256-CBC を使い、Copy も暗号化できます。decoder 順は
packed → AES → 選択方式です。空ファイルは従来どおり
EmptyStream として保存します。header 暗号化は名前も隠します。既定の Apple LZMA2 の圧縮単位は最大 16 MiB、
読取・暗号化・書込は 256 KiB 単位です。Apple の 8 MiB 辞書を使い、16 MiB 以下のファイルは
従来の全体圧縮と同じ圧縮 payload になります。大きいファイルだけ 16 MiB 境界で辞書を reset します。
主な作業メモリは最大 16 MiB の入力とその圧縮出力です。
この buffer の説明は codec state を含みません。Apple LZMA2 の codec 作業メモリは[設定リファレンス](options.md#並列処理と出力の待機)を参照してください。

tar（全9圧縮形式を含む）/ LHA のパスワード指定は `unsupportedOption("password")`、
パスワードなしの header 暗号化指定は `invalidOption("encryptsSevenZipHeaders")` です。

## 名前とメタデータの制限

新規追加・改名・`ArchiveRewriter` の再出力名は、全形式で NFC へ正規化します。
空の名前・絶対パス・`.` / `..`・空の成分・NUL・
UTF-8 で 65,535 byte を超える出力名・NFC 正規化後の重複・file と子の衝突は拒否します。
`\` / `:` は Windows 向けの ZIP / 7z / LHA 出力で拒否します。
tar（全9圧縮形式を含む）では両文字を名前の一部として許可します。
`ArchiveRewriter` の既存名の検査にも、出力形式の規則を適用します。

macOS metadata の保存は今後の段階です。[設計書](design.md)と
[作成](verification/2026-09-10-zip-writer.md)・
[追加](verification/2026-09-10-zip-updater.md)・
[削除・改名](verification/2026-09-10-zip-delete-rename.md)・
[暗号化](verification/2026-09-15-encryption.md)・
[大規模編集とパス境界](verification/2026-09-16-edit-review.md)・
[全形式の空書庫と横断検証](verification/2026-09-17-release-hardening.md)・
[ZIP の読取量と編集可否 probe](verification/2026-09-19-release-review.md)の検証記録を参照してください。
