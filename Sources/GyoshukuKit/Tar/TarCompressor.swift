import Foundation

// tar record を順に受け取り、gzip / XZ stream または bzip2 stream の連結を出力する。
protocol TarCompressor: AnyObject {
    var pendingInputBytes: UInt64 { get }
    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws
    func beginMember(headerLength: UInt64, bodyLength: UInt64)
    func beginEndOfArchive()
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws
    func abandon()
}

extension TarCompressor {
    func beginMember(headerLength: UInt64, bodyLength: UInt64) {}
    func beginEndOfArchive() {}
    func abandon() {}
}
