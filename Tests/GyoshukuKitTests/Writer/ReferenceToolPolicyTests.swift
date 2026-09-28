public import XCTest

final class ReferenceToolPolicyTests: XCTestCase {
    private let missingTool = "/nonexistent/tool"

    func testRequireMissingToolFailsAndThrows() throws {
        try XCTExpectFailure("必須の外部ツールが無ければ失敗する") {
            XCTAssertThrowsError(try ReferenceTool.require([missingTool])) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileNoSuchFile)
            }
        } issueMatcher: {
            $0.type == .assertionFailure
                && $0.compactDescription.contains("Required reference tool missing: \(self.missingTool)")
        }
    }

    func testOptionalMissingToolThrowsSkip() {
        XCTAssertThrowsError(try ReferenceTool.optional([missingTool])) {
            XCTAssertTrue($0 is XCTSkip)
        }
    }
}
