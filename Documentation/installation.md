# 導入と依存解決

[README](../README.md)から導入を始め、使い方は[使用ガイド](usage.md)を参照してください。

## Swift Package Manager

GyoshukuKit 0.8.0 を Swift Package Manager で追加します。

```swift
.package(url: "https://github.com/shunnag/GyoshukuKit.git", .upToNextMinor(from: "0.8.0"))
```

利用側の target の dependencies に `.product(name: "GyoshukuKit", package: "GyoshukuKit")` を追加してください。

## KaitoKit の依存解決

[KaitoKit](https://github.com/shunnag/KaitoKit) 0.12.x（0.12.0 以上、0.13.0 未満）。更新時の読取と往復検証に使用。
`@_spi` は SemVer の保証外で、`public import KaitoKit` により公開 API にも KaitoKit の型を含むため、`.upToNextMinor(from: "0.12.0")` に限定する。
`Package.swift` は隣に `../KaitoKit` の checkout があればその path 依存（開発用）、なければ tag 参照を選ぶ。
SwiftPM / Xcode の `checkouts/` 配下（依存として取得された場合）では常に tag 参照。
切り替わった後は `swift package purge-cache`（Xcode は File → Packages → Reset Package Caches）で manifest を再評価させます（`.build` の削除では manifest cache が残ります）。

この選択は [Package.swift](../Package.swift) に実装しています。path 依存を使う開発者も、KaitoKit 0.12.x の checkout を用意してください。

## 0.8.0 のリリースの関係

リリース順は KaitoKit 0.12.x → GyoshukuKit 0.8.0 → KaitoFinder 0.6.0 です。
KaitoKit は既存の0.12.xを使い、製品ソースが v0.12.1 以降変わっていないため今回は再リリースしません。

## システムライブラリ

圧縮・暗号化には system zlib / libbz2、Apple Compression、CommonCrypto / CryptoKit / Security を使います。システムの libarchive はリンクしません。libbz2 を Swift から読み込むための最小の system-library header shim は [CGyoshukuBzip2](../Sources/CGyoshukuBzip2/shim.h) にあります。独自 encoder の本体は Swift です。
