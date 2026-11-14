import XCTest
import Darwin
@testable import TransferCore
final class RecoveryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func app(_ name: String) throws -> AppInstance {
        let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        return AppInstance(displayName: name, bundleIdentifier: "test." + name, root: url, origin: "fixture")
    }
    // LaunchServices reconstructs existing directory URLs with a trailing slash after relaunch.
    func rediscovered(_ app: AppInstance) -> AppInstance {
        var result = app
        result.root = URL(fileURLWithPath: app.root.path, isDirectory: true)
        XCTAssertEqual(result.root.path, app.root.path)
        return result
    }
    func put(_ a: AppInstance, _ path: String, _ text: String) throws { let p = a.root.appendingPathComponent(path); try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: p) }
    func testInterruptedCopyResumesAndRejectsExternalTargetChange() async throws {
        for mode in [TransferMode.replace, .merge] {
            let a = try app("a-" + mode.rawValue), b = try app("b-" + mode.rawValue)
            try put(a, "Documents/a", "first"); try put(a, "Documents/b", "second"); try put(b, "Documents/old", "preserve-or-delete")
            let location = root.appendingPathComponent("Tasks-" + mode.rawValue)
            let service = DirectMigrationService(store: location), prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
            let work = Task {
                try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], mode: mode, preferences: prefs, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { p in
                    if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { _ = try await work.value; XCTFail("expected cancellation") } catch is CancellationError {}
            let history = try await service.history(); let task = try XCTUnwrap(history.first)
            // Recreate the service to prove that recovery depends on disk state, not actor memory.
            let fresh = DirectMigrationService(store: location)
            let resumed = try await fresh.resume(task.id, source: rediscovered(a), target: rediscovered(b), preferences: prefs, progress: { _ in })
            XCTAssertEqual(resumed.state, "filesVerified")
            XCTAssertEqual(try String(contentsOf: b.root.appendingPathComponent("Documents/b")), "second")
            XCTAssertEqual(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("Documents/old").path), mode == .merge)
            do { _ = try await fresh.resume(task.id, source: a, target: b, preferences: prefs, progress: { _ in }); XCTFail("completed task resumed") } catch {}
        }
    }
    func testResumeRefusesSourceOrUnrelatedTargetMutation() async throws {
        for mutateSource in [false, true] {
            let a = try app("source-\(mutateSource)"), b = try app("target-\(mutateSource)")
            try put(a, "Documents/a", "first"); try put(a, "Documents/b", "second")
            let location = root.appendingPathComponent("Tasks-\(mutateSource)"), prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
            let service = DirectMigrationService(store: location)
            let work = Task {
                try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], preferences: prefs, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { p in
                    if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            _ = try? await work.value
            let history = try await service.history(), id = try XCTUnwrap(history.first?.id)
            try put(mutateSource ? a : b, "Documents/a", "external modification")
            do { _ = try await DirectMigrationService(store: location).resume(id, source: a, target: b, preferences: prefs, progress: { _ in }); XCTFail("changed data accepted") } catch {}
        }
    }

    func testHistorySkipsTruncatedReceiptAndKeepsValidTask() async throws {
        let store = root.appendingPathComponent("Tasks")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(to: store.appendingPathComponent("broken.json"))
        let receipt = MigrationReceipt(id: UUID(), created: Date(), sourceName: "a", targetName: "b",
            sourceBundleID: "test.a", targetBundleID: "test.b", state: "cancelledPartial", files: 0,
            bytes: 0, completedFiles: 0, completedBytes: 0, preferences: [], preferenceAbsences: [], mappings: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: store.appendingPathComponent(receipt.id.uuidString + ".json"))

        let history = try await DirectMigrationService(store: store).history()
        XCTAssertEqual(history.map(\.id), [receipt.id])
    }

    func testDeepTreeStopsWithDiagnosticInsteadOfUnboundedRecursion() async throws {
        let source = try app("deep-source"), target = try app("deep-target")
        var current = source.root.appendingPathComponent("Documents")
        // Keep each component short so the fixture reaches the migration depth
        // guard before the host filesystem rejects the path itself.
        for _ in 0..<129 {
            current = current.appendingPathComponent("d")
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: current.appendingPathComponent("file"))
        do {
            _ = try await DirectMigrationService(store: root.appendingPathComponent("Tasks"))
                .preview(source: source, target: target,
                         mappings: [DirectoryMapping(source: "Documents", target: "Documents")],
                         mode: .replace, detailed: true)
            XCTFail("deep tree should be rejected before exhausting the call stack")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("128"))
        }
    }
    func testExchangeResumeNeverSwapsCompletedPairAgain() async throws {
        let a = try app("source"), b = try app("target")
        try put(a, "one", "source-one"); try put(a, "two", "source-two")
        try put(b, "one", "target-one"); try put(b, "two", "target-two")
        let location = root.appendingPathComponent("Tasks"), prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
        let service = DirectMigrationService(store: location)
        let work = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "one", target: "one"), DirectoryMapping(source: "two", target: "two")], mode: .exchange, preferences: prefs, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { p in
                if p.stage == "双向转换完成" && p.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = try? await work.value
        let history = try await service.history(), id = try XCTUnwrap(history.first?.id)
        // Emulate crash after kernel swap but before the plan completion checkpoint.
        let planURL = location.appendingPathComponent("Plans/" + id.uuidString + ".json")
        var plan = try JSONSerialization.jsonObject(with: Data(contentsOf: planURL)) as! [String: Any]
        plan["completed"] = [String: Any]()
        try JSONSerialization.data(withJSONObject: plan).write(to: planURL, options: .atomic)
        let result = try await DirectMigrationService(store: location).resume(id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(result.state, "filesVerified")
        XCTAssertEqual(try String(contentsOf: a.root.appendingPathComponent("one")), "target-one")
        XCTAssertEqual(try String(contentsOf: b.root.appendingPathComponent("one")), "source-one")
        XCTAssertEqual(try String(contentsOf: a.root.appendingPathComponent("two")), "target-two")
    }
    func testPlistOnlyRecursesAndPreservesFolders() async throws {
        let a = try app("source")
        try put(a, "Library/Preferences/plugin.plist", "one")
        try put(a, "Library/Preferences/Nested/.hidden.PLIST", "two")
        try put(a, "Library/Preferences/Nested/options.json", "ignored")
        try put(a, "Library/Preferences/Empty/data.bin", "ignored")
        let service = PreferencesService(store: root.appendingPathComponent("Copies"))
        let maybe = try await service.save(instance: a, systemVersion: "test", deviceModel: "test", plistOnly: true, progress: { _ in })
        let result = try XCTUnwrap(maybe)
        XCTAssertEqual(result.files.map(\.path), ["Library/Preferences/Nested/.hidden.PLIST", "Library/Preferences/plugin.plist"])
        XCTAssertEqual(result.directories, ["Library/Preferences", "Library/Preferences/Nested"])
        XCTAssertEqual(result.plistOnly, true)
        try await service.verify(result)
    }
    func testBackupResumeSkipsVerifiedFilesAndRejectsChangedSource() async throws {
        let a = try app("source")
        try put(a, "Library/Preferences/a.plist", "first")
        try put(a, "Library/Preferences/b.plist", "second")
        let location = root.appendingPathComponent("Copies")
        let service = PreferencesService(store: location)
        let work = Task {
            try await service.save(instance: a, systemVersion: "test", deviceModel: "test", plistOnly: true) { p in
                if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await work.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let fresh = PreferencesService(store: location), pending = try await fresh.pendingBackups()
        XCTAssertEqual(pending.count, 1)
        let resumed = try await fresh.resumeBackup(pending[0].id, instance: rediscovered(a), progress: { _ in })
        XCTAssertEqual(resumed.files.count, 2); XCTAssertEqual(resumed.plistOnly, true)
        try await fresh.verify(resumed)
        let remaining = try await fresh.pendingBackups(); XCTAssertTrue(remaining.isEmpty)
    }
    func testDeletingPendingBackupRemovesPartialDirectory() async throws {
        let a = try app("pending-delete")
        try put(a, "Library/Preferences/plugin.plist", "pending")
        let location = root.appendingPathComponent("Copies-delete")
        let service = PreferencesService(store: location)
        let work = Task {
            try await service.save(instance: a, systemVersion: "test", deviceModel: "test", plistOnly: true) { p in
                if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await work.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let pending = try await service.pendingBackups()
        let id = try XCTUnwrap(pending.first?.id)
        let partial = location.appendingPathComponent(id.uuidString + ".partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        try await service.delete(id)
        let remaining = try await service.pendingBackups()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
    func testExchangeMissingTargetRecoversMoveBeforeJournal() async throws {
        let a = try app("source"), b = try app("target")
        try put(a, "one", "one"); try put(a, "two", "two")
        let location = root.appendingPathComponent("Tasks"), prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
        let service = DirectMigrationService(store: location)
        let work = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "one", target: "one"), DirectoryMapping(source: "two", target: "two")], mode: .exchange, preferences: prefs, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { p in
                if p.stage == "双向转换完成" && p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = try? await work.value
        let history = try await service.history(), id = try XCTUnwrap(history.first?.id)
        let result = try await DirectMigrationService(store: location).resume(id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(result.state, "filesVerified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("one").path))
        XCTAssertEqual(try String(contentsOf: b.root.appendingPathComponent("two")), "two")
    }

    func testBackupResumeRefusesChangedSource() async throws {
        let a = try app("source"); try put(a, "Library/Preferences/a.plist", "one"); try put(a, "Library/Preferences/b.plist", "two")
        let service = PreferencesService(store: root.appendingPathComponent("Copies"))
        let work = Task {
            try await service.save(instance: a, systemVersion: "test", deviceModel: "test") { p in
                if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = try? await work.value
        let pending = try await service.pendingBackups()
        try put(a, "Library/Preferences/b.plist", "changed")
        do { _ = try await service.resumeBackup(pending[0].id, instance: a, progress: { _ in }); XCTFail("changed source resumed") } catch {}
        let copies = try await service.list(); XCTAssertTrue(copies.isEmpty)
    }
    func testResumeRemovesOnlyJournaledCrashTemporaryFile() async throws {
        let a = try app("source"), b = try app("target")
        try put(a, "Documents/a", "one"); try put(a, "Documents/b", "two")
        let location = root.appendingPathComponent("Tasks"), prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
        let service = DirectMigrationService(store: location)
        let work = Task {
            try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")], preferences: prefs, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { p in
                if p.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = try? await work.value
        let history = try await service.history(), id = try XCTUnwrap(history.first?.id)
        let temporary = "Documents/.xct-" + id.uuidString + "-crash.partial"
        try put(b, temporary, "partially written bytes")
        let url = location.appendingPathComponent("Plans/" + id.uuidString + ".pending")
        try JSONEncoder().encode(temporary).write(to: url, options: .atomic)
        let result = try await DirectMigrationService(store: location).resume(id, source: a, target: b, preferences: prefs, progress: { _ in })
        XCTAssertEqual(result.state, "filesVerified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.root.appendingPathComponent(temporary).path))
    }

}
