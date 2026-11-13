import XCTest
import Darwin
@testable import TransferCore

final class MoveMigrationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func app(_ name: String) throws -> AppInstance {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Documents/Nested"), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: url.appendingPathComponent("Documents/a"))
        try Data((name + " nested").utf8).write(to: url.appendingPathComponent("Documents/Nested/b"))
        return AppInstance(displayName: name, bundleIdentifier: name, root: url, origin: "test")
    }
    func inode(_ path: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        return (attrs[.systemFileNumber] as! NSNumber).uint64Value
    }
    func perform(_ mode: TransferMode, missing: Bool = false) async throws {
        let a = try app("source"), b = try app("target")
        let id = try inode(a.root.appendingPathComponent("Documents/a"))
        if missing { try FileManager.default.removeItem(at: b.root.appendingPathComponent("Documents")) }
        else { try Data("unique".utf8).write(to: b.root.appendingPathComponent("Documents/unique")) }
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let receipt = try await service.migrate(source: a, target: b,
            mappings: [DirectoryMapping(source: "Documents", target: "Documents")], mode: mode, keepSource: false,
            preferences: PreferencesService(store: root.appendingPathComponent("Prefs")), systemVersion: "", deviceModel: "", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified")
        XCTAssertEqual(receipt.keepSource, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("Documents").path))
        XCTAssertEqual(try inode(b.root.appendingPathComponent("Documents/a")), id, "Must rename, not copy then delete")
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/Nested/b")), Data("source nested".utf8))
        XCTAssertEqual(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("Documents/unique").path), mode == .merge && !missing)
    }
    func testMoveReplace() async throws { try await perform(.replace) }
    func testMoveMerge() async throws { try await perform(.merge) }
    func testMoveToMissingTarget() async throws { try await perform(.replace, missing: true) }
    func testMoveMergeFileDirectoryConflicts() async throws {
        let a = try app("source"), b = try app("target")
        try FileManager.default.removeItem(at: b.root.appendingPathComponent("Documents/a"))
        try FileManager.default.createDirectory(at: b.root.appendingPathComponent("Documents/a/Old"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: b.root.appendingPathComponent("Documents/a/Old/file"))
        try FileManager.default.removeItem(at: b.root.appendingPathComponent("Documents/Nested"))
        try Data("old file".utf8).write(to: b.root.appendingPathComponent("Documents/Nested"))
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        _ = try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], mode: .merge, keepSource: false,
            preferences: PreferencesService(store: root.appendingPathComponent("Prefs")), systemVersion: "", deviceModel: "", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/a")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/Nested/b")), Data("source nested".utf8))
    }
    func testResumeAfterKernelSwapBeforeCleanup() async throws {
        let a = try app("source"), b = try app("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let prefs = PreferencesService(store: root.appendingPathComponent("Prefs"))
        let task = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], keepSource: false,
                preferences: prefs, systemVersion: "", deviceModel: "", allowOverwrite: true,
                diagnostic: { text in if text.hasPrefix("直接移动已提交") { withUnsafeCurrentTask { $0?.cancel() } } }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let records = try await service.history()
        let receipt = try XCTUnwrap(records.first)
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/a")), Data("source".utf8))
        let done = try await service.resume(receipt.id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(done.state, "filesVerified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("Documents").path))
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/a")), Data("source".utf8))
    }
    func testMergeResumeAfterFirstMove() async throws {
        let a = try app("source"), b = try app("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let prefs = PreferencesService(store: root.appendingPathComponent("Prefs"))
        let task = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], mode: .merge, keepSource: false,
                preferences: prefs, systemVersion: "", deviceModel: "", allowOverwrite: true,
                progress: { p in if p.stage == "直接移动文件" { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let records = try await service.history()
        let done = try await service.resume(XCTUnwrap(records.first).id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(done.state, "filesVerified")
    }
    func testResumeRejectsUnexpectedOldTargetContent() async throws {
        let a = try app("source"), b = try app("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let prefs = PreferencesService(store: root.appendingPathComponent("Prefs"))
        let task = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], keepSource: false,
                preferences: prefs, systemVersion: "", deviceModel: "", allowOverwrite: true,
                diagnostic: { text in if text.hasPrefix("直接移动已提交") { withUnsafeCurrentTask { $0?.cancel() } } }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let unexpected = a.root.appendingPathComponent("Documents/new-content")
        try Data("must survive".utf8).write(to: unexpected)
        let records = try await service.history()
        do {
            _ = try await service.resume(XCTUnwrap(records.first).id, source: a, target: b, preferences: prefs, progress: { _ in })
            XCTFail("Unexpected data must block cleanup")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("must survive".utf8))
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Documents/a")), Data("source".utf8))
    }
    func testResumeWhenSourceAlreadyMovedToAbsentTarget() async throws {
        let a = try app("source"), b = try app("target")
        try FileManager.default.removeItem(at: b.root.appendingPathComponent("Documents"))
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let prefs = PreferencesService(store: root.appendingPathComponent("Prefs"))
        let task = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], keepSource: false,
                preferences: prefs, systemVersion: "", deviceModel: "", allowOverwrite: true,
                diagnostic: { text in if text.hasPrefix("直接移动已提交") { withUnsafeCurrentTask { $0?.cancel() } } }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let records = try await service.history()
        let done = try await service.resume(XCTUnwrap(records.first).id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(done.state, "filesVerified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("Documents").path))
    }

}
