import Foundation
import Darwin
import Synchronization
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

// 形式ごとの三つの class が同じ `CompressedTarDeterminism.run`（Support/CompressedTarTestSupport.swift）を呼ぶ。
// `--filter CompressedTarSpliceXZTests` のように一形式だけを選んで走らせられる。
final class CompressedTarSpliceGzipTests: XCTestCase {
    func testDeterminismAndFullEncodeBytes() throws { try CompressedTarDeterminism.run(.tarGzip) }
}

final class CompressedTarSpliceBzip2Tests: XCTestCase {
    func testDeterminismAndFullEncodeBytes() throws { try CompressedTarDeterminism.run(.tarBzip2) }
}

final class CompressedTarSpliceXZTests: XCTestCase {
    func testDeterminismAndFullEncodeBytes() throws { try CompressedTarDeterminism.run(.tarXZ) }
}
