import XCTest
@testable import TransferCore

final class ConfigurationRenameTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func app(_ name: String, id: String) throws -> AppInstance {
        let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        return AppInstance(displayName: name, bundleIdentifier: id, root: url, origin: "test")
    }
    func put(_ app: AppInstance, name: String? = nil, value: String) throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
        try data.write(to: app.root.appendingPathComponent("Library/Preferences/" + (name ?? app.bundleIdentifier) + ".plist")); return data
    }
    func queue() -> ConfigurationRenameQueue { ConfigurationRenameQueue(file: root.appendingPathComponent("queue.json")) }
    let maps = [DirectoryMapping(source: "Library/Preferences", target: "Library/Preferences")]
    func testReplaceAndMergeAdaptNameAndKeepSourceAndPlugins() async throws {
        for mode in [TransferMode.replace, .merge] {
            let a = try app("a" + mode.rawValue, id: "com.tencent.xin"), b = try app("b" + mode.rawValue, id: "com.tencent.qy.xin")
            let content = try put(a, value: "source"); let plugin = try put(a, name: "com.plugin.options", value: "plugin")
            _ = try put(b, value: "old")
            let service = DirectMigrationService(store: root.appendingPathComponent("tasks" + mode.rawValue))
            _ = try await service.migrate(source: a, target: b, mappings: maps, mode: mode, preferences: PreferencesService(store: root.appendingPathComponent("backups")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
            let q = queue(); let jobs = try await q.enqueue(ConfigurationRename.plan(source: a, target: b, mappings: maps))
            let applied = try await q.apply(Set(jobs.map(\.id))); XCTAssertEqual(applied, 1)
            XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Library/Preferences/" + b.bundleIdentifier + ".plist")), content)
            XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Library/Preferences/com.plugin.options.plist")), plugin)
            XCTAssertEqual(try Data(contentsOf: a.root.appendingPathComponent("Library/Preferences/" + a.bundleIdentifier + ".plist")), content)
            XCTAssertFalse(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("Library/Preferences/" + a.bundleIdentifier + ".plist").path))
        }
    }
    func testExchangeAdaptsBothDirections() async throws {
        let a = try app("a", id: "com.tencent.xin"), b = try app("b", id: "clone.wechat")
        let x = try put(a, value: "first"), y = try put(b, value: "second")
        let jobs = ConfigurationRename.plan(source: a, target: b, mappings: maps) + ConfigurationRename.plan(source: b, target: a, mappings: maps)
        _ = try await DirectMigrationService(store: root.appendingPathComponent("tasks")).migrate(source: a, target: b, mappings: maps, mode: .exchange, preferences: PreferencesService(store: root.appendingPathComponent("copies")), systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        let q = queue(); let pending = try await q.enqueue(jobs); let n = try await q.apply(Set(pending.map(\.id))); XCTAssertEqual(n, 2)
        XCTAssertEqual(try Data(contentsOf: a.root.appendingPathComponent("Library/Preferences/com.tencent.xin.plist")), y)
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Library/Preferences/clone.wechat.plist")), x)
    }
    func testPendingSurvivesRestartAndRejectsChangedDestination() async throws {
        let a = try app("a", id: "com.tencent.xin"), b = try app("b", id: "clone.wechat")
        _ = try put(b, name: a.bundleIdentifier, value: "incoming"); _ = try put(b, value: "old")
        let q = queue(); let jobs = try await q.enqueue(ConfigurationRename.plan(source: a, target: b, mappings: maps))
        let restarted = queue(); let pending = try await restarted.pending(); XCTAssertEqual(pending.count, 1)
        _ = try put(b, value: "new external modification")
        do { _ = try await restarted.apply(Set(jobs.map(\.id))); XCTFail("Must preserve newer target config") } catch {}
        let left = try await restarted.pending(); XCTAssertEqual(left.count, 1)
    }
    func testRejectsSymlinkAndDoesNotRenamePluginOrDocuments() async throws {
        let a = try app("a", id: "com.tencent.xin"), b = try app("b", id: "clone.wechat")
        XCTAssertTrue(ConfigurationRename.plan(source: a, target: b, mappings: [DirectoryMapping(source: "Documents", target: "Documents")]).isEmpty)
        XCTAssertTrue(ConfigurationRename.plan(source: a, target: b, mappings: [DirectoryMapping(source: "Library/Preferences/plugin.plist", target: "Library/Preferences/plugin.plist")]).isEmpty)
        let external = root.appendingPathComponent("secret"); try Data("private".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: b.root.appendingPathComponent("Library/Preferences/" + a.bundleIdentifier + ".plist"), withDestinationURL: external)
        do { _ = try await queue().enqueue(ConfigurationRename.plan(source: a, target: b, mappings: maps)); XCTFail() } catch {}
    }
    func testSingleImportedFileAndCustomTargetPath() throws {
        let a = try app("a", id: "com.tencent.xin"), b = try app("b", id: "clone.wechat")
        let plan = ConfigurationRename.plan(source: a, target: b, mappings: [DirectoryMapping(source: "Library/Preferences/com.tencent.xin.plist", target: "Custom/com.tencent.xin.plist")])
        XCTAssertEqual(plan.first?.destination, "Custom/clone.wechat.plist")
        XCTAssertTrue(ConfigurationRename.plan(source: a, target: a, mappings: maps).isEmpty)
    }
}
