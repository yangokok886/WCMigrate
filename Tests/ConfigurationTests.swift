import XCTest
@testable import TransferCore

final class ConfigurationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func put(_ path: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url); return url
    }
    func plist(_ name: String) throws -> URL { try put(name, PropertyListSerialization.data(fromPropertyList: ["enabled": true], format: .binary, options: 0)) }
    func service(_ path: String = "copies") -> PreferencesService { PreferencesService(store: root.appendingPathComponent(path)) }
    func testImportSinglePlistAndDelete() async throws {
        let file = try plist("plugin.plist"); let svc = service()
        let m = try await svc.importConfiguration(at: file, systemVersion: "test", deviceModel: "test")
        XCTAssertEqual(m.importedSingleFile, true); XCTAssertEqual(m.files.map(\.path), ["Library/Preferences/plugin.plist"])
        try await svc.verify(m)
        try await svc.delete(m.id); let copies = try await svc.list(); XCTAssertTrue(copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testImportedArchiveUsesOriginalFileName() async throws {
        _ = try plist("ConfigImport-random/Preferences/plugin.plist")
        let svc = service()
        let m = try await svc.importConfiguration(at: root.appendingPathComponent("ConfigImport-random"), systemVersion: "test", deviceModel: "test", displayName: "MyPluginBackup")
        XCTAssertEqual(m.instance.displayName, "MyPluginBackup")
        try await svc.verify(m)
    }
    func testInvalidPlistRejectedWithoutPublishing() async throws {
        let file = try put("bad.plist", Data("not a plist".utf8)); let svc = service()
        do { _ = try await svc.importConfiguration(at: file, systemVersion: "test", deviceModel: "test"); XCTFail() } catch {}
        let copies = try await svc.list(); XCTAssertTrue(copies.isEmpty)
    }
    func testFlatPlistFolderRecognized() async throws {
        _ = try plist("extracted/a.plist"); _ = try plist("extracted/b.plist")
        let m = try await service().importConfiguration(at: root.appendingPathComponent("extracted"), systemVersion: "test", deviceModel: "test")
        XCTAssertEqual(m.files.count, 2); XCTAssertFalse(m.importedSingleFile ?? false)
    }
    func testPreferencesTreeKeepsHiddenAndNonPlist() async throws {
        _ = try plist("extracted/Wrapper/Library/Preferences/a.plist")
        _ = try put("extracted/Wrapper/Library/Preferences/.hidden/options", Data("value".utf8))
        _ = try put("extracted/Wrapper/ignored-chat", Data("not configuration".utf8))
        let m = try await service().importConfiguration(at: root.appendingPathComponent("extracted"), systemVersion: "test", deviceModel: "test")
        XCTAssertEqual(m.files.count, 2); XCTAssertTrue(m.files.contains { $0.path.hasSuffix(".hidden/options") })
    }
    func testOwnArchiveManifestRoundTripAndTamperRefusal() async throws {
        let svc = service(); let first = try await svc.importConfiguration(at: plist("input.plist"), systemVersion: "test", deviceModel: "test")
        let own = root.appendingPathComponent("copies/" + first.id.uuidString)
        let second = try await service("imported").importConfiguration(at: own, systemVersion: "test", deviceModel: "test")
        XCTAssertEqual(second.files.map(\.sha256), first.files.map(\.sha256)); XCTAssertEqual(second.importedSingleFile, true)
        try Data("tampered".utf8).write(to: own.appendingPathComponent("payload/Library/Preferences/input.plist"))
        do { _ = try await service("bad").importConfiguration(at: own, systemVersion: "test", deviceModel: "test"); XCTFail() } catch {}
    }
    func testCustomConfigurationDirectory() async throws {
        _ = try put("app/Custom/Options/.config", Data("hidden".utf8)); _ = try put("app/Documents/chat", Data("chat".utf8))
        let app = AppInstance(displayName: "app", bundleIdentifier: "test.app", root: root.appendingPathComponent("app"), origin: "test")
        let svc = PreferencesService(store: root.appendingPathComponent("copies"), relativePath: "Custom/Options")
        let saved = try await svc.save(instance: app, systemVersion: "test", deviceModel: "test", progress: { _ in })
        let m = try XCTUnwrap(saved); XCTAssertEqual(m.files.map(\.path), ["Custom/Options/.config"]); try await svc.verify(m)
        let listed = try await svc.list(); XCTAssertEqual(listed.count, 1)
    }
    func testUnrecognizedFolderAndLinksRejected() async throws {
        _ = try put("unknown/chat.db", Data("chat".utf8))
        do { _ = try await service().importConfiguration(at: root.appendingPathComponent("unknown"), systemVersion: "test", deviceModel: "test"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("无法自动识别")) }
        _ = try plist("linked/Preferences/valid.plist")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked/Preferences/link").path, withDestinationPath: "/tmp")
        do { _ = try await service().importConfiguration(at: root.appendingPathComponent("linked"), systemVersion: "test", deviceModel: "test"); XCTFail() } catch {}
    }
    func testDiagnosticIncludesExactMappingConflictAndMissingPath() throws {
        let folder = root.appendingPathComponent("app"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { _ = try PathSafety.resolve("Documents/missing", in: folder); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("Documents")); XCTAssertTrue(error.localizedDescription.contains("errno=2"))
        }
        do { try PathSafety.validateMappings([DirectoryMapping(source: "a", target: "a")], source: folder, target: folder); XCTFail() } catch {}
        let issue = PathDiagnostic.system("扫描", "/exact/path", code: 1)
        XCTAssertTrue(issue.localizedDescription.contains("App Group")); XCTAssertTrue(issue.localizedDescription.contains("/exact/path"))
    }
    func testXinPrefixHasTopPriority() {
        let ids = ["com.tencent.ww", "com.other", "com.tencent.xin.clone", "com.tencent.xin", "com.tencent.qy.xin"]
        let apps = ids.map { AppInstance(displayName: $0, bundleIdentifier: $0, root: root, origin: "test") }
        let result = AppInstance.prioritized(apps)
        XCTAssertEqual(result[1].bundleIdentifier, "com.tencent.qy.xin"); XCTAssertEqual(result[2].bundleIdentifier, "com.tencent.xin.clone")
        XCTAssertEqual(result[0].bundleIdentifier, "com.tencent.xin"); XCTAssertEqual(result[3].bundleIdentifier, "com.tencent.ww")
    }
    func testImportedTreeRestoreReplaceAndMergeWithoutAutomaticBackup() async throws {
        for mode in [TransferMode.replace, .merge] {
            let base = mode.rawValue
            _ = try plist(base + "/input/Preferences/new.plist")
            let svc = service(base + "/copies")
            let m = try await svc.importConfiguration(at: root.appendingPathComponent(base + "/input"), systemVersion: "test", deviceModel: "test")
            let targetRoot = root.appendingPathComponent(base + "/app")
            _ = try plist(base + "/app/Library/Preferences/old.plist")
            _ = try put(base + "/app/Documents/chat", Data("untouched".utf8))
            let source = AppInstance(displayName: "config", bundleIdentifier: "config", root: root.appendingPathComponent(base + "/copies/" + m.id.uuidString + "/payload"), origin: "test")
            let target = AppInstance(displayName: "target", bundleIdentifier: "target", root: targetRoot, origin: "test")
            _ = try await DirectMigrationService(store: root.appendingPathComponent(base + "/tasks")).migrate(source: source, target: target, mappings: PreferencesService.restorationMappings(m, targetPath: "Library/Preferences"), mode: mode, preferences: svc, systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("Library/Preferences/new.plist").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("Library/Preferences/old.plist").path), mode == .merge)
            XCTAssertEqual(try String(contentsOf: targetRoot.appendingPathComponent("Documents/chat"), encoding: .utf8), "untouched")
            let copies = try await svc.list(); XCTAssertEqual(copies.count, 1); XCTAssertFalse(copies.contains { $0.instance.bundleIdentifier == "target" })
        }
    }
    func testSinglePlistRestoreDoesNotClearDirectory() async throws {
        let svc = service(); let m = try await svc.importConfiguration(at: plist("plugin.plist"), systemVersion: "test", deviceModel: "test")
        let source = AppInstance(displayName: "config", bundleIdentifier: "config", root: root.appendingPathComponent("copies/" + m.id.uuidString + "/payload"), origin: "test")
        let target = AppInstance(displayName: "app", bundleIdentifier: "app", root: root.appendingPathComponent("app"), origin: "test")
        _ = try plist("app/Library/Preferences/unrelated.plist")
        _ = try await DirectMigrationService(store: root.appendingPathComponent("tasks")).migrate(source: source, target: target, mappings: PreferencesService.restorationMappings(m, targetPath: "Library/Preferences"), mode: .replace, preferences: svc, systemVersion: "test", deviceModel: "test", allowOverwrite: true, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Library/Preferences/unrelated.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Library/Preferences/plugin.plist").path))
    }

}
