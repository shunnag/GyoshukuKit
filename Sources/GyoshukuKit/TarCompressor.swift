import Foundation

/// Receives successive tar records and emits one complete compressed stream.
/// A failed call invalidates the owning ArchiveWriter; no partial output is published.
protocol TarCompressor: AnyObject {
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws
}
