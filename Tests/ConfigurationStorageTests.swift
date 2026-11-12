import XCTest
@testable import TransferCore

final class ConfigurationStorageTests: XCTestCase {
    func testMovesBackupsAndPartialTasksTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Support/PreferencesCopies"), new = root.appendingPathComponent("Documents/插件配置备份")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("task.partial"), withIntermediateDirectories: true)
        let payload = Data("preserve manifest".utf8)
        try payload.write(to: old.appendingPathComponent("task.partial/plan.json"))
        XCTAssertEqual(try ConfigurationStorage.prepare(legacy: old, destination: new), new)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("task.partial/plan.json")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try ConfigurationStorage.prepare(legacy: old, destination: new), new)
    }
    func testConflictLeavesBothStoresIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("Documents/backup")
        for dir in [old, new] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(dir.lastPathComponent.utf8).write(to: dir.appendingPathComponent("file"))
        }
        XCTAssertThrowsError(try ConfigurationStorage.prepare(legacy: old, destination: new))
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("file")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("file")), Data("backup".utf8))
    }
    func testEmptyDestinationAndFreshInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("Documents/backup")
        _ = try ConfigurationStorage.prepare(legacy: old, destination: new)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("copy".utf8).write(to: old.appendingPathComponent("copy"))
        _ = try ConfigurationStorage.prepare(legacy: old, destination: new)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("copy")), Data("copy".utf8))
    }
}
