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
    // Missing in older saved plans: their inventories were always complete.
    public var inventoryComplete: Bool? = nil
    public var keepSource: Bool? = nil
    public var preservesSource: Bool { mode != .exchange && (keepSource ?? true) }
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
    public var keepSource: Bool? = nil
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
    // Keep the strict snapshot comparison; report precisely why resuming was refused.
    private func inventoryDifference(expected: Tree, current: Tree) -> String {
        let before = Dictionary(uniqueKeysWithValues: expected.items.map { ($0.relative, $0) })
        let after = Dictionary(uniqueKeysWithValues: current.items.map { ($0.relative, $0) })
        var added = 0, removed = 0, changed = 0
        var examples: [String] = []
        for path in Set(before.keys).union(after.keys).sorted() {
            let label = path.isEmpty ? "（所选目录本身）" : path
            var detail: String?
            switch (before[path], after[path]) {
            case (nil, .some): added += 1; detail = "新增：" + label
            case (.some, nil): removed += 1; detail = "缺失：" + label
            case let (.some(old), .some(new)) where old != new:
                changed += 1
                var fields: [String] = []
                if old.directory != new.directory { fields.append("类型 \(old.directory ? "目录" : "文件") → \(new.directory ? "目录" : "文件")") }
                if old.bytes != new.bytes { fields.append("大小 \(old.bytes) → \(new.bytes) 字节") }
                if old.modified != new.modified { fields.append("修改时间戳 \(old.modified.timeIntervalSince1970) → \(new.modified.timeIntervalSince1970)") }
                if old.inode != new.inode { fields.append("inode \(old.inode) → \(new.inode)") }
                if old.device != new.device { fields.append("device \(old.device) → \(new.device)") }
                detail = "变化：" + label + " · " + fields.joined(separator: "；")
            default: break
            }
            if let detail, examples.count < 8 { examples.append(detail) }
        }
        return (["与中断前相比：新增 \(added) 项，缺失 \(removed) 项，变化 \(changed) 项（最多列出 8 项）。"] + examples +
            ["未继续覆盖。请先退出来源应用及其后台；若来源数据确实已更新，需要重新建立暂存任务。删除未完成记录前，请确认原应用中仍有完整数据；移动暂存可能已移走部分文件。"])
            .joined(separator: "\n")
    }
    private struct MoveStep: Codable {
        var source: String
        var target: String
        var originalSource: Tree
        var originalTarget: Tree
    }
    private struct ResumePlan: Codable {
        var source: AppInstance
        var target: AppInstance
        var summary: MigrationSummary
        var sources: [Tree]
        var targets: [Tree]
        var completed: [Int: [Tree]] = [:]
        var moves: [MoveStep]? = nil
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
    public func resumeStaging(_ taskID: UUID, recordID: UUID, stagingRoot: URL, source: AppInstance, target: AppInstance,
                              preferences: PreferencesService, diagnostic: @escaping @Sendable (String) -> Void = { _ in },
                              progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> MigrationReceipt {
        try await migrate(source: source, target: target, mappings: [], preferences: preferences, systemVersion: "", deviceModel: "",
                          allowOverwrite: true, resuming: taskID, stagingRecordID: recordID, stagingRoot: stagingRoot, diagnostic: diagnostic, progress: progress)
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
    private func tree(root: URL, relative: String, scanned: (Int) -> Void = { _ in }) throws -> Tree {
        prepareAccess(root); prepareAccess(root.appendingPathComponent(relative))
        let base = try PathSafety.potential(relative, in: root, prepareAccess: prepareAccess)
        var initial = stat()
        if lstat(base.path, &initial) != 0 {
            guard errno == ENOENT else { throw PathDiagnostic.system("读取文件树入口", base.path, code: errno) }
            return Tree(items: [])
        }
        var items: [Item] = []
        // Descendants are read relative to open directory descriptors. This avoids
        // resolving every ancestor and probing access again for every single file.
        // No-follow flags and inode checks keep symlink/replacement protection.
        func walk(_ url: URL, _ inside: String, parent: Int32 = AT_FDCWD, name: String? = nil) throws {
            try Task.checkCancellation()
            let entry = name ?? url.path
            var info = stat()
            var result = fstatat(parent, entry, &info, AT_SYMLINK_NOFOLLOW)
            if result != 0 && (errno == EACCES || errno == EPERM) {
                prepareAccess(url)
                result = fstatat(parent, entry, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { throw PathDiagnostic.system("扫描文件树", url.path, code: errno) }
            guard XCTModeIsSymlink(UInt32(info.st_mode)) == 0 else { throw PathDiagnostic("扫描文件树", url.path, "检测到符号链接；请取消选择该链接或缩小范围。") }
            let directory = XCTModeIsDirectory(UInt32(info.st_mode)) != 0
            let regular = XCTModeIsRegular(UInt32(info.st_mode)) != 0
            guard directory || regular else { throw PathDiagnostic("扫描文件类型", url.path, "不支持特殊文件。") }
            items.append(Item(relative: inside, directory: directory,
                bytes: regular ? Int64(info.st_size) : 0,
                modified: Date(timeIntervalSinceReferenceDate: Double(info.st_mtimespec.tv_sec) - 978_307_200 + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000), inode: UInt64(info.st_ino), device: Int32(info.st_dev)))
            scanned(items.count)
            if directory {
                var fd = XCTOpenDirectoryAt(parent, entry)
                if fd < 0 && (errno == EACCES || errno == EPERM) {
                    prepareAccess(url)
                    fd = XCTOpenDirectoryAt(parent, entry)
                }
                guard fd >= 0 else { throw PathDiagnostic.system("打开扫描目录", url.path, code: errno) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else {
                    close(fd); throw MigrationFailure.changed
                }
                guard let stream = fdopendir(fd) else {
                    let code = errno; close(fd); throw PathDiagnostic.system("枚举扫描目录", url.path, code: code)
                }
                defer { closedir(stream) }
                var names: [String] = []
                while true {
                    try Task.checkCancellation()
                    errno = 0
                    guard let record = readdir(stream) else {
                        guard errno == 0 else { throw PathDiagnostic.system("枚举扫描目录", url.path, code: errno) }
                        break
                    }
                    let childName = withUnsafePointer(to: &record.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if childName != "." && childName != ".." { names.append(childName) }
                }
                for childName in names.sorted() {
                    try walk(url.appendingPathComponent(childName), inside.isEmpty ? childName : inside + "/" + childName,
                             parent: fd, name: childName)
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
    private func preflight(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], mode: TransferMode, keepSource: Bool = true, taskID: UUID? = nil, progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> (MigrationSummary, [Tree], [Tree]) {
        try validate(source: source, target: target, mappings: mappings)
        var sources: [Tree] = []; var targets: [Tree] = []
        var total: Int64 = 0; var largest: Int64 = 0; var added: Int64 = 0
        var scannedTotal = 0
        var lastReport = Date.distantPast
        progress(BackupProgress("统计所选目录（不读取文件内容）", 0, 0, 0))
        for m in mappings {
            func scan(_ app: AppInstance, _ path: String) throws -> Tree {
                let result = try tree(root: app.root, relative: path) { count in
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        progress(BackupProgress("统计目录 · 已检查 \(scannedTotal + count) 项 · \(path)", 0, 0, 0))
                    }
                }
                scannedTotal += result.items.count
                return result
            }
            let s = try scan(source, m.source)
            let t = try scan(target, m.target)
            guard !s.items.isEmpty else { throw TransferError.invalidPath }
            let old = Dictionary(uniqueKeysWithValues: t.items.map { ($0.relative, $0) })
            for item in s.files {
                total += item.bytes; largest = max(largest, item.bytes)
                added += max(0, item.bytes - (old[item.relative]?.bytes ?? 0))
            }
            if mode == .exchange || !keepSource {
                var existing = try PathSafety.potential(m.target, in: target.root)
                while !fm.fileExists(atPath: existing.path) { existing.deleteLastPathComponent() }
                var info = stat()
                guard lstat(existing.path, &info) == 0, s.items[0].device == Int32(info.st_dev) else { throw MigrationFailure.exchangeUnsupported }
                if mode == .exchange { total += t.files.reduce(Int64(0)) { $0 + $1.bytes } }
            }
            sources.append(s); targets.append(t)
        }
        let available = try fm.attributesOfFileSystem(forPath: target.root.path)[.systemFreeSize] as? NSNumber
        let required = (mode == .exchange || !keepSource) ? 32 * 1_048_576 : added + largest + 32 * 1_048_576
        guard let available, available.int64Value > required else { throw MigrationFailure.insufficientSpace }
        let fileCount = sources.reduce(0) { $0 + $1.files.count } + (mode == .exchange ? targets.reduce(0) { $0 + $1.files.count } : 0)
        return (MigrationSummary(id: taskID ?? UUID(), sourceName: source.displayName, targetName: target.displayName,
            sourceBundleID: source.bundleIdentifier, targetBundleID: target.bundleIdentifier,
            files: fileCount, bytes: total, largestFile: largest, targetFiles: targets.reduce(0) { $0 + $1.files.count },
            mappings: mappings, targetPreferencesExist: false, mode: mode, keepSource: keepSource), sources, targets)
    }
    public func preview(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], mode: TransferMode = .replace, keepSource: Bool = true, detailed: Bool = true) throws -> MigrationSummary {
        if detailed { return try preflight(source: source, target: target, mappings: mappings, mode: mode, keepSource: keepSource).0 }
        // Confirmation checks selected roots and boundaries only. The full inventory and
        // exact space check run once on starting, before any file is changed.
        try Task.checkCancellation()
        try validate(source: source, target: target, mappings: mappings)
        return MigrationSummary(id: UUID(), sourceName: source.displayName, targetName: target.displayName,
            sourceBundleID: source.bundleIdentifier, targetBundleID: target.bundleIdentifier,
            files: 0, bytes: 0, largestFile: 0, targetFiles: 0, mappings: mappings,
            targetPreferencesExist: false, mode: mode, inventoryComplete: false, keepSource: keepSource)
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
    // Remove the receipt first: even if interrupted, the plan alone cannot be resumed.
    func deleteTask(_ id: UUID) throws {
        for url in [store.appendingPathComponent(id.uuidString + ".json"), planURL(id), temporaryJournalURL(id)] {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
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
    private func copyVerified(source: URL, destination: URL, expected: Item, temporary: URL, commit: () throws -> Void, progress: (Int64, Bool) throws -> Void) throws -> Bool {
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard sourceAttributes[.modificationDate] as? Date == expected.modified else { throw MigrationFailure.changed }
        let fd = XCTOpenReadOnly(source.path); guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, XCTModeIsRegular(UInt32(before.st_mode)) != 0,
            before.st_size == expected.bytes, UInt64(before.st_ino) == expected.inode else { throw MigrationFailure.changed }
        let parent = destination.deletingLastPathComponent()
        prepareAccess(parent)
        let temp = temporary
        var existingTemp = stat()
        guard lstat(temp.path, &existingTemp) != 0, errno == ENOENT else { throw MigrationFailure.conflict }
        let cloned = preferCloning && XCTCloneFile(fd, temp.path) == 0
        if !cloned { guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) } }
        defer { try? fm.removeItem(at: temp) }
        // A successful fclonefileat creates an independent COW snapshot, not a hard link.
        // Do not reread both entire files after the filesystem has already cloned them.
        var sourceDigest: (String, Int64)?
        if !cloned {
            let output = try FileHandle(forWritingTo: temp)
            do { sourceDigest = try hash(fd, output: output, progress: { try progress($0, false) }); try output.synchronize(); try output.close() }
            catch { try? output.close(); throw error }
        }
        var after = stat(); var pathname = stat()
        guard fstat(fd, &after) == 0, lstat(source.path, &pathname) == 0,
              before.st_ino == pathname.st_ino, before.st_dev == pathname.st_dev,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw MigrationFailure.changed }
        let check = XCTOpenReadOnly(temp.path); guard check >= 0 else { throw CocoaError(.fileReadUnknown) }; defer { close(check) }
        var copied = stat()
        guard fstat(check, &copied) == 0, XCTModeIsRegular(UInt32(copied.st_mode)) != 0,
              copied.st_size == before.st_size,
              copied.st_dev != before.st_dev || copied.st_ino != before.st_ino else { throw TransferError.corruptBackup }
        if let sourceDigest {
            let verified = try hash(check, output: nil, progress: { try progress(expected.bytes + $0, false) })
            guard verified == sourceDigest, sourceDigest.1 == before.st_size else { throw TransferError.corruptBackup }
        } else {
            try progress(expected.bytes * 2, true)
        }
        try Task.checkCancellation()
        try commit()
        guard rename(temp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Atomic per-file replacement; no preimage copy of the destination chat file.
        return cloned
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

    // Persist the immutable move list before touching either app. A rename preserves inode:
    // after interruption, source identity at the destination proves that step committed.
    private func executeMoves(plan: inout ResumePlan, receipt: inout MigrationReceipt,
                              diagnostic: @Sendable (String) -> Void,
                              progress: @Sendable (BackupProgress) -> Void) throws -> MigrationReceipt {
        func subtree(_ tree: Tree, _ positions: [String: Int], _ relative: String) -> Tree {
            guard let start = positions[relative] else { return Tree(items: []) }
            let prefix = relative.isEmpty ? "" : relative + "/"
            var end = start + 1
            while end < tree.items.count && (relative.isEmpty || tree.items[end].relative.hasPrefix(prefix)) { end += 1 }
            return Tree(items: tree.items[start..<end].map {
                var item = $0
                item.relative = item.relative == relative ? "" : String(item.relative.dropFirst(prefix.count))
                return item
            })
        }
        if plan.moves == nil {
            var steps: [MoveStep] = []
            for (i, mapping) in plan.summary.mappings.enumerated() {
                let src = plan.sources[i], dst = plan.targets[i]
                let targetItems = Dictionary(uniqueKeysWithValues: dst.items.map { ($0.relative, $0) })
                let sourcePositions = Dictionary(uniqueKeysWithValues: src.items.enumerated().map { ($0.element.relative, $0.offset) })
                let targetPositions = Dictionary(uniqueKeysWithValues: dst.items.enumerated().map { ($0.element.relative, $0.offset) })
                var covered: String?
                for item in src.items {
                    if let prior = covered, prior.isEmpty || item.relative == prior || item.relative.hasPrefix(prior + "/") { continue }
                    if plan.summary.mode == .merge && item.directory && targetItems[item.relative]?.directory == true { continue }
                    let suffix = item.relative.isEmpty ? "" : "/" + item.relative
                    steps.append(MoveStep(source: mapping.source + suffix, target: mapping.target + suffix,
                                          originalSource: subtree(src, sourcePositions, item.relative), originalTarget: subtree(dst, targetPositions, item.relative)))
                    covered = item.relative
                }
            }
            plan.moves = steps
            try persistPlan(plan)
        }
        func matches(_ expected: Tree, _ actual: Tree, partial: Bool = false) -> Bool {
            let originals = Dictionary(uniqueKeysWithValues: expected.items.map { ($0.relative, $0) })
            if !partial && expected.items.count != actual.items.count { return false }
            return actual.items.allSatisfy { item in
                guard let old = originals[item.relative] else { return false }
                if item.directory {
                    return old.directory && old.inode == item.inode && old.device == item.device
                }
                return old == item
            }
        }
        // Validate before deleting, then unlink known entries one by one. No recursive
        // removeItem on a partially consumed directory: unexpected content must stop us.
        func removeKnown(_ original: Tree, root: URL, relative: String) throws {
            let current = try tree(root: root, relative: relative)
            guard matches(original, current, partial: true) else { throw MigrationFailure.changed }
            for item in current.items.reversed() {
                try Task.checkCancellation()
                let url = try PathSafety.resolve(relative + (item.relative.isEmpty ? "" : "/" + item.relative), in: root)
                try checkItem(item, at: url)
                let result = item.directory ? rmdir(url.path) : unlink(url.path)
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        receipt.completedFiles = 0; receipt.completedBytes = 0
        receipt.state = "moving"; try persist(receipt)
        var lastSave = Date()
        for step in plan.moves ?? [] {
            try Task.checkCancellation()
            let sourceBase = try PathSafety.potential(step.source, in: plan.source.root)
            let targetBase = try PathSafety.potential(step.target, in: plan.target.root)
            var a = try tree(root: plan.source.root, relative: step.source)
            var b = try tree(root: plan.target.root, relative: step.target)
            if !matches(step.originalSource, b) {
                guard matches(step.originalSource, a), matches(step.originalTarget, b) else {
                    throw PathDiagnostic("续传核对移动", step.source + " → " + step.target, "当前文件身份与移动任务不一致，未继续覆盖。")
                }
                try createParents(of: targetBase, in: plan.target.root)
                let result = b.items.isEmpty ? XCTMoveExclusive(sourceBase.path, targetBase.path) : XCTSwapPaths(sourceBase.path, targetBase.path)
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                diagnostic("直接移动已提交 · " + step.source + " → " + step.target)
                a = try tree(root: plan.source.root, relative: step.source)
                b = try tree(root: plan.target.root, relative: step.target)
                guard matches(step.originalSource, b) else { throw MigrationFailure.changed }
            }
            // After a swap, only the original destination remains at the old source.
            // A crash during cleanup is recoverable from this same immutable step.
            guard matches(step.originalTarget, a, partial: true) else { throw MigrationFailure.changed }
            if !a.items.isEmpty { try removeKnown(step.originalTarget, root: plan.source.root, relative: step.source) }
            receipt.completedFiles += step.originalSource.files.count
            receipt.completedBytes += step.originalSource.files.reduce(0) { $0 + $1.bytes }
            progress(BackupProgress("直接移动文件", receipt.completedFiles, receipt.files, receipt.completedBytes,
                                    fraction: receipt.files == 0 ? 0 : Double(receipt.completedFiles) / Double(receipt.files)))
            if Date().timeIntervalSince(lastSave) >= 1 { try persist(receipt); lastSave = Date() }
        }
        // Merge leaves only shared source directories, now empty. Remove those without
        // touching any newly created file. Directory timestamps naturally changed.
        for (i, mapping) in plan.summary.mappings.enumerated() {
            let remaining = try tree(root: plan.source.root, relative: mapping.source)
            guard matches(plan.sources[i], remaining, partial: true), remaining.files.isEmpty else { throw MigrationFailure.changed }
            if !remaining.items.isEmpty { try removeKnown(plan.sources[i], root: plan.source.root, relative: mapping.source) }
            let target = try tree(root: plan.target.root, relative: mapping.target)
            try verifyShape(target, expected: expectedResult(source: plan.sources[i], target: plan.targets[i], mode: plan.summary.mode))
        }
        receipt.state = "filesVerified"; try persist(receipt)
        progress(BackupProgress("移动完成", receipt.files, receipt.files, receipt.bytes, fraction: 1))
        return receipt
    }

    public func migrate(source: AppInstance, target: AppInstance, mappings requestedMappings: [DirectoryMapping], mode requestedMode: TransferMode = .replace, keepSource: Bool = true,
                        preferences: PreferencesService, systemVersion: String, deviceModel: String, allowOverwrite: Bool,
                        configurationID: UUID? = nil, resuming: UUID? = nil, taskID: UUID? = nil,
                        stagingRecordID: UUID? = nil, stagingRoot: URL? = nil,
                        diagnostic: @escaping @Sendable (String) -> Void = { _ in }, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> MigrationReceipt {
        guard allowOverwrite else { throw TransferError.unavailable }
        let started = Date()
        var phase = "统计与准备"
        var phaseStart = started
        func finishPhase() {
            diagnostic("迁移耗时 · \(phase) · \(String(format: "%.2f", Date().timeIntervalSince(phaseStart))) 秒")
        }
        defer { diagnostic("迁移总耗时 · \(String(format: "%.2f", Date().timeIntervalSince(started))) 秒") }
        func monitoredTree(root: URL, relative: String) throws -> Tree {
            var lastReport = Date.distantPast
            return try tree(root: root, relative: relative) { count in
                let now = Date()
                if now.timeIntervalSince(lastReport) >= 0.25 {
                    lastReport = now
                    progress(BackupProgress(phase + " · 已检查 \(count) 项", 0, 0, 0))
                }
            }
        }
        var plan: ResumePlan
        var summary: MigrationSummary
        var sources: [Tree]
        var targets: [Tree]
        let mode: TransferMode
        let mappings: [DirectoryMapping]
        var receipt: MigrationReceipt
        if let id = resuming {
            plan = try readPlan(id)
            var rebasedStagingRoot = false
            var refreshCopyStaging = false
            if let stagingRecordID, let stagingRoot {
                let stagingAppID = "staging-" + stagingRecordID.uuidString
                let modern = try PathSafety.potential(".records/" + stagingRecordID.uuidString + ".json", in: stagingRoot)
                let metadata = fm.fileExists(atPath: modern.path) ? modern : try PathSafety.resolve(stagingRecordID.uuidString + "/record.json", in: stagingRoot)
                let record = try JSONDecoder().decode(StagedData.self, from: Data(contentsOf: metadata))
                guard record.id == stagingRecordID else { throw TransferError.corruptBackup }
                let directoryName = record.directoryName ?? stagingRecordID.uuidString
                guard !directoryName.contains("/"), !directoryName.hasPrefix(".") else { throw TransferError.corruptBackup }
                let relative = directoryName + (record.directoryName == nil ? "/payload" : "")
                let currentDataRoot = try PathSafety.resolve(relative, in: stagingRoot)
                let expectedSuffix = ["Documents", "数据暂存"] + relative.split(separator: "/").map(String.init)
                func priorPathMatches(_ saved: URL) -> Bool {
                    Array(saved.standardizedFileURL.pathComponents.suffix(expectedSuffix.count)) == expectedSuffix
                }
                if plan.source.id == stagingAppID {
                    guard source.id == stagingAppID, priorPathMatches(plan.source.root), source.root.resolvingSymlinksInPath().standardizedFileURL == currentDataRoot else {
                        throw PathDiagnostic("续传核对暂存来源", plan.source.root.path, "暂存记录 ID 或目录不匹配，拒绝重定向任务来源。")
                    }
                    plan.source.root = currentDataRoot; rebasedStagingRoot = true
                }
                if plan.target.id == stagingAppID {
                    guard target.id == stagingAppID, priorPathMatches(plan.target.root), target.root.resolvingSymlinksInPath().standardizedFileURL == currentDataRoot else {
                        throw PathDiagnostic("续传核对暂存目标", plan.target.root.path, "暂存记录 ID 或目录不匹配，拒绝重定向任务目标。")
                    }
                    plan.target.root = currentDataRoot; rebasedStagingRoot = true
                    // This destination is the owned, incomplete copy staging area. Resume
                    // against today's source; never apply this to moves or external targets.
                    refreshCopyStaging = record.keepSource && record.state == .incoming && plan.summary.mode == .replace
                        && record.application.bundleIdentifier == source.bundleIdentifier
                        && record.incomingTask == id
                }
                guard rebasedStagingRoot else {
                    throw PathDiagnostic("续传核对暂存身份", plan.source.root.path + " → " + plan.target.root.path, "原任务不包含此暂存记录，拒绝重定向。")
                }
            }
            func sameRoot(_ a: URL, _ b: URL) -> Bool {
                a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
            }
            guard plan.source.bundleIdentifier == source.bundleIdentifier, plan.target.bundleIdentifier == target.bundleIdentifier,
                  sameRoot(plan.source.root, source.root), sameRoot(plan.target.root, target.root),
                  let saved = try history().first(where: { $0.id == id }), saved.state != "filesVerified" else {
                let reason: String
                if plan.source.bundleIdentifier != source.bundleIdentifier || plan.target.bundleIdentifier != target.bundleIdentifier { reason = "应用标识与原任务不一致。" }
                else if !sameRoot(plan.source.root, source.root) || !sameRoot(plan.target.root, target.root) { reason = "应用目录与原任务不一致；系统解析后的路径也不同。\n当前来源：\(source.root.path)\n当前目标：\(target.root.path)" }
                else { reason = "任务日志不存在或任务已经完成。" }
                throw PathDiagnostic("续传核对任务身份", plan.source.root.path + " → " + plan.target.root.path, reason + "未继续写入。")
            }
            if rebasedStagingRoot { try persistPlan(plan) }
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
            if refreshCopyStaging {
                phase = "按当前来源继续暂存"
                var currentSources: [Tree] = [], currentTargets: [Tree] = []
                for mapping in mappings {
                    currentSources.append(try monitoredTree(root: source.root, relative: mapping.source))
                    currentTargets.append(try monitoredTree(root: target.root, relative: mapping.target))
                }
                let files = currentSources.flatMap(\.files)
                summary = MigrationSummary(id: summary.id, sourceName: summary.sourceName, targetName: summary.targetName,
                    sourceBundleID: summary.sourceBundleID, targetBundleID: summary.targetBundleID,
                    files: files.count, bytes: files.reduce(0) { $0 + $1.bytes }, largestFile: files.map(\.bytes).max() ?? 0,
                    targetFiles: currentTargets.reduce(0) { $0 + $1.files.count }, mappings: mappings,
                    targetPreferencesExist: summary.targetPreferencesExist, mode: mode, inventoryComplete: true)
                sources = currentSources; targets = currentTargets
                plan.sources = sources; plan.targets = targets; plan.summary = summary; plan.completed = [:]
                receipt.files = summary.files; receipt.bytes = summary.bytes
                diagnostic("续传策略 · 按当前来源继续暂存；相同内容跳过，变化文件重传，新增文件补传，已从来源删除的项目按替换规则清理暂存副本。")
            }
            for (i, m) in mappings.enumerated() {
                if refreshCopyStaging || (summary.keepSource == false && mode != .exchange) { break }
                let a = try monitoredTree(root: source.root, relative: m.source), b = try monitoredTree(root: target.root, relative: m.target)
                if let done = plan.completed[i] {
                    guard a.items == done[0].items, b.items == done[1].items else { throw PathDiagnostic("续传复查已完成映射", source.root.appendingPathComponent(m.source).path + " ⇄ " + target.root.appendingPathComponent(m.target).path, "已完成项目的目录结构、文件身份、大小或修改时间发生变化，未继续写入。") }
                } else if mode == .exchange {
                    if a.items == plan.targets[i].items && b.items == sources[i].items {
                        plan.completed[i] = [a, b] // Kernel swap/move happened before the completion journal.
                    } else {
                        guard a.items == sources[i].items, b.items == plan.targets[i].items else { throw PathDiagnostic("续传核对转换结果", m.source + " ⇄ " + m.target, "当前两边既不匹配原始状态，也不匹配已交换状态；不能确定结果，未重复交换。") }
                    }
                } else {
                    guard a.items == sources[i].items else { throw PathDiagnostic("续传复查源数据", source.root.appendingPathComponent(m.source).path, inventoryDifference(expected: sources[i], current: a)) }
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
            if let taskID, try history().contains(where: { $0.id == taskID }) { throw MigrationFailure.conflict }
            let fresh = try preflight(source: source, target: target, mappings: requestedMappings, mode: requestedMode, keepSource: keepSource, taskID: taskID, progress: progress)
            summary = fresh.0; sources = fresh.1; targets = fresh.2
            mode = summary.mode; mappings = summary.mappings
            plan = ResumePlan(source: source, target: target, summary: summary, sources: sources, targets: targets)
            receipt = MigrationReceipt(id: summary.id, created: Date(), sourceName: source.displayName, targetName: target.displayName,
                sourceBundleID: source.bundleIdentifier, targetBundleID: target.bundleIdentifier, state: "preflight",
                files: summary.files, bytes: summary.bytes, completedFiles: 0, completedBytes: 0, preferences: [], preferenceAbsences: [], mappings: mappings)
            receipt.keepSource = summary.keepSource
            receipt.operation = mode; receipt.configurationID = configurationID; receipt.resumable = true; receipt.exchanged = []
            try persistPlan(plan); try persist(receipt)
        }
        do {
            if summary.keepSource == false && mode != .exchange {
                return try executeMoves(plan: &plan, receipt: &receipt, diagnostic: diagnostic, progress: progress)
            }
            // Configuration snapshots are an independent manual action, never a migration prerequisite.
            finishPhase()
            progress(BackupProgress("复查所选数据", 0, summary.files, 0))
            receipt.state = mode == .exchange ? "exchanging" : "transferring"; try persist(receipt)
            var lastReceiptSave = Date.distantPast
            var lastUIUpdate = Date.distantPast
            var lastSpaceCheck = Date.distantPast
            var pendingCopyPath: String?
            var clonedFiles = 0
            var copiedFiles = 0
            defer { diagnostic("复制路径统计 · 系统克隆 \(clonedFiles) 个 · 普通复制并 SHA-256 校验 \(copiedFiles) 个") }
            func saveCopyProgress(force: Bool = false) throws {
                if force || Date().timeIntervalSince(lastReceiptSave) >= 1 {
                    try persist(receipt); lastReceiptSave = Date()
                }
            }
            for (index, mapping) in mappings.enumerated() {
                try Task.checkCancellation()
                if plan.completed[index] != nil { continue }
                let sourceBase = try PathSafety.resolve(mapping.source, in: source.root, prepareAccess: prepareAccess)
                let targetBase = try PathSafety.potential(mapping.target, in: target.root, prepareAccess: prepareAccess)
                phase = "映射 \(index + 1) 执行前复查 · \(mapping.source)"
                phaseStart = Date()
                progress(BackupProgress(phase, receipt.completedFiles, summary.files, receipt.completedBytes))
                guard try monitoredTree(root: source.root, relative: mapping.source).items == sources[index].items,
                      try monitoredTree(root: target.root, relative: mapping.target).items == targets[index].items else { throw MigrationFailure.changed }
                finishPhase()
                phase = "映射 \(index + 1) · \(mode.title)及结果校验"
                phaseStart = Date()
                let original = Dictionary(uniqueKeysWithValues: targets[index].items.map { ($0.relative, $0) })
                if mode == .exchange {
                    try createParents(of: targetBase, in: target.root)
                    prepareAccess(sourceBase.deletingLastPathComponent()); prepareAccess(targetBase.deletingLastPathComponent())
                    receipt.pendingExchange = mapping; try persist(receipt); try Task.checkCancellation()
                    // One kernel operation per pair: no huge temporary chat copy or three-step rename gap.
                    let result = targets[index].items.isEmpty ? XCTMoveExclusive(sourceBase.path, targetBase.path) : XCTSwapPaths(sourceBase.path, targetBase.path)
                    guard result == 0 else { receipt.pendingExchange = nil; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    receipt.exchanged?.append(mapping); receipt.pendingExchange = nil; try persist(receipt)
                    let afterSource = try monitoredTree(root: source.root, relative: mapping.source)
                    let afterTarget = try monitoredTree(root: target.root, relative: mapping.target)
                    guard afterTarget.items == sources[index].items,
                          afterSource.items == targets[index].items else { throw MigrationFailure.changed }
                    receipt.completedFiles += sources[index].files.count + targets[index].files.count
                    receipt.completedBytes += sources[index].files.reduce(0) { $0 + $1.bytes } + targets[index].files.reduce(0) { $0 + $1.bytes }
                    plan.completed[index] = [afterSource, afterTarget]
                    finishPhase()
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
                            receipt.completedFiles += 1; receipt.completedBytes += item.bytes; try saveCopyProgress()
                            progress(BackupProgress("已核验并跳过完成文件", receipt.completedFiles, summary.files, receipt.completedBytes,
                                fraction: summary.bytes > 0 ? min(0.98, Double(receipt.completedBytes) / Double(summary.bytes)) : nil))
                            continue
                        }
                        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".xct-" + receipt.id.uuidString + "-copy.partial")
                        let relativeTemporary = String(temporary.path.dropFirst(target.root.path.count + 1))
                        // A serial copy reuses one temporary name per directory. Commit its
                        // recovery location before use, once per directory rather than per file.
                        if pendingCopyPath != relativeTemporary {
                            try persistTemporary(receipt.id, path: relativeTemporary)
                            pendingCopyPath = relativeTemporary
                        }
                        let cloned = try copyVerified(source: file, destination: destination, expected: item, temporary: temporary, commit: {
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
                        }) { bytes, cloned in
                            let now = Date()
                            if now.timeIntervalSince(lastSpaceCheck) >= 1 {
                                let free = try self.fm.attributesOfFileSystem(forPath: target.root.path)[.systemFreeSize] as? NSNumber
                                guard let free, free.int64Value > 8 * 1_048_576 else { throw MigrationFailure.insufficientSpace }
                                lastSpaceCheck = now
                            }
                            if count <= 1 || now.timeIntervalSince(lastUIUpdate) >= 0.2 {
                                let bytePart = summary.bytes > 0 ? Double(done) / Double(summary.bytes) + Double(bytes) / (2 * Double(summary.bytes)) : 0
                                let filePart = summary.files > 0 ? Double(count) / Double(summary.files) : 0
                                progress(BackupProgress(cloned ? "系统快速复制 · 核对文件身份" : "复制并校验文件内容", count, summary.files, done + min(bytes, item.bytes), fraction: min(0.98, summary.bytes > 0 ? (bytePart + filePart) / 2 : filePart)))
                                lastUIUpdate = now
                            }
                        }
                        if cloned { clonedFiles += 1 } else { copiedFiles += 1 }
                        // Keep the last pending path until the next file; after rename it no longer
                        // exists. Resume already handles ENOENT and rechecks actual file contents.
                        if old?.directory == true { replacedDirectories.insert(item.relative) }
                        receipt.completedFiles += 1; receipt.completedBytes += item.bytes
                        try saveCopyProgress()
                    }
                }
                try persistTemporary(receipt.id, path: nil)
                pendingCopyPath = nil
                try saveCopyProgress(force: true)
                let afterSource = try monitoredTree(root: source.root, relative: mapping.source)
                guard afterSource.items == sources[index].items else { throw MigrationFailure.changed }
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
                let afterTarget = try monitoredTree(root: target.root, relative: mapping.target)
                try verifyShape(afterTarget, expected: expected)
                plan.completed[index] = [afterSource, afterTarget]
                finishPhase()
                try persistPlan(plan)
            }
            receipt.state = "filesVerified"; try persist(receipt)
            progress(BackupProgress("文件操作校验完成", summary.files, summary.files, summary.bytes, fraction: 1)); return receipt
        } catch {
            diagnostic("迁移停止阶段 · \(phase) · \(String(describing: error))")
            finishPhase()
            receipt.state = error is CancellationError ? "cancelledPartial" : "failedPartial"
            try? persist(receipt); throw error
        }
    }
}
