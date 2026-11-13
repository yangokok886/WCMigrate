import XCTest
import Foundation
@testable import TransferCore

final class DataStagingTests: XCTestCase {
    var root: URL!
    var own: URL!
    var migration: DirectMigrationService!
    var service: DataStagingService!
    var preferences: PreferencesService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        own = root.appendingPathComponent("WCMigrate")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        migration = DirectMigrationService(store: own.appendingPathComponent("Library/Tasks"))
        service = DataStagingService(root: own.appendingPathComponent("Documents/数据暂存"), ownContainer: own, migration: migration)
        preferences = PreferencesService(store: own.appendingPathComponent("Documents/插件配置备份"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func app(_ name: String) throws -> AppInstance {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Documents/Empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        try Data((name + " chat").utf8).write(to: url.appendingPathComponent("Documents/chat.db"))
        try Data((name + " plugin").utf8).write(to: url.appendingPathComponent("Library/Preferences/plugin.plist"))
        return AppInstance(displayName: name, bundleIdentifier: "com.tencent.xin", root: url, origin: "test")
    }
    func run(_ id: UUID) async throws -> MigrationReceipt {
        try await service.run(id, preferences: preferences, systemVersion: "test", deviceModel: "test", progress: { _ in })
    }
    func testMoveIntoOwnHoldingFolderAndReturnWithoutCopying() async throws {
        let source = try app("OldWeChat")
        let sentinel = own.appendingPathComponent("Library/live-config")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep own config".utf8).write(to: sentinel)
        let before = try FileManager.default.attributesOfItem(atPath: source.root.appendingPathComponent("Documents/chat.db").path)[.systemFileNumber] as? NSNumber
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        _ = try await run(record.id)
        let staged = try await service.application(for: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents").path))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("OldWeChat chat".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep own config".utf8))
        let movedInode = try FileManager.default.attributesOfItem(atPath: staged.root.appendingPathComponent("Documents/chat.db").path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, movedInode)
        // Simulate deleting the expired application after all selected paths are stored.
        try FileManager.default.removeItem(at: source.root)
        let target = try app("ReinstalledWeChat")
        try await service.beginReturn(record.id, target: target)
        _ = try await run(record.id)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("OldWeChat chat".utf8))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("OldWeChat plugin".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("ReinstalledWeChat chat".utf8))
        let returnedInode = try FileManager.default.attributesOfItem(atPath: target.root.appendingPathComponent("Documents/chat.db").path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, returnedInode)
        let records = try await service.list()
        XCTAssertEqual(records.first?.state, .returned)
        do { try await service.beginReturn(record.id, target: target); XCTFail("must not restore target leftovers as original chats") } catch {}
    }

