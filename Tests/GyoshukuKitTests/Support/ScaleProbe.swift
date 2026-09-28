import Foundation
import Darwin
import XCTest

/// opt-in の計測（`*ScaleProbeTests` など）が共有する、負荷の待ち・行の出力・時間の閾値。
///
/// 閾値の方針は一つ: 計測の行は閾値の成否に関わらず必ず出し、閾値を超えたことを失敗にするのは
/// `GYOSHUKU_SCALE_ASSERT=1`（または probe ごとの古い鍵。例: xz packing の `GYOSHUKU_P14_ASSERT=1`）のときだけ。
/// 閾値は release build（`-c release -Xswiftc -enable-testing`）を静かな機械で走らせる前提の値。
enum ScaleProbe {
    /// 閾値を assert するか。`GYOSHUKU_SCALE_ASSERT=1` か、`alias`（probe ごとの古い鍵）が 1 のとき。
    static func assertsThresholds(alias: String? = nil) -> Bool {
        OptInGate.isOn("GYOSHUKU_SCALE_ASSERT") || alias.map(OptInGate.isOn) == true
    }

    /// 1 分平均の load が `limit` 以下になるまで 1 秒ずつ待つ。待てる秒数 `budget` は同じ試験の計測全体で共有し、
    /// 使い切った後は待たずに測る（下がらない負荷はそのまま行に記録し、閾値は変えない）。
    /// - Returns: 測る直前の load（1・5・15 分）と、この呼び出しで待った秒数。
    static func waitForLoad(below limit: Double, budget: inout Int) throws -> (load: [Double], waited: Int) {
        var load = [Double](repeating: 0, count: 3), waited = 0
        _ = getloadavg(&load, 3)
        while load[0] > limit, budget > 0 {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 1)
            waited += 1; budget -= 1
            _ = getloadavg(&load, 3)
        }
        return (load, waited)
    }

    /// 計測の一行を `<tag>\t<column>\t…` の TSV として stderr へ出す（`TestSupport.report` と同じ出力先）。
    static func report(tag: String, columns: [String]) {
        TestSupport.report(([tag] + columns).joined(separator: "\t"))
    }

    /// `measured` が `limit` 以下なら true を返す。`assert` が真のとき（既定は `assertsThresholds()`）だけ超過を失敗にする。
    @discardableResult
    static func threshold(_ measured: Double, limit: Double, assert: Bool = assertsThresholds(),
                          _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if assert { XCTAssertLessThanOrEqual(measured, limit, message(), file: file, line: line) }
        return measured <= limit
    }
}
