import XCTest
@testable import TransferCore

final class DirectMigrationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func instance(_ name: String) throws -> AppInstance {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Documents/Empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Library/Preferences/Nested"), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: path.appendingPathComponent("Documents/chat.db"))
        try Data((name + " preference").utf8).write(to: path.appendingPathComponent("Library/Preferences/plugin.plist"))
        try Data("hidden".utf8).write(to: path.appendingPathComponent("Library/Preferences/.hidden"))
        try Data("binary config".utf8).write(to: path.appendingPathComponent("Library/Preferences/Nested/options.bin"))
        return AppInstance(displayName: name, bundleIdentifier: "test." + name, root: path, origin: "fixture")
    }
    var maps: [DirectoryMapping] { [DirectoryMapping(source: "Documents", target: "Documents")] }
    func testConfigurationCopiesEntirePreferencesAndNothingElse() async throws {
        let app = try instance("source"); let location = root.appendingPathComponent("ConfigCopies")
        let preferences = PreferencesService(store: location)
        let maybeCopy = try await preferences.save(instance: app, systemVersion: "test", deviceModel: "test", progress: { _ in })
        let copy = try XCTUnwrap(maybeCopy)
        XCTAssertEqual(copy.selections, ["Library/Preferences"])
        XCTAssertEqual(copy.files.count, 3)
        XCTAssertTrue(copy.files.contains { $0.path.hasSuffix(".hidden") })
        XCTAssertTrue(copy.files.contains { $0.path.hasSuffix("Nested/options.bin") })
        XCTAssertFalse(copy.files.contains { $0.path.contains("Documents") })
        try await preferences.verify(copy)
    }
    func testDirectMigrationPreservesSourceAndDoesNotBackUpChats() async throws {
        let source = try instance("source"); let target = try instance("target")
        try Data("target-only".utf8).write(to: target.root.appendingPathComponent("Documents/obsolete.db"))
        let preferences = PreferencesService(store: root.appendingPathComponent("ConfigCopies"))
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let preview = try await service.preview(source: source, target: target, mappings: maps)
        XCTAssertEqual(preview.files, 1); XCTAssertEqual(preview.targetFiles, 2)
        let receipt = try await service.migrate(source: source, target: target, mappings: maps, preferences: preferences,
            systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified"); XCTAssertEqual(receipt.preferences.count, 0)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: source.root.appendingPathComponent("Documents/chat.db")), Data("source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Documents/obsolete.db").path))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("target preference".utf8))
        let copies = try await preferences.list()
        XCTAssertEqual(copies.count, 0)
        for copy in copies { XCTAssertEqual(copy.selections, ["Library/Preferences"]); XCTAssertFalse(copy.files.contains { $0.path.contains("chat.db") }) }
        let history = try await service.history(); XCTAssertEqual(history.first?.completedFiles, 1)
    }
    func testFullLibraryMigrationDoesNotCreateConfigurationCopy() async throws {
        let source = try instance("source"); let target = try instance("target")
        try Data(repeating: 0x51, count: 2 * 1_048_576).write(to: source.root.appendingPathComponent("Library/large-chat.bin"))
        let preferences = PreferencesService(store: root.appendingPathComponent("ConfigCopies"))
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let receipt = try await service.migrate(source: source, target: target,
            mappings: [DirectoryMapping(source: "Library", target: "Library")], preferences: preferences,
            systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Library/large-chat.bin").path))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("source preference".utf8))
        let copies = try await preferences.list()
        XCTAssertFalse(copies.contains { $0.files.contains { $0.path.contains("large-chat") } })
    }
    func testUnselectedPreferencesCannotBlockMigration() async throws {
        let source = try instance("source"); let target = try instance("target")
        try FileManager.default.createSymbolicLink(atPath: target.root.appendingPathComponent("Library/Preferences/bad-link").path, withDestinationPath: "/tmp")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let receipt = try await service.migrate(source: source, target: target, mappings: maps,
            preferences: PreferencesService(store: root.appendingPathComponent("ConfigCopies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(receipt.state, "filesVerified"); XCTAssertTrue(receipt.preferences.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ConfigCopies").path))
    }
    func testMissingPreferencesNotFakedAsBackup() async throws {
        let source = try instance("source")
        try FileManager.default.removeItem(at: source.root.appendingPathComponent("Library/Preferences"))
        let preferences = PreferencesService(store: root.appendingPathComponent("ConfigCopies"))
        let result = try await preferences.save(instance: source, systemVersion: "test", deviceModel: "test", progress: { _ in })
        XCTAssertNil(result)
        let copies = try await preferences.list(); XCTAssertTrue(copies.isEmpty)
    }
    func testNoExplicitConfirmationMeansNoWrite() async throws {
        let source = try instance("source"); let target = try instance("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        do { _ = try await service.migrate(source: source, target: target, mappings: maps,
                preferences: PreferencesService(store: root.appendingPathComponent("ConfigCopies")), systemVersion: "test", deviceModel: "test", allowOverwrite: false, progress: { _ in }); XCTFail("must reject") } catch {}
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("target".utf8))
    }
    func testChangedSourceFailsAndKeepsOriginalSource() async throws {
        let source = try instance("source"); let target = try instance("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let file = source.root.appendingPathComponent("Documents/chat.db")
        do {
            _ = try await service.migrate(source: source, target: target, mappings: maps,
                preferences: PreferencesService(store: root.appendingPathComponent("ConfigCopies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true) { progress in
                    if progress.stage == "复查所选数据" { try? Data("changed-source".utf8).write(to: file) }
                }
            XCTFail("must reject changed source")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("target".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testOverlappingContainersRejected() async throws {
        let source = try instance("source"); let target = try instance("target")
        try FileManager.default.removeItem(at: target.root.appendingPathComponent("Documents/chat.db"))
        try FileManager.default.createDirectory(at: target.root.appendingPathComponent("Documents/chat.db"), withIntermediateDirectories: false)
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        _ = try await service.preview(source: source, target: target, mappings: maps) // Type replacement is supported in 0.3.
        do { _ = try await service.preview(source: source, target: source, mappings: maps); XCTFail("same root accepted") } catch {}
    }
    func testCancellationRemovesTemporaryFileAndKeepsSource() async throws {
        let source = try instance("source"); let target = try instance("target")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let preferences = PreferencesService(store: root.appendingPathComponent("ConfigCopies"))
        let task = Task {
            try await service.migrate(source: source, target: target, mappings: maps, preferences: preferences,
                systemVersion: "test", deviceModel: "test", allowOverwrite: true) { progress in
                    if progress.stage == "系统快速复制 · 核对文件身份" || progress.stage == "复制并校验文件内容" { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        do { _ = try await task.value; XCTFail("cancelled migration completed") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: source.root.appendingPathComponent("Documents/chat.db")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("target".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: target.root.appendingPathComponent("Documents").path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".xct-") })
        let history = try await service.history(); XCTAssertEqual(history.first?.state, "cancelledPartial")
    }

    func testInvalidUnselectedLibraryIsNeverInspected() async throws {
        let source = try instance("source"); let target = try instance("target")
        try FileManager.default.removeItem(at: target.root.appendingPathComponent("Library"))
        try FileManager.default.createSymbolicLink(atPath: target.root.appendingPathComponent("Library").path, withDestinationPath: "/private/no-access")
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let plan = try await service.preview(source: source, target: target, mappings: maps)
        XCTAssertEqual(plan.files, 1)
        let result = try await service.migrate(source: source, target: target, mappings: maps, preferences: PreferencesService(store: root.appendingPathComponent("Copies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertEqual(result.state, "filesVerified"); XCTAssertTrue(result.preferences.isEmpty)
    }

    func testCopiesRemainIndependentWithCloneAndFallback() async throws {
        for cloning in [true, false] {
            let source = try instance("source-\(cloning)")
            let target = try instance("target-\(cloning)")
            let file = "Documents/chat.db"
            let data = Data(repeating: 0x5a, count: 8 * 1_048_576)
            try data.write(to: source.root.appendingPathComponent(file))
            let service = DirectMigrationService(store: root.appendingPathComponent("Tasks-\(cloning)"), preferCloning: cloning)
            let result = try await service.migrate(source: source, target: target, mappings: maps,
                preferences: PreferencesService(store: root.appendingPathComponent("Copies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
            XCTAssertEqual(result.state, "filesVerified")
            XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent(file)), data)
            let handle = try FileHandle(forWritingTo: target.root.appendingPathComponent(file))
            try handle.write(contentsOf: Data("changed target".utf8)); try handle.close()
            XCTAssertEqual(try Data(contentsOf: source.root.appendingPathComponent(file)), data)
            let targetAfter = try Data(contentsOf: target.root.appendingPathComponent(file))
            let original = try FileHandle(forWritingTo: source.root.appendingPathComponent(file))
            try original.write(contentsOf: Data("changed source".utf8)); try original.close()
            XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent(file)), targetAfter)
        }
    }
    func testManySmallFilesCopyAndResumeJournalCleanup() async throws {
        let source = try instance("small-source"), target = try instance("small-target")
        for i in 0..<2000 { try Data("file \(i)".utf8).write(to: source.root.appendingPathComponent("Documents/\(i)")) }
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let started = Date()
        let result = try await service.migrate(source: source, target: target, mappings: maps,
            preferences: PreferencesService(store: root.appendingPathComponent("Copies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        print("COPY-BENCH 2001 small files: \(Date().timeIntervalSince(started))s")
        XCTAssertEqual(result.completedFiles, 2001)
        for i in 0..<2000 { XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/\(i)")), Data("file \(i)".utf8)) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.root.appendingPathComponent("Documents").path).contains { $0.hasPrefix(".xct-") })
    }

}
