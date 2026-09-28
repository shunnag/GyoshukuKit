import Foundation

/// 書き込み失敗。失敗した writer は破棄する。ZIP の未完成出力は呼出側で削除する。
public enum WriterError: Error, Sendable, Equatable {
    case invalidOption(String)
    case unsupportedOption(String)
    case invalidPath(String)
    case duplicatePath(String)
    case unsupportedFileType(String)
    case sourceChanged(String)
    case invalidDate
    case invalidState
    case io(operation: String, code: Int32)
    case compression(Int32)
    case sizeOverflow
}
