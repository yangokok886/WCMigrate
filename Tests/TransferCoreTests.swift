import XCTest
import SQLite3
@testable import TransferCore

final class TransferCoreTests: XCTestCase {
    var temp: URL!
    override func setUpWithError() throws { temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }
    func source() throws -> AppInstance {
        let root = temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents/Empty"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("Documents/data.txt"))
        return AppInstance(displayName: "Fixture", bundleIdentifier: "test.fixture", root: root, origin: "test")
    }
    func testPathTraversalAndSymlinkRejected() throws {
        let instance = try source()
        for path in ["../escape", "/tmp", "Documents/../Documents", "Documents//Empty", "Documents/."] { XCTAssertThrowsError(try PathSafety.resolve(path, in: instance.root)) }
        try FileManager.default.createSymbolicLink(atPath: instance.root.appendingPathComponent("link").path, withDestinationPath: temp.path)
        XCTAssertThrowsError(try PathSafety.resolve("link", in: instance.root))
        XCTAssertThrowsError(try PathSafety.validateSelections(["Documents", "Documents/Empty"], root: instance.root))
        XCTAssertThrowsError(try PathSafety.validateSelections([], root: instance.root))
    }
    func testVerifiedBackupAndTamperDetection() async throws {
        let instance = try source(); let store = temp.appendingPathComponent("Backups"); let service = BackupService(store: store)
        let backup = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "fixture", deviceModel: "fixture", progress: { _ in })
        XCTAssertEqual(backup.files.count, 1); XCTAssertTrue(backup.directories.contains("Documents/Empty"))
        XCTAssertEqual(backup.files[0].sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try await service.verify(backup)
        let loaded = try await service.list(); XCTAssertEqual(loaded.count, 1); try await service.verify(loaded[0])
        try Data("tampered".utf8).write(to: store.appendingPathComponent(backup.id.uuidString + "/payload/Documents/data.txt"))
        do { try await service.verify(backup); XCTFail("tamper accepted") } catch { XCTAssertTrue(error is TransferError) }
        XCTAssertEqual(try String(contentsOf: instance.root.appendingPathComponent("Documents/data.txt"), encoding: .utf8), "abc")
    }
    func testUnexpectedFilesRejected() async throws {
        let instance = try source(); let store = temp.appendingPathComponent("Backups"); let service = BackupService(store: store)
        let backup = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in })
        try Data().write(to: store.appendingPathComponent(backup.id.uuidString + "/payload/extra"))
        do { try await service.verify(backup); XCTFail("extra accepted") } catch {}
    }
    func testSourceChangesFailClosed() async throws {
        let instance = try source(); let service = BackupService(store: temp.appendingPathComponent("Backups"))
        let path = instance.root.appendingPathComponent("Documents/data.txt")
        do {
            _ = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test") { update in
                if update.stage == "复查源数据一致性" { try? Data("changed".utf8).write(to: path) }
            }
            XCTFail("changed source accepted")
        } catch { XCTAssertTrue(error is TransferError) }
        let completed = try await service.list(); let incomplete = try await service.incompleteCount()
        XCTAssertEqual(completed.count, 0); XCTAssertEqual(incomplete, 1)
    }
    func testSymlinkInsideTreeBlocksBackup() async throws {
        let instance = try source(); let service = BackupService(store: temp.appendingPathComponent("Backups"))
        try FileManager.default.createSymbolicLink(atPath: instance.root.appendingPathComponent("Documents/link").path, withDestinationPath: "/tmp")
        do { _ = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in }); XCTFail("symlink accepted") } catch {}
        let completed = try await service.list(); XCTAssertTrue(completed.isEmpty)
    }
    func testBackupIntoSourceRejected() async throws {
        let instance = try source(); let service = BackupService(store: instance.root.appendingPathComponent("Backups"))
        do { _ = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in }); XCTFail("recursive backup accepted") } catch {}
    }
    func testSQLiteInspectionDoesNotAlterBackup() async throws {
        let instance = try source(); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(instance.root.appendingPathComponent("Documents/test.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sample(id INTEGER); CREATE INDEX sample_idx ON sample(id);", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = temp.appendingPathComponent("Backups"); let service = BackupService(store: store)
        let backup = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in })
        let reports = try DatabaseInspector.inspect(manifest: backup, backupDirectory: store.appendingPathComponent(backup.id.uuidString))
        XCTAssertEqual(reports.count, 1); XCTAssertEqual(reports[0].tables, ["sample"]); XCTAssertEqual(reports[0].indexCount, 1)
        XCTAssertTrue(reports[0].result.contains("通过")); try await service.verify(backup)
    }
    func testInvalidDatabaseReported() async throws {
        let instance = try source(); try Data("not a sqlite database".utf8).write(to: instance.root.appendingPathComponent("Documents/encrypted.db"))
        let store = temp.appendingPathComponent("Backups"); let service = BackupService(store: store)
        let backup = try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in })
        let reports = try DatabaseInspector.inspect(manifest: backup, backupDirectory: store.appendingPathComponent(backup.id.uuidString))
        XCTAssertTrue(reports[0].result.contains("无法解析"))
    }
    func testCancelledTaskNeverPublishes() async throws {
        let instance = try source(); let service = BackupService(store: temp.appendingPathComponent("Backups"))
        let task = Task { try await service.create(instance: instance, selections: ["Documents"], systemVersion: "test", deviceModel: "test", progress: { _ in }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel accepted") } catch { XCTAssertTrue(error is CancellationError) }
        let completed = try await service.list(); XCTAssertTrue(completed.isEmpty)
    }
}
