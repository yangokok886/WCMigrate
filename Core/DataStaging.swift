import Foundation

/// A holding area, never this application's live Documents/Library directories.
public struct StagedData: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case incoming, stored, returning, returned, deleting
        public var title: String {
            switch self {
            case .incoming: return "迁入尚未完成 · 勿删除原应用"
            case .stored: return "已暂存 · 可选择重装后的应用"
            case .returning: return "迁回尚未完成 · 勿删除暂存数据"
            case .deleting: return "删除尚未完成 · 可重试删除"
            case .returned: return "已迁回 · 此处保留目标原有内容"
            }
        }
    }
    public var id: UUID
    public var created: Date
    public var application: AppInstance
    public var selections: [String]
    public var state: State
    public var incomingTask: UUID
    public var returnTask: UUID?
    public var returnTarget: AppInstance?
    public var bytes: Int64 = 0
    public var files: Int = 0
    /// Persistent user-facing directory name. Missing in legacy records.
    public var directoryName: String? = nil
    /// When true, staging copies selected data and leaves the source untouched.
    public var keepSource: Bool = false
    public var layoutUpgradePending: Bool? = nil

    private enum CodingKeys: String, CodingKey { case id, created, application, selections, state, incomingTask, returnTask, returnTarget, bytes, files, directoryName, keepSource, layoutUpgradePending }
    public init(id: UUID, created: Date, application: AppInstance, selections: [String], state: State, incomingTask: UUID, returnTask: UUID? = nil, returnTarget: AppInstance? = nil, bytes: Int64 = 0, files: Int = 0, directoryName: String? = nil, keepSource: Bool = false) {
        self.id = id; self.created = created; self.application = application; self.selections = selections; self.state = state; self.incomingTask = incomingTask; self.returnTask = returnTask; self.returnTarget = returnTarget; self.bytes = bytes; self.files = files; self.directoryName = directoryName; self.keepSource = keepSource
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); created = try c.decode(Date.self, forKey: .created); application = try c.decode(AppInstance.self, forKey: .application)
        selections = try c.decode([String].self, forKey: .selections); state = try c.decode(State.self, forKey: .state); incomingTask = try c.decode(UUID.self, forKey: .incomingTask)
        returnTask = try c.decodeIfPresent(UUID.self, forKey: .returnTask); returnTarget = try c.decodeIfPresent(AppInstance.self, forKey: .returnTarget)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0; files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        directoryName = try c.decodeIfPresent(String.self, forKey: .directoryName); keepSource = try c.decodeIfPresent(Bool.self, forKey: .keepSource) ?? false
        layoutUpgradePending = try c.decodeIfPresent(Bool.self, forKey: .layoutUpgradePending)
    }
    public var mappings: [DirectoryMapping] { selections.map { DirectoryMapping(source: $0, target: $0) } }
}

