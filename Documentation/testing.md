# 開発と検証

[README](../README.md#開発)から参照する、ビルド・テスト手順、toolchain・oracle・大容量・性能測定のガイドです。試験の配置、helper、fixture、全 `GYOSHUKU_*` 環境変数は [Tests/README.md](../Tests/README.md) を参照してください。

## ビルドと通常テスト

```sh
swift build
swift test
```

実行は macOS 26 以上・Apple Silicon、ビルドは Xcode 27 / Swift 6.4 以上です。

## Toolchain と CI

Swift 6.3.3 の `-O` は `TaskLocal<function?>.withValue` を誤コンパイルし、valueType metadata が nil になって EXC_BAD_ACCESS となることを2026-10-08に確認しました。Xcode 26 / Swift 6.3 でのビルドはサポートしません。Swift 6.4 でビルドした製品は macOS 26 の OS Swift runtime で動作します。

`Package.swift` の `swift-tools-version` は6.0のため、manifest はこのビルド要件を強制しません。古い toolchain で依存解決・ビルドできても、release での正しい動作は保証されません。

[CI](../.github/workflows/ci.yml) は Xcode 27 で debug suite と release FullSize をビルド・実行します。別 job でも同じ toolchain で debug / release をビルドし、test bundle・resource・依存 dylib / framework と Xcode 27 の xctest runner を macOS 26 に運び、再コンパイルせず同じ試験を実行します。Xcode 26 の system xctest は XCTestCore の interop symbol が不足するため使いません。実際の test failure と実行件数0を失敗にし、KaitoKit は利用側と同じ tag 参照で解決します。

FullSize の大入力 encoder / writer 試験（16件、BZip2追加後）は通常実行で opt-in です。CI では両 OS で有効にします。

```sh
GYOSHUKU_LARGE_ENCODER_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter FullSize
```

CI と toolchain の背景は[設計書](design.md#ci-と-toolchain2026-10-08)、通常・FullSize の測定は [encoder 検証](verification/2026-10-07-encoder-debug-speed.md)と[BZip2 splice 検証](verification/2026-10-08-bzip2-splice-mini-ab.md)にあります。

## 外部ツールと作業領域

新形式の試験には `/opt/homebrew/bin/lzip`・`lz4`・`brotli`・`xz` と、macOS の
gzip / bzip2 / uncompress / bsdtar も使います。テストには `/usr/bin/unzip`、`/opt/homebrew/bin/7zz`、`/usr/bin/ditto`、
`/usr/bin/tar`、`/usr/bin/python3`、`/usr/bin/cmp` が必要です。参照ツールが欠けていれば試験は失敗し、skip しません
（名前に `WhenAvailable` を含む試験だけが例外。[Tests/README.md](../Tests/README.md) の「外部ツールが無いとき」）。
テストの配置、共有 helper、`GYOSHUKU_*` 環境変数（`GYOSHUKU_SCALE_ASSERT` を含む）の一覧も同じ README にあります。通常の `swift test` に 4 GiB + 1 MiB の全バイト往復と
65,536 entry の全件検証と、改名で local offset が 4 GiB を越える再構築も含めます。
作業用 clone と展開物に約 12 GiB の空き領域を確保し、
巨大な展開物は成功後に削除します。小さい書庫と実ツールのログは
`.build/verification/` に残します。

この一覧に加え、Zstandard は `/opt/homebrew/bin/zstd`、LHA の方式試験は Lhasa と `~/.local/bin/lha-unix`（LHa for UNIX）を使います。CI の導入コマンドと optional 検査の区別は [Tests/README.md](../Tests/README.md#外部ツールが無いとき)を参照してください。製品の実行にこれらの CLI は必要ありません。

## 暗号化の検証

暗号化の oracle は KaitoKit のパスワード付き全 entry 往復、ZIP AES / 7z AES の `7zz t`、
ZipCrypto の `unzip -P ... -t` と `7zz t` です。誤パスワード・AES 認証破損・header の秘匿、
更新時の旧 record の byte 一致も検査します。300 MiB の入力を ZIP AES / 7z AES / ZipCrypto
で stream 処理し、読取中と終了後の一時ファイルも検査します。40 MiB の固定 seed テキストでは
平文・暗号 7z の往復と、Apple の全体圧縮から packed size が ±5% に収まることを検査します。
7z の5 / 16 MiBの片の圧縮 payload の byte 一致も検査します。2026-09-15 はsandboxの
module cache制限で未確認でしたが、2026-09-16には標準のSwiftPM実行環境で全件成功を確認しました。
実行件数と大規模編集の測定は[追加の検証記録](verification/2026-09-16-edit-review.md)にあります。

## 実ツールの制限

実機固有の制限も検査しています。空 ZIP は Python の出力とも一致する正当な
22 byte の書庫ですが、Apple unzip は警告、ditto は拒否します。Apple unzip の
日本語表示は崩れるため、独立した標準 ZIP の表示との比較に加え、7-Zip・ditto・
KaitoKit と生バイトで名前を検証します。Archive Utility / Windows Explorer の
直接検証は未完了です。

## 性能測定

書き込み速度の測定は独立した [Benchmarks package](../Benchmarks/README.md) を使います。
`Benchmarks/make-corpora.sh /tmp/gyoshuku-corpora` で固定 seed の入力を作成し、
`Benchmarks/run.sh /tmp/gyoshuku-corpora` で全形式の release 実行時間・peak RSS・出力サイズを測定します。
2026-09-24 の [並列 LZMA2](verification/2026-09-24-parallel-lzma2.md) と
[並列 deflate / bzip2](verification/2026-09-24-parallel-deflate-bzip2.md) の検証記録も参照してください。

writer の複数 core 化は[横断検証](verification/2026-10-07-writer-multicore.md)、最新の小規模 A/B は[統合記録](verification/2026-10-08-integrated-mini-ab.md)を参照してください。

## 圧縮 tar の大容量検証

`GYOSHUKU_LARGE_TAR_TESTS=1 swift test` は 4 GiB + 513 byte の実ファイルを tar.bz2 / tar.xz の両形式で作成し、
Python / bsdtar / 7zz と KaitoKit で内容を照合します。通常実行では、この大容量ケースだけを skip します。
6 GiB 以上の空き領域が必要です。読取側の既定 4 GiB 上限は変更せず、このテストでは明示的に上限を上げます。
KaitoFinder の `Tools/benchmark_tar_memory.py` は最適化した実 writer のピークRSSと内容を検査します。

大容量の手順と測定条件は[検証記録](verification/2026-09-18-compressed-tar.md)にあります。
