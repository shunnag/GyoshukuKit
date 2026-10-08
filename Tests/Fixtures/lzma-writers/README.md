# LZMA レベル接続前の既定出力

`feature/write-methods-levels` の自前 LZMA encoder 接続前に Apple COMPRESSION_LZMA で生成した
tar.xz / 7z LZMA2 / ZIP XZ (95)。`LZMAWriterDefaultOutputTests` が固定日時、192 KiB text、
17 MiB の同一 byte、空 entry を書き、並列数1・4の両方を比較する。再生成しない。
ZIP の DOS timestamp は JST に固定する。GyoshukuKit commit `4d34e76` の試験データ（MIT）。

| file | SHA-256 |
|---|---|
| `default.7z` | `f16e2a16e9c3ff6b2a6378030c64f1e3020962fdb95dcd312d2a64f1cd2ecb58` |
| `default.tar.xz` | `f93bcbbf8ac19980083c7dfbaa57c0491628e79a337e09bd258cc9a9e937d147` |
| `default.zip` | `6bcf7a5e00290419ba46c3afa322efd5210a761dc407da93f6ef64cacaeb091a` |