/// Uses the normal durable exchange journal. Moving to a vacant path does not copy chat files.
/// Every operation is per selected path; a process termination may leave a mixed state until resumed.
public actor DataStagingService {
    public let root: URL
    private let ownContainer: URL
    private let migration: DirectMigrationService
    private let fm = FileManager.default
    private var running = false
    public init(root: URL, ownContainer: URL, migration: DirectMigrationService) {
        self.root = root; self.ownContainer = ownContainer; self.migration = migration
    }
    private func safeDirectoryName(_ value: String) -> String {
        let allowed = value.map { ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "_" }
        let result = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return result.isEmpty ? "application" : result
    }
    private func metadata(_ id: UUID) throws -> URL {
        try PathSafety.potential(".records/" + id.uuidString + ".json", in: root)
    }
    private func folder(_ item: StagedData) throws -> URL {
        let name = item.directoryName ?? item.id.uuidString
        guard !name.contains("/"), !name.hasPrefix(".") else { throw TransferError.corruptBackup }
        return try PathSafety.resolve(name, in: root)
    }
    private func save(_ item: StagedData) throws {
        let url: URL
        if item.directoryName != nil {
            url = try metadata(item.id)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else { url = try folder(item).appendingPathComponent("record.json") }
        try DurableJournal.write(JSONEncoder().encode(item), to: url)
    }
    private func load(_ id: UUID) throws -> StagedData {
        let modern = try metadata(id)
        let url = fm.fileExists(atPath: modern.path) ? modern : try PathSafety.resolve(id.uuidString + "/record.json", in: root)
        let item = try JSONDecoder().decode(StagedData.self, from: Data(contentsOf: url))
        guard item.id == id else { throw TransferError.corruptBackup }
        return item.layoutUpgradePending == true ? try finishLayoutUpgrade(item) : item
    }
    private func availableName(for app: AppInstance) -> String {
        let base = safeDirectoryName(app.bundleIdentifier)
        var name = base; var suffix = 1
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) { name = "\(base)-\(suffix)"; suffix += 1 }
        return name
    }
    private func finishLayoutUpgrade(_ record: StagedData) throws -> StagedData {
        var item = record
        guard let name = item.directoryName, !name.contains("/"), !name.hasPrefix(".") else { throw TransferError.corruptBackup }
        let legacy = try PathSafety.potential(item.id.uuidString, in: root)
        let payload = try PathSafety.potential(item.id.uuidString + "/payload", in: root)
        let destination = try PathSafety.potential(name, in: root)
        if fm.fileExists(atPath: payload.path) {
            guard !fm.fileExists(atPath: destination.path) else { throw MigrationFailure.conflict }
            // Same-volume directory rename, not a second copy of the chat data.
            try fm.moveItem(at: payload, to: destination)
        }
        guard fm.fileExists(atPath: destination.path) else { throw TransferError.corruptBackup }
        if fm.fileExists(atPath: legacy.path) {
            let remaining = try fm.contentsOfDirectory(atPath: legacy.path)
            guard remaining.allSatisfy({ $0 == "record.json" }) else { throw MigrationFailure.conflict }
            try fm.removeItem(at: legacy)
        }
        item.layoutUpgradePending = nil
        try save(item)
        return item
    }
    private func upgradeLayout(_ record: StagedData) throws -> StagedData {
        var item = record
        item.directoryName = availableName(for: item.application)
        item.layoutUpgradePending = true
        // Persist intent first: after termination, load finishes the rename and metadata cleanup.
        try save(item)
        return try finishLayoutUpgrade(item)
    }
    private func validateExternal(_ app: AppInstance) throws {
        let path = app.root.resolvingSymlinksInPath().standardizedFileURL.path
        let own = ownContainer.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != own, !path.hasPrefix(own + "/"), !own.hasPrefix(path + "/") else {
            throw PathDiagnostic("检查暂存边界", path, "请选择外部应用。暂存区不能指向 WCMigrate 自身的活动目录。")
        }
    }
    public func application(for id: UUID) throws -> AppInstance {
        let item = try load(id)
        let directory = try folder(item)
        let dataRoot = item.directoryName == nil ? try PathSafety.resolve("payload", in: directory) : directory
        return AppInstance(id: "staging-" + id.uuidString, displayName: item.application.displayName + " · 暂存数据",
            bundleIdentifier: item.application.bundleIdentifier, root: dataRoot, origin: "WCMigrate 数据暂存")
    }
    public func create(source: AppInstance, selections: [String], keepSource: Bool = false) throws -> StagedData {
        try validateExternal(source)
        try PathSafety.validateItems(selections, root: source.root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try (root as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        let id = UUID()
        let name = availableName(for: source)
        let item = StagedData(id: id, created: Date(), application: source, selections: selections.sorted(), state: .incoming, incomingTask: UUID(), directoryName: name, keepSource: keepSource)
        let directory = root.appendingPathComponent(name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        // Persist the chosen paths and task ID before any move.
        try save(item)
        return item
    }
    public func list() async throws -> [StagedData] {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let history = try await migration.history()
        var result: [StagedData] = []
        var ids = Set<UUID>()
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), fm.fileExists(atPath: url.appendingPathComponent("record.json").path) { ids.insert(id) }
        }
        let records = try PathSafety.potential(".records", in: root)
        if fm.fileExists(atPath: records.path) {
            for url in try fm.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) {
                if url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { ids.insert(id) }
            }
        }
        for id in ids {
            var item = try load(id)
            // Recover a successful task even if killed before the metadata update.
            let task = item.state == .incoming ? item.incomingTask : (item.state == .returning ? item.returnTask : nil)
            if !running, let task, let receipt = history.first(where: { $0.id == task }), receipt.state == "filesVerified" {
                item.state = item.state == .incoming ? .stored : .returned
                item.bytes = receipt.bytes; item.files = receipt.files; try save(item)
            }
            if !running, item.directoryName == nil, item.state == .stored || item.state == .returned {
                item = try upgradeLayout(item)
            }
            result.append(item)
        }
        return result.sorted { $0.created > $1.created }
    }
    public func beginReturn(_ id: UUID, target: AppInstance) async throws {
        guard !running else { throw TransferError.unavailable }
        running = true; defer { running = false }
        let items = try await list()
        guard var item = items.first(where: { $0.id == id }), item.state == .stored else { throw TransferError.unavailable }
        try validateExternal(target)
        let source = try application(for: id)
        // Check permissions, paths, same-volume atomic exchange, and space before changing state.
        _ = try await migration.preview(source: source, target: target, mappings: item.mappings, mode: .exchange, detailed: false)
        item.state = .returning; item.returnTarget = target; item.returnTask = UUID(); try save(item)
    }
    public func delete(_ id: UUID) async throws {
        guard !running else { throw TransferError.unavailable }
        running = true; defer { running = false }
        var item = try load(id)
        item.state = .deleting
        try save(item)
        // Invalidate resume before deleting data. A retry can finish an interrupted deletion.
        try await migration.deleteTask(item.incomingTask)
        if let returnTask = item.returnTask { try await migration.deleteTask(returnTask) }
        let directory = try PathSafety.potential(item.directoryName ?? id.uuidString, in: root)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        let manifest = try metadata(id)
        if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
    }
    public func run(_ id: UUID, preferences: PreferencesService, systemVersion: String, deviceModel: String,
                    diagnostic: @escaping @Sendable (String) -> Void = { _ in }, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> MigrationReceipt {
        guard !running else { throw TransferError.unavailable }
        running = true; defer { running = false }
        var item = try load(id)
        guard item.state == .incoming || item.state == .returning else { throw TransferError.unavailable }
        let incoming = item.state == .incoming
        let taskID = incoming ? item.incomingTask : item.returnTask
        guard let taskID else { throw TransferError.corruptBackup }
        let staged = try application(for: id)
        let source = incoming ? item.application : staged
        guard let target = incoming ? staged : item.returnTarget else { throw TransferError.corruptBackup }
        try validateExternal(incoming ? source : target)
        diagnostic("暂存任务 · \(id.uuidString) · \(incoming ? "存入" : "迁回") · 保留来源 \(item.keepSource) · \(source.bundleIdentifier) → \(target.bundleIdentifier)")
        let result: MigrationReceipt
        if let existing = try await migration.history().first(where: { $0.id == taskID }) {
            if existing.state == "filesVerified" { result = existing }
            else { result = try await migration.resumeStaging(taskID, recordID: id, stagingRoot: root, source: source, target: target, preferences: preferences, diagnostic: diagnostic, progress: progress) }
        } else {
            // A new incoming task must never exchange with user-created/leftover staging contents.
            if incoming {
                for path in item.selections {
                    let url = try PathSafety.potential(path, in: target.root)
                    guard !fm.fileExists(atPath: url.path) else { throw MigrationFailure.conflict }
                }
            }
            result = try await migration.migrate(source: source, target: target, mappings: item.mappings, mode: incoming && item.keepSource ? .replace : .exchange,
                preferences: preferences, systemVersion: systemVersion, deviceModel: deviceModel, allowOverwrite: true,
                taskID: taskID, diagnostic: diagnostic, progress: progress)
        }
        guard result.state == "filesVerified" else { throw TransferError.unavailable }
        item.state = incoming ? .stored : .returned; item.bytes = result.bytes; item.files = result.files
        try save(item)
        return result
    }
}
