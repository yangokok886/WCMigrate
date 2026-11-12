import XCTest
@testable import TransferCore
final class OperationEstimateTests: XCTestCase {
    func testTimeUsesChineseUnits() {
        XCTAssertEqual(OperationEstimate.timeText(13.2), "14秒")
        XCTAssertEqual(OperationEstimate.timeText(125), "2分5秒")
        XCTAssertEqual(OperationEstimate.timeText(3660), "1小时1分")
    }
    func testEstimateOnlyAfterActualProgressAndNeverInventsScanningPercent() {
        var tracker = OperationEstimate(); let start = Date(timeIntervalSince1970: 1_000)
        tracker.update(BackupProgress("copy", 0, 1, 0, fraction: 0.1), now: start)
        XCTAssertNil(tracker.remaining)
        tracker.update(BackupProgress("copy", 0, 1, 200, fraction: 0.3), now: start.addingTimeInterval(4))
        XCTAssertEqual(tracker.remaining!, 14, accuracy: 0.01)
        tracker.update(BackupProgress("scan", 0, 0, 0), now: start.addingTimeInterval(5))
        XCTAssertNil(tracker.fraction); XCTAssertNil(tracker.remaining)
        tracker.update(BackupProgress("done", 1, 1, 300, fraction: 1))
        XCTAssertEqual(tracker.fraction, 1); XCTAssertNil(tracker.remaining)
    }
}
