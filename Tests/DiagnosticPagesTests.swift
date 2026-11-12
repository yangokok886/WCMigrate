import XCTest
@testable import TransferCore
final class DiagnosticPagesTests: XCTestCase {
    func testLargeUnicodeReportPreservesEveryCharacter() {
        let report = String(repeating: "路径/插件/👍🏽.json errno=1\n", count: 3000) + "END"
        let pages = DiagnosticPages.split(report)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 6000 })
        XCTAssertEqual(pages.joined(), report)
        XCTAssertTrue(pages.last!.hasSuffix("END"))
    }
    func testEmptyAndExactBoundary() {
        XCTAssertEqual(DiagnosticPages.split(""), ["暂无诊断内容"])
        XCTAssertEqual(DiagnosticPages.split("abcdef", limit: 3), ["abc", "def"])
    }
}
