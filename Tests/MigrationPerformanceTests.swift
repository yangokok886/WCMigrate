import XCTest
@testable import TransferCore

final class MigrationPerformanceTests: XCTestCase {
    final class AccessCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        func reset() { lock.lock(); count = 0; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    func testQuickConfirmationDoesNotWalkChildrenButExecutionRejectsUnsafeChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try FileManager.default.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(atPath: a.appendingPathComponent("Documents/unsafe").path, withDestinationPath: b.path)
        let source = AppInstance(displayName: "a", bundleIdentifier: "test.a", root: a, origin: "fixture")
        let target = AppInstance(displayName: "b", bundleIdentifier: "test.b", root: b, origin: "fixture")
        let service = DirectMigrationService(store: root.appendingPathComponent("tasks"))
        let mappings = [DirectoryMapping(source: "Documents", target: "Documents")]
        let preview = try await service.preview(source: source, target: target, mappings: mappings, detailed: false)
        XCTAssertEqual(preview.inventoryComplete, false)
        do {
            _ = try await service.migrate(source: source, target: target, mappings: mappings,
                preferences: PreferencesService(store: root.appendingPathComponent("configs")),
                systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
            XCTFail("Unsafe child must be rejected before writing")
        } catch { XCTAssertTrue(error is PathDiagnostic) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.appendingPathComponent("Documents").path).isEmpty)
    }
    func testInventoryAccessProbesDoNotScaleWithEveryFile() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try fm.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true) }
        for index in 0..<2_000 { try Data([0x41]).write(to: a.appendingPathComponent("Documents/\(index).bin")) }
        let source = AppInstance(displayName: "a", bundleIdentifier: "test.a", root: a, origin: "fixture")
        let target = AppInstance(displayName: "b", bundleIdentifier: "test.b", root: b, origin: "fixture")
        let count = AccessCounter()
        let service = DirectMigrationService(store: root.appendingPathComponent("tasks"), prepareAccess: { _ in count.record() })
        let mappings = [DirectoryMapping(source: "Documents", target: "Documents")]
        var started = Date()
        let quick = try await service.preview(source: source, target: target, mappings: mappings, detailed: false)
        let quickElapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(quick.inventoryComplete, false)
        XCTAssertLessThan(count.value, 50)
        count.reset(); started = Date()
        let full = try await service.preview(source: source, target: target, mappings: mappings)
        let fullElapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(full.files, 2_000); XCTAssertEqual(full.bytes, 2_000)
        XCTAssertLessThan(count.value, 50, "Already accessible children must not need per-file access probes")
        print("SCAN-BENCH 2000 small files: quick=\(quickElapsed)s inventory=\(fullElapsed)s prepareAccess=\(count.value)")
        // Older saved plans omit this key and remain decodable.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        json.removeValue(forKey: "inventoryComplete")
        let old = try JSONDecoder().decode(MigrationSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.inventoryComplete); XCTAssertEqual(old.files, 2_000)
    }
}

extension MigrationPerformanceTests {
    func testLargeReplaceMoveUsesRootRenameAndPreservesAllEntries() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let sourceDir = a.appendingPathComponent("Documents"), targetDir = b.appendingPathComponent("Documents")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        for index in 0..<10_000 {
            try Data([UInt8(index & 0xff)]).write(to: sourceDir.appendingPathComponent("item-\(index).bin"))
        }
        try Data("old".utf8).write(to: targetDir.appendingPathComponent("old.bin"))
        let source = AppInstance(displayName: "a", bundleIdentifier: "test.a", root: a, origin: "fixture")
        let target = AppInstance(displayName: "b", bundleIdentifier: "test.b", root: b, origin: "fixture")
        let service = DirectMigrationService(store: root.appendingPathComponent("tasks"))
        let receipt = try await service.migrate(source: source, target: target,
            mappings: [DirectoryMapping(source: "Documents", target: "Documents")], mode: .replace,
            keepSource: false, preferences: PreferencesService(store: root.appendingPathComponent("configs")),
            systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified")
        XCTAssertFalse(fm.fileExists(atPath: sourceDir.path))
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent("old.bin").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: targetDir.path).count, 10_000)
    }
}

extension MigrationPerformanceTests {
    private final class PendingJournalObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Data?
        private var installations = 0
        let path: URL
        init(path: URL) { self.path = path }
        func observe() {
            lock.lock(); defer { lock.unlock() }
            guard let data = try? Data(contentsOf: path), data != last else { return }
            last = data
            if (try? JSONDecoder().decode(String?.self, from: data)) != nil { installations += 1 }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return installations }
    }

    func testCopyReusesPendingJournalWithinDirectory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try fm.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true) }
        for i in 0..<40 { try Data([UInt8(i)]).write(to: a.appendingPathComponent("Documents/\(i).bin")) }
        let taskID = UUID(), store = root.appendingPathComponent("tasks")
        let observer = PendingJournalObserver(path: store.appendingPathComponent("Plans/\(taskID.uuidString).pending"))
        let service = DirectMigrationService(store: store, preferCloning: false, prepareAccess: { _ in observer.observe() })
        let receipt = try await service.migrate(
            source: AppInstance(displayName: "a", bundleIdentifier: "test.a", root: a, origin: "fixture"),
            target: AppInstance(displayName: "b", bundleIdentifier: "test.b", root: b, origin: "fixture"),
            mappings: [DirectoryMapping(source: "Documents", target: "Documents")], keepSource: true,
            preferences: PreferencesService(store: root.appendingPathComponent("configs")),
            systemVersion: "test", deviceModel: "test", allowOverwrite: true, taskID: taskID, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified")
        XCTAssertEqual(observer.count, 1, "Fresh files in one directory must share a durable pending path")
        for i in 0..<40 {
            XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("Documents/\(i).bin")), Data([UInt8(i)]))
            XCTAssertTrue(fm.fileExists(atPath: a.appendingPathComponent("Documents/\(i).bin").path))
        }
    }

    func testBufferedCopyPreservesMultiChunkFileAndTail() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try fm.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true) }
        // Includes repeated full 1 MiB reads, a partial final read, and a zero-byte file.
        let data = Data((0..<(17 * 1_048_576 + 137)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: a.appendingPathComponent("Documents/large.img"))
        try Data().write(to: a.appendingPathComponent("Documents/empty"))
        let service = DirectMigrationService(store: root.appendingPathComponent("tasks"), preferCloning: false)
        let receipt = try await service.migrate(
            source: AppInstance(displayName: "a", bundleIdentifier: "test.a", root: a, origin: "fixture"),
            target: AppInstance(displayName: "b", bundleIdentifier: "test.b", root: b, origin: "fixture"),
            mappings: [DirectoryMapping(source: "Documents", target: "Documents")], keepSource: true,
            preferences: PreferencesService(store: root.appendingPathComponent("configs")),
            systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.completedBytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("Documents/large.img")), data)
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("Documents/empty")).count, 0)
    }
}
