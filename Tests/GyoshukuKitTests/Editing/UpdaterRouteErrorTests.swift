import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class UpdaterRouteErrorTests: XCTestCase {
    func testAliasEqualityAndBothCatchPatterns() {
        let old = TarUpdaterError.requiresRewrite(reason: "reason")
        XCTAssertEqual(old, UpdaterRouteError.requiresRewrite(reason: "reason"))
        do { throw old } catch UpdaterRouteError.requiresRewrite(let reason) { XCTAssertEqual(reason, "reason") } catch { XCTFail("\(error)") }
        do { throw UpdaterRouteError.outputVerificationFailed(reason: "V5") }
        catch TarUpdaterError.outputVerificationFailed(let reason) { XCTAssertEqual(reason, "V5") } catch { XCTFail("\(error)") }
    }
}
