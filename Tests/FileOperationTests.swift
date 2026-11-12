import XCTest
@testable import TransferCore

final class FileOperationTests: XCTestCase {
    var root: URL!
    var source: AppInstance!
    var target: AppInstance!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["one", "two"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name + "/Library/Preferences"), withIntermediateDirectories: true) }
        source = AppInstance(displayName: "One", bundleIdentifier: "test.one", root: root.appendingPathComponent("one"), origin: "test")
        target = AppInstance(displayName: "Two", bundleIdentifier: "test.two", root: root.appendingPathComponent("two"), origin: "test")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func put(_ app: AppInstance, _ path: String, _ text: String) throws {
        let url = app.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func text(_ app: AppInstance, _ path: String) throws -> String { try String(contentsOf: app.root.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ app: AppInstance, _ path: String) -> Bool { FileManager.default.fileExists(atPath: app.root.appendingPathComponent(path).path) }
    func run(_ mode: TransferMode, _ paths: [(String, String)]) async throws -> MigrationReceipt {
        try await DirectMigrationService(store: root.appendingPathComponent("Tasks")).migrate(source: source, target: target,
            mappings: paths.map { DirectoryMapping(source: $0.0, target: $0.1) }, mode: mode,
            preferences: PreferencesService(store: root.appendingPathComponent("Preferences")), systemVersion: "test", deviceModel: "test",
            allowOverwrite: true, progress: { _ in })
    }
    func testSingleRootFileReplacesAndPreservesSource() async throws {
        try put(source, "root.plist", "one"); try put(target, "root.plist", "two")
        let receipt = try await run(.replace, [("root.plist", "root.plist")])
        XCTAssertEqual(receipt.state, "filesVerified"); XCTAssertEqual(try text(source, "root.plist"), "one"); XCTAssertEqual(try text(target, "root.plist"), "one")
    }
    func testMergeKeepsTargetOnlyFilesAtEveryDepth() async throws {
        try put(source, "tmp/selected/same", "one"); try put(source, "tmp/selected/new", "new")
        try put(target, "tmp/selected/same", "two"); try put(target, "tmp/selected/target-only", "keep")
        try put(target, "tmp/selected/Nested/only", "nested")
        _ = try await run(.merge, [("tmp/selected", "tmp/selected")])
        XCTAssertEqual(try text(target, "tmp/selected/same"), "one"); XCTAssertEqual(try text(target, "tmp/selected/target-only"), "keep")
        XCTAssertEqual(try text(target, "tmp/selected/Nested/only"), "nested"); XCTAssertEqual(try text(source, "tmp/selected/same"), "one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.root.appendingPathComponent("tmp/selected").path).sorted(), ["Nested","new","same","target-only"])
    }
    func testReplaceRemovesTargetOnlyContentsButNotOutsideSelection() async throws {
        try put(source, "tmp/chosen/one", "one"); try put(target, "tmp/chosen/Nested/extra", "remove"); try put(target, "tmp/outside", "keep")
        _ = try await run(.replace, [("tmp/chosen", "tmp/chosen")])
        XCTAssertFalse(exists(target, "tmp/chosen/Nested")); XCTAssertEqual(try text(target, "tmp/outside"), "keep")
    }
    func testMissingNestedDestinationIsCreatedForFileAndFolder() async throws {
        try put(source, "single", "one"); try put(source, "Folder/a", "a")
        _ = try await run(.merge, [("single", "tmp/new/file"), ("Folder", "Documents/newFolder")])
        XCTAssertEqual(try text(target, "tmp/new/file"), "one"); XCTAssertEqual(try text(target, "Documents/newFolder/a"), "a")
        XCTAssertFalse(exists(target, "Documents/newFolder/Folder"))
    }
    func testFileFolderTypeCollisionsReplaceWithoutRenaming() async throws {
        try put(source, "Folder/item", "directory"); try put(target, "Folder", "old-file")
        try put(source, "single", "new-file"); try put(target, "single/child", "old-directory")
        _ = try await run(.merge, [("Folder", "Folder"), ("single", "single")])
        XCTAssertEqual(try text(target, "Folder/item"), "directory"); XCTAssertEqual(try text(target, "single"), "new-file")
        XCTAssertFalse(exists(target, "single/child"))
    }
    func testNestedTypeCollisionsAndTargetOnlyMerge() async throws {
        try put(source, "Data/a", "file"); try put(source, "Data/b/item", "folder")
        try put(target, "Data/a/nested", "remove"); try put(target, "Data/b", "old"); try put(target, "Data/keep", "keep")
        _ = try await run(.merge, [("Data", "Data")])
        XCTAssertEqual(try text(target, "Data/a"), "file"); XCTAssertEqual(try text(target, "Data/b/item"), "folder"); XCTAssertEqual(try text(target, "Data/keep"), "keep")
    }
    func testExchangeFilesMovesOriginalBytesAndInodesBothDirections() async throws {
        try put(source, "one.dat", "one"); try put(target, "two.dat", "two")
        let a = try FileManager.default.attributesOfItem(atPath: source.root.appendingPathComponent("one.dat").path)[.systemFileNumber] as? NSNumber
        let b = try FileManager.default.attributesOfItem(atPath: target.root.appendingPathComponent("two.dat").path)[.systemFileNumber] as? NSNumber
        let receipt = try await run(.exchange, [("one.dat", "two.dat")])
        XCTAssertEqual(try text(source, "one.dat"), "two"); XCTAssertEqual(try text(target, "two.dat"), "one")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.root.appendingPathComponent("one.dat").path)[.systemFileNumber] as? NSNumber, b)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.root.appendingPathComponent("two.dat").path)[.systemFileNumber] as? NSNumber, a)
        XCTAssertEqual(receipt.exchanged?.count, 1); XCTAssertNil(receipt.pendingExchange)
    }
    func testExchangeWholeFoldersDoesNotMixTheirContents() async throws {
        try put(source, "Documents/a", "one"); try put(target, "Documents/b", "two")
        _ = try await run(.exchange, [("Documents", "Documents")])
        XCTAssertEqual(try text(source, "Documents/b"), "two"); XCTAssertFalse(exists(source, "Documents/a"))
        XCTAssertEqual(try text(target, "Documents/a"), "one"); XCTAssertFalse(exists(target, "Documents/b"))
    }
    func testExchangeMissingDestinationMovesSource() async throws {
        try put(source, "single", "move")
        _ = try await run(.exchange, [("single", "new/sub/item")])
        XCTAssertFalse(exists(source, "single")); XCTAssertEqual(try text(target, "new/sub/item"), "move")
    }
    func testExchangeSupportsFileAndFolderPair() async throws {
        try put(source, "choice", "one"); try put(target, "choice/nested", "two")
        _ = try await run(.exchange, [("choice", "choice")])
        XCTAssertEqual(try text(source, "choice/nested"), "two"); XCTAssertEqual(try text(target, "choice"), "one")
    }
    func testMappingRejectsLinksAndOverlappingMissingPaths() throws {
        try put(source, "file", "data")
        try FileManager.default.createSymbolicLink(atPath: target.root.appendingPathComponent("linked").path, withDestinationPath: root.path)
        XCTAssertThrowsError(try PathSafety.validateMappings([DirectoryMapping(source: "file", target: "linked/x")], source: source.root, target: target.root))
        try put(source, "other", "other")
        XCTAssertThrowsError(try PathSafety.validateMappings([DirectoryMapping(source: "file", target: "new"), DirectoryMapping(source: "other", target: "new/sub")], source: source.root, target: target.root))
    }
    func testAllModesDoNotAutomaticallySavePreferences() async throws {
        try put(source, "sample", "one"); try put(target, "sample", "two")
        try put(source, "Library/Preferences/plugin.plist", "p1"); try put(target, "Library/Preferences/plugin.plist", "p2")
        for mode in TransferMode.allCases { _ = try await run(mode, [("sample", "sample")]) }
        let copies = try await PreferencesService(store: root.appendingPathComponent("Preferences")).list()
        XCTAssertEqual(copies.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Preferences").appendingPathComponent("payload").path))
    }
    func testNoLibraryStillAllowsAnySandboxFile() async throws {
        try FileManager.default.removeItem(at: source.root.appendingPathComponent("Library")); try FileManager.default.removeItem(at: target.root.appendingPathComponent("Library"))
        try put(source, "root-file", "data")
        let receipt = try await run(.replace, [("root-file", "root-file")])
        XCTAssertEqual(receipt.preferenceAbsences.count, 0); XCTAssertEqual(try text(target, "root-file"), "data")
    }
    func testApplicationIdentityAndTencentPriority() throws {
        var a = source!; a.displayName = "Z"; a.bundleIdentifier = "com.tencent.example"
        var b = target!; b.displayName = "A"; b.executableName = "WeChat"; b.bundlePath = "/installed/Example.app"
        XCTAssertTrue(b.isWeChat); XCTAssertEqual(AppInstance.prioritized([b,a]).first?.id, a.id)
        b.executableName = "NotWeChat"; XCTAssertFalse(b.isWeChat)
        b.executableName = "WeChat"; b.bundlePath = nil; XCTAssertFalse(b.isWeChat)
    }
    func testLegacyApplicationMetadataStillDecodes() throws {
        let data = try JSONEncoder().encode(source!)
        let decoded = try JSONDecoder().decode(AppInstance.self, from: data)
        XCTAssertNil(decoded.executableName); XCTAssertNil(decoded.bundlePath)
    }
    func testCancellationBetweenExchangesRecordsCompletedPair() async throws {
        for path in ["first", "second"] { try put(source, path, "one"); try put(target, path, "two") }
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let a = source!; let b = target!; let preferences = PreferencesService(store: root.appendingPathComponent("Preferences"))
        let task = Task {
            try await service.migrate(source: a, target: b,
                mappings: [DirectoryMapping(source: "first", target: "first"), DirectoryMapping(source: "second", target: "second")], mode: .exchange,
                preferences: preferences, systemVersion: "test", deviceModel: "test", allowOverwrite: true) { progress in
                    if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        do { _ = try await task.value; XCTFail("cancelled task completed") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(try text(source, "first"), "two"); XCTAssertEqual(try text(target, "first"), "one")
        XCTAssertEqual(try text(source, "second"), "one"); XCTAssertEqual(try text(target, "second"), "two")
        let history = try await service.history(); XCTAssertEqual(history.first?.state, "cancelledPartial")
        XCTAssertEqual(history.first?.exchanged?.count, 1); XCTAssertNil(history.first?.pendingExchange)
    }
    func testLegacyReceiptDefaultsToReplace() async throws {
        try put(source, "file", "one")
        let receipt = try await run(.replace, [("file", "file")])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        for key in ["operation", "exchanged", "pendingExchange"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(MigrationReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.mode, .replace)
    }

}