    func testCorruptStagingRecordDoesNotHideHealthyRecords() async throws {
        let first = try app("Healthy")
        let second = try app("Broken")
        let healthy = try await service.create(source: first, selections: ["Documents"])
        let broken = try await service.create(source: second, selections: ["Documents"])
        let brokenMetadata = own.appendingPathComponent("Documents/数据暂存/.records/\(broken.id.uuidString).json")
        try Data("{ definitely not json".utf8).write(to: brokenMetadata)

        let listed = try await service.list()
        XCTAssertEqual(listed.map(\.id), [healthy.id])
    }
    func testInterruptedMoveResumesAfterRestart() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption before second mapping") } catch is CancellationError {}
        let partial = try await service.list()
        XCTAssertEqual(partial.first?.state, .incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Library").path))
        service = DataStagingService(root: own.appendingPathComponent("Documents/数据暂存"), ownContainer: own, migration: migration)
        _ = try await run(record.id)
        let completed = try await service.list()
        XCTAssertEqual(completed.first?.state, .stored)
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("Old plugin".utf8))
    }
    func testInterruptedStagingResumesAfterWCMigrateContainerChanges() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}

        let previousOwn = own!
        let previousStage = previousOwn.appendingPathComponent("Documents/数据暂存")
        let previousTasks = previousOwn.appendingPathComponent("Library/Tasks")
        let replacementOwn = root.appendingPathComponent("WCMigrateAfterReinstall")
        try FileManager.default.createDirectory(at: replacementOwn.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementOwn.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: previousStage, to: replacementOwn.appendingPathComponent("Documents/数据暂存"))
        try FileManager.default.moveItem(at: previousTasks, to: replacementOwn.appendingPathComponent("Library/Tasks"))

        own = replacementOwn
        migration = DirectMigrationService(store: replacementOwn.appendingPathComponent("Library/Tasks"))
        service = DataStagingService(root: replacementOwn.appendingPathComponent("Documents/数据暂存"), ownContainer: replacementOwn, migration: migration)
        let receipt = try await run(record.id)
        XCTAssertEqual(receipt.state, "filesVerified")
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("Old plugin".utf8))
    }
    func testResumeAcceptsEquivalentRootAliasAfterInterruption() async throws {
        var source = try app("Old")
        let real = source.root.resolvingSymlinksInPath()
        let alias = root.appendingPathComponent("OldAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        source.root = alias
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        var updated = record
        updated.application.root = real
        let url = own.appendingPathComponent("Documents/数据暂存/.records/" + record.id.uuidString + ".json")
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        let receipt = try await run(record.id)
        XCTAssertEqual(receipt.state, "filesVerified")
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("Old plugin".utf8))
    }
    func testDeleteBeforeFirstMigrationPlanExists() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"])
        try await service.delete(record.id)
        let items = try await service.list()
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents/chat.db").path))
    }
    func testDeletingIncompleteStageRemovesPayloadAndResumeJournal() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        let staged = try await service.application(for: record.id)
        let recordFolder = staged.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.root.appendingPathComponent("Documents/chat.db").path))
        try await service.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordFolder.path))
        let history = try await migration.history()
        XCTAssertFalse(history.contains { $0.id == record.incomingTask })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents/chat.db").path))
    }
    func testInterruptedReturnResumesWithoutRepeatingCompletedExchange() async throws {
        let source = try app("Old"), target = try app("New")
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        _ = try await run(record.id)
        try await service.beginReturn(record.id, target: target)
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        _ = try await run(record.id)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("Old plugin".utf8))
    }
    func testRejectOwnApplicationAndOverlappingPaths() async throws {
        var source = try app("Old")
        do { _ = try await service.create(source: source, selections: ["Library", "Library/Preferences"]); XCTFail("overlap") } catch {}
        source.root = own
        do { _ = try await service.create(source: source, selections: ["Documents"]); XCTFail("own sandbox") } catch {}
    }
    func testRejectNonemptyIncomingDestination() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"])
        let staged = try await service.application(for: record.id)
        try FileManager.default.createDirectory(at: staged.root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        do { _ = try await run(record.id); XCTFail("incoming must never swap unknown data back into source") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents/chat.db").path))
    }
    func testRecoversReceiptCompletedBeforeRecordWrite() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"])
        _ = try await run(record.id)
        // Simulate termination after the migration journal was committed but before record.json.
        let url = own.appendingPathComponent("Documents/数据暂存/.records/" + record.id.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        let recovered = try await service.list()
        XCTAssertEqual(recovered.first?.state, .stored)
    }
    func testStoredRecordCanBeDeleted() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"])
        _ = try await run(record.id)
        try await service.delete(record.id)
        let remaining = try await service.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testKeepSourceCopiesIntoBundleNamedDirectory() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"], keepSource: true)
        XCTAssertEqual(record.directoryName, "com.tencent.xin")
        _ = try await run(record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("Documents/chat.db").path))
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.root.appendingPathComponent("payload").path))
    }
    func testArbitraryFileCanBeStaged() async throws {
        let source = try app("Old")
        try Data("tmp".utf8).write(to: source.root.appendingPathComponent("custom.bin"))
        let record = try await service.create(source: source, selections: ["custom.bin"])
        _ = try await run(record.id)
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("custom.bin")), Data("tmp".utf8))
    }
    func testSameApplicationGetsSeparateBundleNamedRecords() async throws {
        let source = try app("Old")
        let first = try await service.create(source: source, selections: ["Documents"])
        let second = try await service.create(source: source, selections: ["Documents"])
        XCTAssertEqual(first.directoryName, "com.tencent.xin")
        XCTAssertEqual(second.directoryName, "com.tencent.xin-1")
        XCTAssertNotEqual(first.id, second.id)
    }
    func testMetadataDoesNotConflictWithSelectedFileOrPayloadFolder() async throws {
        let source = try app("Old")
        try Data("user record".utf8).write(to: source.root.appendingPathComponent("record.json"))
        try FileManager.default.createDirectory(at: source.root.appendingPathComponent("payload"), withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: source.root.appendingPathComponent("payload/data"))
        let record = try await service.create(source: source, selections: ["record.json", "payload"], keepSource: true)
        _ = try await run(record.id)
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(staged.root.lastPathComponent, "com.tencent.xin")
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("record.json")), Data("user record".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("payload/data")), Data("user data".utf8))
    }
    func testCopiedStageCanReturnAndBeDeletedWithoutTouchingOriginal() async throws {
        let source = try app("Old"), target = try app("New")
        let record = try await service.create(source: source, selections: ["Documents", "Library"], keepSource: true)
        _ = try await run(record.id)
        try await service.beginReturn(record.id, target: target)
        _ = try await run(record.id)
        try await service.delete(record.id)
        XCTAssertEqual(try Data(contentsOf: source.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        let remaining = try await service.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testLegacyRecordWithoutNewFieldsResumesAndDeletes() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents", "Library"])
        let stagingRoot = own.appendingPathComponent("Documents/数据暂存")
        let modernFolder = stagingRoot.appendingPathComponent(record.directoryName!)
        let legacyFolder = stagingRoot.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: legacyFolder.appendingPathComponent("payload"), withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "directoryName"); json.removeValue(forKey: "keepSource")
        try JSONSerialization.data(withJSONObject: json).write(to: legacyFolder.appendingPathComponent("record.json"))
        try FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(".records/" + record.id.uuidString + ".json"))
        try FileManager.default.removeItem(at: modernFolder)
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "双向转换完成" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        _ = try await run(record.id)
        let staged = try await service.application(for: record.id)
        XCTAssertEqual(staged.root.lastPathComponent, "payload")
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("Old chat".utf8))
        try await service.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFolder.path))
    }
    func testChangedCopySourceResumesWithCurrentContents() async throws {
        let source = try app("Old")
        let record = try await service.create(source: source, selections: ["Documents"], keepSource: true)
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { progress in
                if progress.stage == "系统快速复制 · 核对文件身份" || progress.stage == "复制并校验文件内容" {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        let file = source.root.appendingPathComponent("Documents/chat.db")
        try Data("new chat content after stopping".utf8).write(to: file)
        try Data("new".utf8).write(to: source.root.appendingPathComponent("Documents/new-file"))
        let staged = try await service.application(for: record.id)
        try Data("stale".utf8).write(to: staged.root.appendingPathComponent("Documents/removed-from-source"))
        let result = try await run(record.id)
        XCTAssertEqual(result.state, "filesVerified")
        XCTAssertEqual(result.files, 2)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("new chat content after stopping".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/new-file")), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.root.appendingPathComponent("Documents/removed-from-source").path))
        XCTAssertEqual(try Data(contentsOf: file), Data("new chat content after stopping".utf8))
        let records = try await service.list()
        XCTAssertEqual(records.first?.state, .stored)
    }
    func testCopyResumeRefreshesCompletedMappingAndSkipsUnchangedFile() async throws {
        let source = try app("Old")
        try Data("unchanged".utf8).write(to: source.root.appendingPathComponent("Documents/unchanged"))
        let record = try await service.create(source: source, selections: ["Documents", "Library"], keepSource: true)
        let task = Task {
            try await service.run(record.id, preferences: preferences, systemVersion: "test", deviceModel: "test") { p in
                if p.stage.contains("映射 2 执行前复查") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected interruption") } catch is CancellationError {}
        let staged = try await service.application(for: record.id)
        let unchanged = staged.root.appendingPathComponent("Documents/unchanged")
        let before = try FileManager.default.attributesOfItem(atPath: unchanged.path)[.systemFileNumber] as? NSNumber
        try Data("updated completed mapping".utf8).write(to: source.root.appendingPathComponent("Documents/chat.db"))
        _ = try await run(record.id)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Documents/chat.db")), Data("updated completed mapping".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: unchanged.path)[.systemFileNumber] as? NSNumber, before)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("Library/Preferences/plugin.plist")), Data("Old plugin".utf8))
    }
    func testLargeSparseFileMovesWithoutChangingIdentityOrLength() async throws {
        let source = try app("Old"), target = try app("New")
        let url = source.root.appendingPathComponent("Documents/large.dat")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try file.seek(toOffset: 2 * 1_024 * 1_024 * 1_024 - 4)
        try file.write(contentsOf: Data([1, 2, 3, 4])); try file.close()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let record = try await service.create(source: source, selections: ["Documents"])
        _ = try await run(record.id)
        try await service.beginReturn(record.id, target: target); _ = try await run(record.id)
        let moved = target.root.appendingPathComponent("Documents/large.dat")
        let after = try FileManager.default.attributesOfItem(atPath: moved.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        let input = try FileHandle(forReadingFrom: moved); defer { try? input.close() }
        try input.seek(toOffset: 2 * 1_024 * 1_024 * 1_024 - 4)
        XCTAssertEqual(try input.read(upToCount: 4), Data([1, 2, 3, 4]))
    }
}
