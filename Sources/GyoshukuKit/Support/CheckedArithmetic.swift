import Foundation

// byte 位置・長さの加算は溢れを WriterError.sizeOverflow にする。ZIP / tar / 7z / LHA の全経路で共有する。
func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw WriterError.sizeOverflow }
    return result.partialValue
}
