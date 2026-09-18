# ZIP XZ・旧 Zstandard の編集確認（2026-09-18）

macOS 27.2（26B5086k）、Xcode 27.0（27A266a）、arm64。
KaitoKit の ZIP 20/95 読み取り追加に伴い、`ZipModernMethodEditingTests` を追加した。
GyoshukuKit の writer / updater の製品コードはこの追加では変更していない。

通常XZ・AES XZ・ZipCrypto XZ・Zstandard 20/93・AES Zstandard 20/93 の7種類を使用。
由来と独立検証の範囲は [KaitoKit の記録](../../../KaitoKit/Documentation/verification/2026-09-18-zip-methods.md)と
`KaitoKit/Tests/Fixtures/zip-modern/README.md` に記載。

- 追加後も既存 local record の全byteを保存する。
- 改名と隣接項目の削除後も既存の圧縮・暗号化payloadを保存する。
- 方式ID、CRC、暗号化、圧縮サイズを保ち、展開後の全byteも一致する。
- 新しい項目は従来のDeflateで書く。XZ/Zstandardの新規出力を提供する変更ではない。

追加2テストと全194テストが成功。skip・失敗とも0。
全件ログ: `KaitoFinder/build/ZIPMethodsVerification/gyoshuku-full.log`。
アプリ側の複数ファイル追加・改名・削除・Undo/Redoは KaitoFinder の追加検証も参照。
