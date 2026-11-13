import Foundation
#if canImport(CSupport)
import CSupport
#endif
import Darwin

public struct PendingConfigurationBackup: Identifiable, Codable, Sendable {
    public var id: UUID
    public var instance: AppInstance
    public var selections: [String]
    public var plistOnly: Bool
    public var systemVersion: String
    public var deviceModel: String
}
public actor BackupService {
    public let store: URL
    private let fm = FileManager.default
    private let prepareAccess: @Sendable (URL) -> Void
    public init(store: URL, prepareAccess: @escaping @Sendable (URL) -> Void = { _ in }) { self.store = store; self.prepareAccess = prepareAccess }

    private struct Inventory: Equatable, Codable {
        var files: [String: FileRecord] = [:]
        var directories: [String] = []
    }
    private struct BackupPlan: Codable { var task: PendingConfigurationBackup; var before: Inventory }
    public func pending() throws -> [PendingConfigurationBackup] {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        var result: [PendingConfigurationBackup] = []
        for dir in try fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) {
            guard dir.pathExtension == "partial",
                  UUID(uuidString: dir.deletingPathExtension().lastPathComponent) != nil else { continue }
            let url = dir.appendingPathComponent("plan.json")
            guard let data = try? Data(contentsOf: url),
                  let plan = try? JSONDecoder().decode(BackupPlan.self, from: data),
                  dir.lastPathComponent == plan.task.id.uuidString + ".partial" else { continue }
            result.append(plan.task)
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func resume(_ id: UUID, instance: AppInstance, progress: @escaping @Sendable (BackupProgress) -> Void) throws -> BackupManifest {
        let stage = try PathSafety.resolve(id.uuidString + ".partial", in: store)
        let plan = try JSONDecoder().decode(BackupPlan.self, from: Data(contentsOf: PathSafety.resolve("plan.json", in: stage)))
        guard plan.task.instance.root.standardizedFileURL.path == instance.root.standardizedFileURL.path, plan.task.instance.bundleIdentifier == instance.bundleIdentifier else { throw TransferError.changedSource }
        return try create(instance: instance, selections: plan.task.selections, systemVersion: plan.task.systemVersion,
                          deviceModel: plan.task.deviceModel, plistOnly: plan.task.plistOnly, resuming: id, progress: progress)
    }
    private func inventory(root: URL, selections: [String], hashes: Bool, plistOnly: Bool = false, onHashBytes: ((Int64) -> Void)? = nil) throws -> Inventory {
        var result = Inventory(); var hashedBytes: Int64 = 0
        func walk(_ path: String) throws {
            try Task.checkCancellation()
            prepareAccess(root.appendingPathComponent(path))
            let url = try PathSafety.resolve(path, in: root, prepareAccess: prepareAccess)
            let a = try fm.attributesOfItem(atPath: url.path)
            switch a[.type] as? FileAttributeType {
            case .typeDirectory:
                result.directories.append(path)
                guard let dir = opendir(url.path) else { throw PathDiagnostic.system("列出配置目录", url.path, code: errno) }
                var children: [(String, UInt8)] = []
                defer { closedir(dir) }
                while true {
                    errno = 0
                    guard let entry = readdir(dir) else {
                        if errno != 0 { throw PathDiagnostic.system("列出配置目录", url.path, code: errno) }
                        break
                    }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
                    if name != "." && name != ".." { children.append((name, entry.pointee.d_type)) }
                }
                for (name, entryType) in children.sorted(by: { $0.0 < $1.0 }) {
                    if plistOnly && !name.lowercased().hasSuffix(".plist") && entryType != DT_DIR {
                        if entryType != DT_UNKNOWN { continue }
                        var info = stat(); let child = url.appendingPathComponent(name); prepareAccess(child)
                        guard lstat(child.path, &info) == 0 else { throw PathDiagnostic.system("识别配置目录项", child.path, code: errno) }
                        if XCTModeIsDirectory(UInt32(info.st_mode)) == 0 { continue }
                    }
                    try walk(path + "/" + name)
                }
            case .typeRegular:
                if plistOnly && !path.lowercased().hasSuffix(".plist") { return }
                let bytes = (a[.size] as? NSNumber)?.int64Value ?? 0
                let base = hashedBytes
                let digest = hashes ? try stream(url, destination: nil, onBytes: { onHashBytes?(base + $0) }) : ""
                if hashes { hashedBytes += bytes }
                result.files[path] = FileRecord(path: path, bytes: bytes, modified: a[.modificationDate] as? Date ?? .distantPast, sha256: digest)
            default: throw TransferError.unsupportedFile
            }
        }
        for s in selections.sorted() { try walk(s) }
        if plistOnly {
            // Keep selected roots and only the ancestor folders of matching files.
            var keep = Set(selections)
            for file in result.files.keys {
                var parts = file.split(separator: "/"); parts.removeLast()
                while !parts.isEmpty { keep.insert(parts.joined(separator: "/")); parts.removeLast() }
            }
            result.directories = result.directories.filter { keep.contains($0) }
        }
        result.directories.sort()
        return result
    }
    // No-follow descriptor, constant memory, source identity/timestamp checks, durable destination.
    private func stream(_ source: URL, destination: URL?, onBytes: ((Int64) throws -> Void)? = nil) throws -> String {
        prepareAccess(source)
        let fd = XCTOpenReadOnly(source.path)
        guard fd >= 0 else { throw PathDiagnostic.system("读取配置文件", source.path, code: errno) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(); guard fstat(fd, &before) == 0, XCTModeIsRegular(UInt32(before.st_mode)) != 0 else { throw TransferError.unsupportedFile }
        var output: FileHandle?
        if let destination {
            if XCTCloneFile(fd, destination.path) != 0 {
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                output = try FileHandle(forWritingTo: destination)
            }
        }
        defer { try? output?.close() }
        var hash = CC_SHA256_CTX(); CC_SHA256_Init(&hash); var count: Int64 = 0; var lastUpdate = Date.distantPast
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 4 * 1_048_576) ?? Data()
            if data.isEmpty { break }
            data.withUnsafeBytes { buffer in _ = CC_SHA256_Update(&hash, buffer.baseAddress, CC_LONG(buffer.count)) }; try output?.write(contentsOf: data)
            count += Int64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.2 { lastUpdate = Date(); try onBytes?(count) }
        }
        try onBytes?(count)
        try output?.synchronize()
        var after = stat(); var pathState = stat()
        guard fstat(fd, &after) == 0, lstat(source.path, &pathState) == 0,
              before.st_dev == pathState.st_dev, before.st_ino == pathState.st_ino,
              before.st_size == after.st_size, count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw TransferError.changedSource }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &hash)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private func checkSpace(_ bytes: Int64) throws {
        let info = try fm.attributesOfFileSystem(forPath: store.path)
        let free = (info[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard bytes >= 0, free > bytes, free - bytes > 32 * 1_048_576 else { throw TransferError.insufficientSpace }
    }
    public func create(instance: AppInstance, selections: [String], systemVersion: String, deviceModel: String, plistOnly: Bool = false, resuming: UUID? = nil,
                       progress: @escaping @Sendable (BackupProgress) -> Void) throws -> BackupManifest {
        let source = instance.root.resolvingSymlinksInPath()
        let canonicalStore = store.resolvingSymlinksInPath()
        guard !canonicalStore.path.hasPrefix(source.path + "/"), canonicalStore != source else { throw TransferError.invalidPath }
        try PathSafety.validateSelections(selections, root: source, prepareAccess: prepareAccess)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let id = resuming ?? UUID(); let stage = try PathSafety.potential(id.uuidString + ".partial", in: store)
        let payload = stage.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        func journal(_ state: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["taskID": id.uuidString, "state": state, "updated": ISO8601DateFormatter().string(from: Date())], options: [.sortedKeys])
            try DurableJournal.write(data, to: stage.appendingPathComponent("journal.json"))
        }
        do {
            try journal("inventory"); progress(BackupProgress("检查目录与空间", 0, 0, 0))
            let before = try inventory(root: source, selections: selections, hashes: false, plistOnly: plistOnly)
            if plistOnly && before.files.isEmpty { throw PathDiagnostic("备份 plist 配置", selections.joined(separator: ";"), "所选配置目录及子目录没有 .plist 文件。") }
            let planURL = stage.appendingPathComponent("plan.json")
            if resuming != nil {
                let old = try JSONDecoder().decode(BackupPlan.self, from: Data(contentsOf: planURL))
                guard old.before == before, old.task.instance.root.standardizedFileURL.path == instance.root.standardizedFileURL.path, old.task.instance.bundleIdentifier == instance.bundleIdentifier else { throw TransferError.changedSource }
            } else {
                let task = PendingConfigurationBackup(id: id, instance: instance, selections: selections, plistOnly: plistOnly, systemVersion: systemVersion, deviceModel: deviceModel)
                try DurableJournal.write(JSONEncoder().encode(BackupPlan(task: task, before: before)), to: planURL)
            }
            let totalBytes = before.files.values.reduce(Int64(0)) { $0 + $1.bytes }
            try checkSpace(totalBytes)
            for d in before.directories { try fm.createDirectory(at: payload.appendingPathComponent(d), withIntermediateDirectories: true) }
            try journal("copying")
            var files: [FileRecord] = []; var doneBytes: Int64 = 0
            for p in before.files.keys.sorted() {
                try Task.checkCancellation()
                var record = before.files[p]!
                let sourceFile = try PathSafety.resolve(p, in: source, prepareAccess: prepareAccess)
                let baseBytes = doneBytes; let doneCount = files.count; let count = before.files.count
                let destination = try PathSafety.potential(p, in: payload)
                if resuming != nil && fm.fileExists(atPath: destination.path) {
                    let sourceHash = try stream(sourceFile, destination: nil)
                    if try stream(destination, destination: nil) == sourceHash {
                        record.sha256 = sourceHash; files.append(record); doneBytes += record.bytes
                        progress(BackupProgress("已核验并跳过完成配置", files.count, before.files.count, doneBytes,
                            fraction: totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) / 3 : nil))
                        continue
                    }
                }
                record.sha256 = try stream(sourceFile, destination: payload.appendingPathComponent(p)) { bytes in
                    try self.checkSpace(0)
                    progress(BackupProgress("复制配置与 SHA-256", doneCount, count, baseBytes + bytes, fraction: totalBytes > 0 ? Double(baseBytes + bytes) / Double(totalBytes) / 3 : nil))
                }
                files.append(record); doneBytes += record.bytes
                progress(BackupProgress("复制配置与 SHA-256", files.count, before.files.count, doneBytes, fraction: totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) / 3 : nil))
            }
            try journal("checking-source"); progress(BackupProgress("复查源数据一致性", files.count, files.count, doneBytes, fraction: 1.0 / 3))
            let after = try inventory(root: source, selections: selections, hashes: true, plistOnly: plistOnly) { processed in
                progress(BackupProgress("复查源数据 SHA-256", files.count, files.count, doneBytes,
                    fraction: totalBytes > 0 ? Double(totalBytes + processed) / Double(totalBytes) / 3 : nil))
            }
            guard before.directories == after.directories, Set(before.files.keys) == Set(after.files.keys) else { throw TransferError.changedSource }
            for f in files { guard after.files[f.path] == f else { throw TransferError.changedSource } }
            var identity = instance; identity.root = URL(fileURLWithPath: "/"); identity.bookmark = nil
            var manifest = BackupManifest(id: id, instance: identity, created: Date(), systemVersion: systemVersion,
                                          deviceModel: deviceModel, selections: selections.sorted(), directories: before.directories, files: files)
            manifest.plistOnly = plistOnly
            try journal("verifying")
            progress(BackupProgress("校验备份副本", files.count, files.count, doneBytes, fraction: 2.0 / 3))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            let checksums = files.map { "\($0.sha256)  \($0.path)" }.joined(separator: "\n") + "\n"
            try checksums.write(to: stage.appendingPathComponent("checksums.sha256"), atomically: true, encoding: .utf8)
            try verify(manifest, directory: stage) { processed in
                progress(BackupProgress("校验配置副本 SHA-256", files.count, files.count, doneBytes,
                    fraction: totalBytes > 0 ? min(0.99, Double(totalBytes * 2 + processed) / Double(totalBytes) / 3) : nil))
            }
            try journal("complete")
            try fm.moveItem(at: stage, to: store.appendingPathComponent(id.uuidString))
            progress(BackupProgress("文件备份校验完成", files.count, files.count, doneBytes, fraction: 1))
            return manifest
        } catch {
            try? journal(error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }
    public func verify(_ manifest: BackupManifest, directory: URL? = nil, onBytes: ((Int64) -> Void)? = nil) throws {
        guard manifest.format == 1, manifest.unsupportedCount == 0,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              Set(manifest.directories).count == manifest.directories.count else { throw TransferError.corruptBackup }
        let base = directory ?? store.appendingPathComponent(manifest.id.uuidString)
        let payload = base.appendingPathComponent("payload")
        try PathSafety.validateSelections(manifest.selections, root: payload)
        let actual = try inventory(root: payload, selections: manifest.selections, hashes: true, onHashBytes: onBytes)
        guard actual.directories == manifest.directories.sorted(), Set(actual.files.keys) == Set(manifest.files.map(\.path)) else { throw TransferError.corruptBackup }
        // Also catch unexpected files alongside selected roots; traversal never ignores dotfiles.
        func allPaths(_ dir: URL, prefix: String) throws -> Set<String> {
            var result = Set<String>()
            for child in try fm.contentsOfDirectory(atPath: dir.path) {
                let p = prefix.isEmpty ? child : prefix + "/" + child
                let url = try PathSafety.resolve(p, in: payload)
                let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                if type == .typeDirectory { result.formUnion(try allPaths(url, prefix: p)) }
                else if type == .typeRegular { result.insert(p) }
                else { throw TransferError.unsupportedFile }
            }
            return result
        }
        guard try allPaths(payload, prefix: "") == Set(manifest.files.map(\.path)) else { throw TransferError.corruptBackup }
        for file in manifest.files {
            guard let a = actual.files[file.path], a.bytes == file.bytes, a.sha256 == file.sha256 else { throw TransferError.corruptBackup }
        }
    }
    public func list() throws -> [BackupManifest] {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result: [BackupManifest] = []
        for dir in try fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: dir.lastPathComponent) != nil else { continue }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let m = try? decoder.decode(BackupManifest.self, from: data),
                  m.id.uuidString == dir.lastPathComponent else { continue }
            result.append(m)
        }
        return result.sorted { $0.created > $1.created }
    }
    public func incompleteCount() throws -> Int {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        return try fm.contentsOfDirectory(atPath: store.path).filter { $0.hasSuffix(".partial") }.count
    }
    public func delete(_ id: UUID) throws { try fm.removeItem(at: store.appendingPathComponent(id.uuidString)) }
}
