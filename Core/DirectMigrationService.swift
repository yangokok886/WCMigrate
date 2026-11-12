import Foundation
import Darwin
#if canImport(CSupport)
import CSupport
#endif

public struct MigrationSummary: Codable, Sendable {
    public let id: UUID
    public let sourceName: String
    public let targetName: String
    public let sourceBundleID: String
    public let targetBundleID: String
    public let files: Int
    public let bytes: Int64
    public let largestFile: Int64
    public let targetFiles: Int
    public let mappings: [DirectoryMapping]
    public let targetPreferencesExist: Bool
    public let mode: TransferMode
}
public struct MigrationReceipt: Identifiable, Codable, Sendable {
    public var id: UUID
    public var created: Date
    public var sourceName: String
    public var targetName: String
    public var sourceBundleID: String
    public var targetBundleID: String
    public var state: String
    public var files: Int
    public var bytes: Int64
    public var completedFiles: Int
    public var completedBytes: Int64
    public var preferences: [UUID]
    public var preferenceAbsences: [String]
    public var mappings: [DirectoryMapping]
    // Optional additions preserve loading of 0.2 task records.
    public var operation: TransferMode? = nil
    public var resumable: Bool? = nil
    public var configurationID: UUID? = nil
    public var exchanged: [DirectoryMapping]? = nil
    public var pendingExchange: DirectoryMapping? = nil
    public var mode: TransferMode { operation ?? .replace }
}
public enum MigrationFailure: Error, LocalizedError {
    case changed, conflict, insufficientSpace, exchangeUnsupported
    public var errorDescription: String? {
        switch self {
        case .changed: return "数据在执行期间发生变化，操作已停止。任务可能已部分完成，请核对两边内容与记录。"
        case .conflict: return "存在文件类型或目录边界冲突，请调整映射。"
        case .insufficientSpace: return "目标可用空间不足，不会改为先删除文件腾空间。"
        case .exchangeUnsupported: return "转换要求两边位于同一文件系统且系统允许原子交换。本次未降级为整份复制。"
        }
    }
}
public actor DirectMigrationService {
    private let fm = FileManager.default
    private let prepareAccess: @Sendable (URL) -> Void
    public let store: URL
    private let preferCloning: Bool
    private struct Item: Equatable, Codable {
        var relative: String
        var directory: Bool
        var bytes: Int64
        var modified: Date
        var inode: UInt64
        var device: Int32
    }
    private struct Tree: Codable {
        var items: [Item]
        var files: [Item] { items.filter { !$0.directory } }
    }
    private struct ResumePlan: Codable {
        var source: AppInstance
        var target: AppInstance
        var summary: MigrationSummary
        var sources: [Tree]
        var targets: [Tree]
        var completed: [Int: [Tree]] = [:]
    }
    private func planURL(_ id: UUID) -> URL { store.appendingPathComponent("Plans").appendingPathComponent(id.uuidString + ".json") }
    private func temporaryJournalURL(_ id: UUID) -> URL { store.appendingPathComponent("Plans").appendingPathComponent(id.uuidString + ".pending") }
    private func persistTemporary(_ id: UUID, path: String?) throws {
        try DurableJournal.write(JSONEncoder().encode(path), to: temporaryJournalURL(id))
    }
    private func readTemporary(_ id: UUID) throws -> String? {
        let url = temporaryJournalURL(id)
        if !fm.fileExists(atPath: url.path) { return nil }
        return try JSONDecoder().decode(String?.self, from: Data(contentsOf: url))
    }
    private func persistPlan(_ plan: ResumePlan) throws {
        try fm.createDirectory(at: planURL(plan.summary.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
        try DurableJournal.write(encoder.encode(plan), to: planURL(plan.summary.id))
    }
    private func readPlan(_ id: UUID) throws -> ResumePlan {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(ResumePlan.self, from: Data(contentsOf: planURL(id)))
    }
    public func recoveryApplications(_ id: UUID) throws -> [AppInstance] {
        let plan = try readPlan(id); return [plan.source, plan.target]
    }
    public func resume(_ id: UUID, source: AppInstance, target: AppInstance, preferences: PreferencesService,
                       progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> MigrationReceipt {
        try await migrate(source: source, target: target, mappings: [], preferences: preferences, systemVersion: "", deviceModel: "", allowOverwrite: true, resuming: id, progress: progress)
    }
    // A stopped copy can contain a mixture of original target files and committed source files.
    // Reject unrelated changes rather than treating whatever is there now as a new baseline.
    private func validatePartial(source: Tree, original: Tree, current: Tree, sourceBase: URL, targetBase: URL, mode: TransferMode) throws {
        let old = Dictionary(uniqueKeysWithValues: original.items.map { ($0.relative, $0) })
        let src = Dictionary(uniqueKeysWithValues: source.items.map { ($0.relative, $0) })
        let now = Dictionary(uniqueKeysWithValues: current.items.map { ($0.relative, $0) })
        for item in current.items {
            if let prior = old[item.relative], item == prior || (item.directory && prior.directory && item.inode == prior.inode && item.device == prior.device) { continue }
            guard let match = src[item.relative], item.directory == match.directory, item.bytes == match.bytes else { throw PathDiagnostic("续传复查目标目录项", targetBase.appendingPathComponent(item.relative).path, "当前项目既不匹配原始目标，也不匹配来源，未继续覆盖。") }
            if !item.directory {
                guard try equalContents(try child(sourceBase, item.relative), try child(targetBase, item.relative)) else { throw PathDiagnostic("续传校验已写入文件", targetBase.appendingPathComponent(item.relative).path, "当前内容的 SHA-256 不匹配来源，也不匹配中断前目标身份。") }
            }
        }
        if mode == .merge {
            for prior in original.items where now[prior.relative] == nil {
                let replacedAncestor = source.items.contains { entry in
                    (!entry.directory && (prior.relative == entry.relative || (entry.relative.isEmpty || prior.relative.hasPrefix(entry.relative + "/")))) ||
                    (entry.directory && entry.relative == prior.relative && !prior.directory)
                }
                guard replacedAncestor else { throw MigrationFailure.changed }
            }
        }
    }
    private func equalContents(_ a: URL, _ b: URL) throws -> Bool {
        prepareAccess(a); prepareAccess(b)
        let x = XCTOpenReadOnly(a.path), y = XCTOpenReadOnly(b.path)
        guard x >= 0, y >= 0 else { if x >= 0 { close(x) }; if y >= 0 { close(y) }; throw MigrationFailure.changed }
        defer { close(x); close(y) }
        return try hash(x, output: nil, progress: { _ in }) == hash(y, output: nil, progress: { _ in })
    }
    public init(store: URL, preferCloning: Bool = true, prepareAccess: @escaping @Sendable (URL) -> Void = { _ in }) { self.store = store; self.preferCloning = preferCloning; self.prepareAccess = prepareAccess }
    private func child(_ base: URL, _ relative: String) throws -> URL {
        if relative.isEmpty { return base }
        return try PathSafety.potential(relative, in: base, prepareAccess: prepareAccess)
    }
    private func tree(root: URL, relative: String) throws -> Tree {
        prepareAccess(root); prepareAccess(root.appendingPathComponent(relative))
        let base = try PathSafety.potential(relative, in: root, prepareAccess: prepareAccess)
        var initial = stat()
        if lstat(base.path, &initial) != 0 {
            guard errno == ENOENT else { throw PathDiagnostic.system("读取文件树入口", base.path, code: errno) }
            return Tree(items: [])
        }
        var items: [Item] = []
        func walk(_ url: URL, _ inside: String) throws {
            try Task.checkCancellation(); prepareAccess(url)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw PathDiagnostic.system("扫描文件树", url.path, code: errno) }
            guard XCTModeIsSymlink(UInt32(info.st_mode)) == 0 else { throw PathDiagnostic("扫描文件树", url.path, "检测到符号链接；请取消选择该链接或缩小范围。") }
            let a = try fm.attributesOfItem(atPath: url.path)
            let kind = a[.type] as? FileAttributeType
            guard kind == .typeDirectory || kind == .typeRegular else { throw PathDiagnostic("扫描文件类型", url.path, "不支持特殊文件。") }
            items.append(Item(relative: inside, directory: kind == .typeDirectory,
                bytes: kind == .typeRegular ? Int64(info.st_size) : 0,
                modified: a[.modificationDate] as? Date ?? .distantPast, inode: UInt64(info.st_ino), device: Int32(info.st_dev)))
            if kind == .typeDirectory {
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    prepareAccess(url.appendingPathComponent(name))
                    let next = try PathSafety.resolve(name, in: url, prepareAccess: prepareAccess)
                    try walk(next, inside.isEmpty ? name : inside + "/" + name)
                }
            }
        }
        try walk(base, ""); return Tree(items: items)
    }
    private func validate(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], allowMissingSource: Bool = false) throws {
        prepareAccess(source.root); prepareAccess(target.root)
        for (root, paths) in [(source.root, mappings.map(\.source)), (target.root, mappings.map(\.target))] {
            for path in paths { var current = root; for part in path.split(separator: "/") { current.appendPathComponent(String(part)); prepareAccess(current) } }
        }
        try PathSafety.validateMappings(mappings, source: source.root, target: target.root, allowMissingSource: allowMissingSource)
        let s = source.root.resolvingSymlinksInPath().path; let t = target.root.resolvingSymlinksInPath().path
        let destination = store.resolvingSymlinksInPath().path
        guard destination != s, destination != t, !destination.hasPrefix(s + "/"), !destination.hasPrefix(t + "/") else { throw TransferError.invalidPath }
    }
    private func preflight(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], mode: TransferMode) throws -> (MigrationSummary, [Tree], [Tree]) {
        try validate(source: source, target: target, mappings: mappings)
        var sources: [Tree] = []; var targets: [Tree] = []
        var total: Int64 = 0; var largest: Int64 = 0; var added: Int64 = 0
        for m in mappings {
            let s = try tree(root: source.root, relative: m.source)
            let t = try tree(root: target.root, relative: m.target)
            guard !s.items.isEmpty else { throw TransferError.invalidPath }
            let old = Dictionary(uniqueKeysWithValues: t.items.map { ($0.relative, $0) })
            for item in s.files {
                total += item.bytes; largest = max(largest, item.bytes)
                added += max(0, item.bytes - (old[item.relative]?.bytes ?? 0))
            }
            if mode == .exchange {
                var existing = try PathSafety.potential(m.target, in: target.root)
                while !fm.fileExists(atPath: existing.path) { existing.deleteLastPathComponent() }
                var info = stat()
                guard lstat(existing.path, &info) == 0, s.items[0].device == Int32(info.st_dev) else { throw MigrationFailure.exchangeUnsupported }
                total += t.files.reduce(Int64(0)) { $0 + $1.bytes }
            }
            sources.append(s); targets.append(t)
        }
        let available = try fm.attributesOfFileSystem(forPath: target.root.path)[.systemFreeSize] as? NSNumber
        let required = mode == .exchange ? 32 * 1_048_576 : added + largest + 32 * 1_048_576
        guard let available, available.int64Value > required else { throw MigrationFailure.insufficientSpace }
        let fileCount = sources.reduce(0) { $0 + $1.files.count } + (mode == .exchange ? targets.reduce(0) { $0 + $1.files.count } : 0)
        return (MigrationSummary(id: UUID(), sourceName: source.displayName, targetName: target.displayName,
            sourceBundleID: source.bundleIdentifier, targetBundleID: target.bundleIdentifier,
            files: fileCount, bytes: total, largestFile: largest, targetFiles: targets.reduce(0) { $0 + $1.files.count },
            mappings: mappings, targetPreferencesExist: false, mode: mode), sources, targets)
    }
    public func preview(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], mode: TransferMode = .replace) throws -> MigrationSummary {
        try preflight(source: source, target: target, mappings: mappings, mode: mode).0
    }
    private func persist(_ receipt: MigrationReceipt) throws {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try DurableJournal.write(encoder.encode(receipt), to: store.appendingPathComponent(receipt.id.uuidString + ".json"))
    }
    public func history() throws -> [MigrationReceipt] {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try decoder.decode(MigrationReceipt.self, from: Data(contentsOf: $0)) }.sorted { $0.created > $1.created }
    }
    private func createParents(of url: URL, in root: URL) throws {
        let canonical = root.resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent()
        guard parent == canonical || parent.path.hasPrefix(canonical.path + "/") else { throw TransferError.invalidPath }
        if parent == canonical { return }
        let relative = String(parent.path.dropFirst(canonical.path.count + 1))
        var current = canonical
        for part in relative.split(separator: "/") {
            current = try PathSafety.potential(String(part), in: current); prepareAccess(current.deletingLastPathComponent())
            if !fm.fileExists(atPath: current.path) { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
            guard try fm.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType == .typeDirectory else { throw MigrationFailure.conflict }
        }
    }
    private func checkItem(_ expected: Item?, at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard expected == nil && errno == ENOENT else { throw MigrationFailure.changed }; return
        }
        guard let expected, XCTModeIsSymlink(UInt32(info.st_mode)) == 0,
              UInt64(info.st_ino) == expected.inode, Int32(info.st_dev) == expected.device else { throw MigrationFailure.changed }
        let a = try fm.attributesOfItem(atPath: url.path)
        guard (a[.type] as? FileAttributeType == .typeDirectory) == expected.directory else { throw MigrationFailure.changed }
        if !expected.directory {
            guard info.st_size == expected.bytes, a[.modificationDate] as? Date == expected.modified else { throw MigrationFailure.changed }
        }
    }
    private func hash(_ fd: Int32, output: FileHandle?, progress: (Int64) throws -> Void) throws -> (String, Int64) {
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var ctx = CC_SHA256_CTX(); CC_SHA256_Init(&ctx); var size: Int64 = 0; var lastUpdate = Date.distantPast
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 4 * 1_048_576) ?? Data(); if chunk.isEmpty { break }
            chunk.withUnsafeBytes { _ = CC_SHA256_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) }
            try output?.write(contentsOf: chunk); size += Int64(chunk.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.2 { lastUpdate = Date(); try progress(size) }
        }
        try progress(size)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH)); CC_SHA256_Final(&digest, &ctx)
        return (digest.map { String(format: "%02x", $0) }.joined(), size)
    }
    private func copyVerified(source: URL, destination: URL, expected: Item, temporary: URL, commit: () throws -> Void, progress: (Int64) throws -> Void) throws {
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard sourceAttributes[.modificationDate] as? Date == expected.modified else { throw MigrationFailure.changed }
        let fd = XCTOpenReadOnly(source.path); guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, XCTModeIsRegular(UInt32(before.st_mode)) != 0,
            before.st_size == expected.bytes, UInt64(before.st_ino) == expected.inode else { throw MigrationFailure.changed }
        let parent = destination.deletingLastPathComponent()
        prepareAccess(parent)
        let temp = temporary
        let cloned = preferCloning && XCTCloneFile(fd, temp.path) == 0
        if !cloned { guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) } }
        defer { try? fm.removeItem(at: temp) }
        let output = cloned ? nil : try FileHandle(forWritingTo: temp)
        let sourceDigest: (String, Int64)
        do { sourceDigest = try hash(fd, output: output, progress: progress); try output?.synchronize(); try output?.close() }
        catch { try? output?.close(); throw error }
        var after = stat(); var pathname = stat()
        guard fstat(fd, &after) == 0, lstat(source.path, &pathname) == 0,
              before.st_ino == pathname.st_ino, before.st_dev == pathname.st_dev,
              before.st_size == after.st_size, sourceDigest.1 == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw MigrationFailure.changed }
        let check = XCTOpenReadOnly(temp.path); guard check >= 0 else { throw CocoaError(.fileReadUnknown) }; defer { close(check) }
        let verified = try hash(check, output: nil, progress: { try progress(expected.bytes + $0) })
        guard verified == sourceDigest else { throw TransferError.corruptBackup }
        try Task.checkCancellation()
        try commit()
        guard rename(temp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Atomic per-file replacement; no preimage copy of the destination chat file.
    }
    private func expectedResult(source: Tree, target: Tree, mode: TransferMode) -> [String: Item] {
        var result = Dictionary(uniqueKeysWithValues: source.items.map { ($0.relative, $0) })
        if mode == .merge {
            let files = source.files.map(\.relative)
            for old in target.items where result[old.relative] == nil {
                if !files.contains(where: { $0.isEmpty || old.relative.hasPrefix($0 + "/") }) { result[old.relative] = old }
            }
        }
        return result
    }
    private func verifyShape(_ tree: Tree, expected: [String: Item]) throws {
        guard tree.items.count == expected.count else { throw MigrationFailure.changed }
        for actual in tree.items {
            guard let item = expected[actual.relative], item.directory == actual.directory, item.bytes == actual.bytes else { throw MigrationFailure.changed }
        }
    }
    public func migrate(source: AppInstance, target: AppInstance, mappings requestedMappings: [DirectoryMapping], mode requestedMode: TransferMode = .replace,
                        preferences: PreferencesService, systemVersion: String, deviceModel: String, allowOverwrite: Bool,
                        configurationID: UUID? = nil, resuming: UUID? = nil, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> MigrationReceipt {
        guard allowOverwrite else { throw TransferError.unavailable }
        var plan: ResumePlan
        let summary: MigrationSummary
        let sources: [Tree]
        var targets: [Tree]
        let mode: TransferMode
        let mappings: [DirectoryMapping]
        var receipt: MigrationReceipt
        if let id = resuming {
            plan = try readPlan(id)
            guard plan.source.bundleIdentifier == source.bundleIdentifier, plan.target.bundleIdentifier == target.bundleIdentifier,
                  plan.source.root.standardizedFileURL.path == source.root.standardizedFileURL.path, plan.target.root.standardizedFileURL.path == target.root.standardizedFileURL.path,
                  let saved = try history().first(where: { $0.id == id }), saved.state != "filesVerified" else { throw PathDiagnostic("续传核对任务身份", plan.source.root.path + " → " + plan.target.root.path, "应用标识、根目录或任务状态与原始记录不一致，未继续写入。") }
            receipt = saved; summary = plan.summary; sources = plan.sources; mode = summary.mode; mappings = summary.mappings
            targets = plan.targets
            try validate(source: source, target: target, mappings: mappings, allowMissingSource: true)
            if let path = try readTemporary(id) {
                let temp = try PathSafety.potential(path, in: target.root, prepareAccess: prepareAccess)
                guard temp.lastPathComponent.hasPrefix(".xct-" + id.uuidString + "-") else { throw MigrationFailure.changed }
                var info = stat()
                if lstat(temp.path, &info) == 0 {
                    guard XCTModeIsRegular(UInt32(info.st_mode)) != 0 else { throw MigrationFailure.changed }
                    try fm.removeItem(at: temp)
                } else if errno != ENOENT { throw MigrationFailure.changed }
                try persistTemporary(id, path: nil)
            }
            for (i, m) in mappings.enumerated() {
                let a = try tree(root: source.root, relative: m.source), b = try tree(root: target.root, relative: m.target)
                if let done = plan.completed[i] {
                    guard a.items == done[0].items, b.items == done[1].items else { throw PathDiagnostic("续传复查已完成映射", source.root.appendingPathComponent(m.source).path + " ⇄ " + target.root.appendingPathComponent(m.target).path, "已完成项目的目录结构、文件身份、大小或修改时间发生变化，未继续写入。") }
                } else if mode == .exchange {
                    if a.items == plan.targets[i].items && b.items == sources[i].items {
                        plan.completed[i] = [a, b] // Kernel swap/move happened before the completion journal.
                    } else {
                        guard a.items == sources[i].items, b.items == plan.targets[i].items else { throw PathDiagnostic("续传核对转换结果", m.source + " ⇄ " + m.target, "当前两边既不匹配原始状态，也不匹配已交换状态；不能确定结果，未重复交换。") }
                    }
                } else {
                    guard a.items == sources[i].items else { throw PathDiagnostic("续传复查源数据", source.root.appendingPathComponent(m.source).path, "源数据身份、大小、时间或目录内容与中断前记录不一致，未继续覆盖。") }
                    try validatePartial(source: sources[i], original: plan.targets[i], current: b,
                        sourceBase: source.root.appendingPathComponent(m.source), targetBase: target.root.appendingPathComponent(m.target), mode: mode)
                    targets[i] = b
                }
            }
            receipt.pendingExchange = nil
            receipt.completedFiles = 0; receipt.completedBytes = 0
            for i in plan.completed.keys {
                receipt.completedFiles += sources[i].files.count + (mode == .exchange ? plan.targets[i].files.count : 0)
                receipt.completedBytes += sources[i].files.reduce(0) { $0 + $1.bytes } + (mode == .exchange ? plan.targets[i].files.reduce(0) { $0 + $1.bytes } : 0)
            }
            try persistPlan(plan); try persist(receipt)
        } else {
            let fresh = try preflight(source: source, target: target, mappings: requestedMappings, mode: requestedMode)
            summary = fresh.0; sources = fresh.1; targets = fresh.2
            mode = summary.mode; mappings = summary.mappings
            plan = ResumePlan(source: source, target: target, summary: summary, sources: sources, targets: targets)
            receipt = MigrationReceipt(id: summary.id, created: Date(), sourceName: source.displayName, targetName: target.displayName,
                sourceBundleID: source.bundleIdentifier, targetBundleID: target.bundleIdentifier, state: "preflight",
                files: summary.files, bytes: summary.bytes, completedFiles: 0, completedBytes: 0, preferences: [], preferenceAbsences: [], mappings: mappings)
            receipt.operation = mode; receipt.configurationID = configurationID; receipt.resumable = true; receipt.exchanged = []
            try persistPlan(plan); try persist(receipt)
        }
        do {
            // Configuration snapshots are an independent manual action, never a migration prerequisite.
            progress(BackupProgress("复查所选数据", 0, summary.files, 0))
            for (i, m) in mappings.enumerated() where plan.completed[i] == nil {
                guard try tree(root: source.root, relative: m.source).items == sources[i].items,
                      try tree(root: target.root, relative: m.target).items == targets[i].items else { throw MigrationFailure.changed }
            }
            receipt.state = mode == .exchange ? "exchanging" : "transferring"; try persist(receipt)
            for (index, mapping) in mappings.enumerated() {
                try Task.checkCancellation()
                if plan.completed[index] != nil { continue }
                let sourceBase = try PathSafety.resolve(mapping.source, in: source.root, prepareAccess: prepareAccess)
                let targetBase = try PathSafety.potential(mapping.target, in: target.root, prepareAccess: prepareAccess)
                let original = Dictionary(uniqueKeysWithValues: targets[index].items.map { ($0.relative, $0) })
                if mode == .exchange {
                    try createParents(of: targetBase, in: target.root)
                    prepareAccess(sourceBase.deletingLastPathComponent()); prepareAccess(targetBase.deletingLastPathComponent())
                    guard try tree(root: source.root, relative: mapping.source).items == sources[index].items,
                          try tree(root: target.root, relative: mapping.target).items == targets[index].items else { throw MigrationFailure.changed }
                    receipt.pendingExchange = mapping; try persist(receipt); try Task.checkCancellation()
                    // One kernel operation per pair: no huge temporary chat copy or three-step rename gap.
                    let result = targets[index].items.isEmpty ? XCTMoveExclusive(sourceBase.path, targetBase.path) : XCTSwapPaths(sourceBase.path, targetBase.path)
                    guard result == 0 else { receipt.pendingExchange = nil; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    receipt.exchanged?.append(mapping); receipt.pendingExchange = nil; try persist(receipt)
                    guard try tree(root: target.root, relative: mapping.target).items == sources[index].items,
                          try tree(root: source.root, relative: mapping.source).items == targets[index].items else { throw MigrationFailure.changed }
                    receipt.completedFiles += sources[index].files.count + targets[index].files.count
                    receipt.completedBytes += sources[index].files.reduce(0) { $0 + $1.bytes } + targets[index].files.reduce(0) { $0 + $1.bytes }
                    plan.completed[index] = [try tree(root: source.root, relative: mapping.source), try tree(root: target.root, relative: mapping.target)]
                    try persistPlan(plan)
                    try persist(receipt); progress(BackupProgress("双向转换完成", receipt.completedFiles, summary.files, receipt.completedBytes, fraction: Double(index + 1) / Double(mappings.count))); continue
                }
                var replacedDirectories: Set<String> = []
                for item in sources[index].items {
                    try Task.checkCancellation()
                    let destination = try child(targetBase, item.relative)
                    try createParents(of: destination, in: target.root)
                    if item.directory {
                        if let old = original[item.relative], !old.directory {
                            try checkItem(old, at: destination); try fm.removeItem(at: destination)
                        }
                        if !fm.fileExists(atPath: destination.path) { prepareAccess(destination.deletingLastPathComponent()); try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
                        else { guard try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory else { throw MigrationFailure.changed } }
                    } else {
                        let file = try child(sourceBase, item.relative)
                        let done = receipt.completedBytes; let count = receipt.completedFiles
                        let old = original[item.relative]
                        if resuming != nil, old?.directory == false, old?.bytes == item.bytes, try equalContents(file, destination) {
                            receipt.completedFiles += 1; receipt.completedBytes += item.bytes; try persist(receipt)
                            progress(BackupProgress("已核验并跳过完成文件", receipt.completedFiles, summary.files, receipt.completedBytes,
                                fraction: summary.bytes > 0 ? min(0.98, Double(receipt.completedBytes) / Double(summary.bytes)) : nil))
                            continue
                        }
                        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".xct-" + receipt.id.uuidString + "-" + UUID().uuidString + ".partial")
                        try persistTemporary(receipt.id, path: String(temporary.path.dropFirst(target.root.path.count + 1)))
                        try copyVerified(source: file, destination: destination, expected: item, temporary: temporary, commit: {
                            try self.checkItem(old, at: destination)
                            if let old, old.directory {
                                let oldTree = try self.tree(root: target.root, relative: mapping.target + (item.relative.isEmpty ? "" : "/" + item.relative))
                                let prefix = item.relative.isEmpty ? "" : item.relative + "/"
                                let baseline = targets[index].items.filter { $0.relative == item.relative || $0.relative.hasPrefix(prefix) }.map { entry -> Item in
                                    var e = entry; e.relative = e.relative == item.relative ? "" : String(e.relative.dropFirst(prefix.count)); return e
                                }
                                guard oldTree.items == baseline else { throw MigrationFailure.changed }
                                try self.fm.removeItem(at: destination)
                            }
                        }) { bytes in
                            let free = try self.fm.attributesOfFileSystem(forPath: target.root.path)[.systemFreeSize] as? NSNumber
                            guard let free, free.int64Value > 8 * 1_048_576 else { throw MigrationFailure.insufficientSpace }
                            progress(BackupProgress("直接传输并校验", count, summary.files, done + min(bytes, item.bytes), fraction: summary.bytes > 0 ? min(0.98, Double(done * 2 + bytes) / Double(summary.bytes * 2)) : nil))
                        }
                        try persistTemporary(receipt.id, path: nil)
                        if old?.directory == true { replacedDirectories.insert(item.relative) }
                        receipt.completedFiles += 1; receipt.completedBytes += item.bytes; try persist(receipt)
                    }
                }
                guard try tree(root: source.root, relative: mapping.source).items == sources[index].items else { throw MigrationFailure.changed }
                let expected = expectedResult(source: sources[index], target: targets[index], mode: mode)
                if mode == .replace {
                    for old in targets[index].items.reversed() where !old.relative.isEmpty && expected[old.relative] == nil {
                        if replacedDirectories.contains(where: { $0.isEmpty || old.relative.hasPrefix($0 + "/") }) { continue }
                        try Task.checkCancellation()
                        let existing = try child(targetBase, old.relative); try checkItem(old, at: existing)
                        if old.directory { guard try fm.contentsOfDirectory(atPath: existing.path).isEmpty else { throw MigrationFailure.changed } }
                        try fm.removeItem(at: existing)
                    }
                }
                try verifyShape(tree(root: target.root, relative: mapping.target), expected: expected)
                plan.completed[index] = [try tree(root: source.root, relative: mapping.source), try tree(root: target.root, relative: mapping.target)]
                try persistPlan(plan)
            }
            receipt.state = "filesVerified"; try persist(receipt)
            progress(BackupProgress("文件操作校验完成", summary.files, summary.files, summary.bytes, fraction: 1)); return receipt
        } catch {
            receipt.state = error is CancellationError ? "cancelledPartial" : "failedPartial"
            try? persist(receipt); throw error
        }
    }
}
