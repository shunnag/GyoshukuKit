import Foundation

// tar record を順に受け取り、gzip / XZ stream または bzip2 stream の連結を出力する。
protocol TarCompressor: AnyObject {
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws
    func abandon()
}

extension TarCompressor {
    func abandon() {}
}
