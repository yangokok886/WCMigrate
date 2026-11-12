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
                    if progress.stage == "直接传输并校验" { withUnsafeCurrentTask { $0?.cancel() } }
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

}
