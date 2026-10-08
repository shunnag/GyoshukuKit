import Foundation

/// 境界・復旧は各試験で実際に確認する。元の規模は full-size の opt-in が使う。
enum EncoderTestCorpus {
    static let sourceMiB = TestCorpus.pseudoSource(mebibytes: 1)
    static let sourceTwentyMiB = TestCorpus.pseudoSource(mebibytes: 20)
    static let restoration = Data(sourceMiB.prefix((256 << 10) + 17))
    static let shortSource = Data(sourceMiB.prefix(128 << 10))
    static let random256KiB = TestCorpus.random(256 << 10)
    static let randomNineMiB = TestCorpus.random(9 << 20)
}
