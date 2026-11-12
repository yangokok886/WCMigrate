import Foundation
import Darwin

/// Configuration-only snapshots. Paths are relative to each selected application's data container.
public actor PreferencesService {
    public static let relativePath = "Library/Preferences"
    public let store: URL
    public let relativePath: String
    private let backup: BackupService
    private let prepareAccess: @Sendable (URL) -> Void
    public init(store: URL, relativePath: String = PreferencesService.relativePath, prepareAccess: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.store = store; self.relativePath = relativePath; self.prepareAccess = prepareAccess
        backup = BackupService(store: store, prepareAccess: prepareAccess)
    }
    public func save(instance: AppInstance, systemVersion: String, deviceModel: String, plistOnly: Bool = false,
                     progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupManifest? {
        prepareAccess(instance.root)
        var current = instance.root
        for part in relativePath.split(separator: "/") { current.appendPathComponent(String(part)); prepareAccess(current) }
        let path = try PathSafety.potential(relativePath, in: instance.root, prepareAccess: prepareAccess)
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw PathDiagnostic.system("读取配置目录", path.path, code: errno) }; return nil
        }
        return try await backup.create(instance: instance, selections: [relativePath], systemVersion: systemVersion, deviceModel: deviceModel, plistOnly: plistOnly, progress: progress)
    }
    public func pendingBackups() async throws -> [PendingConfigurationBackup] { try await backup.pending() }
    public func resumeBackup(_ id: UUID, instance: AppInstance, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupManifest {
        try await backup.resume(id, instance: instance, progress: progress)
    }
    public func list() async throws -> [BackupManifest] { try await backup.list() }
    public func verify(_ manifest: BackupManifest) async throws { try await backup.verify(manifest) }
    public nonisolated static func restorationMappings(_ copy: BackupManifest, targetPath: String) throws -> [DirectoryMapping] {
        guard copy.selections.count == 1 else { throw TransferError.corruptBackup }
        if copy.importedSingleFile == true {
            guard copy.files.count == 1 else { throw TransferError.corruptBackup }
            return copy.files.map { DirectoryMapping(source: $0.path, target: targetPath + "/" + URL(fileURLWithPath: $0.path).lastPathComponent) }
        }
        return [DirectoryMapping(source: copy.selections[0], target: targetPath)]
    }
    public func delete(_ id: UUID) async throws { try await backup.delete(id) }
    public func directory(_ manifest: BackupManifest) -> URL { store.appendingPathComponent(manifest.id.uuidString) }

    /// The caller extracts ZIPs to a fresh private folder first. No imported bytes reach a foreign app here.
    public func importConfiguration(at input: URL, systemVersion: String, deviceModel: String, displayName: String? = nil) async throws -> BackupManifest {
        let fm = FileManager.default
        let type = try fm.attributesOfItem(atPath: input.path)[.type] as? FileAttributeType
        let work = store.appendingPathComponent("Import-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var source = input; var single = false; var identity: AppInstance?; var plistOnly = false
        if type == .typeRegular {
            guard input.pathExtension.lowercased() == "plist" else { throw PathDiagnostic("识别配置", input.path, "只支持 plist 文件或 ZIP 配置包。") }
            guard try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 16 * 1024 * 1024 else { throw TransferError.insufficientSpace }
            _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), options: [], format: nil)
            let dir = work.appendingPathComponent(Self.relativePath)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: input, to: dir.appendingPathComponent(input.lastPathComponent))
            source = work; single = true
        } else {
            guard type == .typeDirectory else { throw TransferError.unsupportedFile }
            // Exported WCMigrate archive: manifest + payload, optionally in a single wrapping folder.
            var candidate = input
            let children = try fm.contentsOfDirectory(at: input, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
            if children.count == 1, (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { candidate = children[0] }
            if fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let original = try decoder.decode(BackupManifest.self, from: Data(contentsOf: candidate.appendingPathComponent("manifest.json")))
                guard original.selections.count == 1 else { throw TransferError.corruptBackup }
                try await backup.verify(original, directory: candidate)
                source = candidate.appendingPathComponent("payload"); identity = original.instance; single = original.importedSingleFile ?? false; plistOnly = original.plistOnly ?? false
                let path = original.selections[0]
                let config = try PathSafety.resolve(path, in: source)
                let normal = work.appendingPathComponent(Self.relativePath)
                try fm.createDirectory(at: normal.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: config, to: normal); source = work
            } else {
                var config: URL?
                for base in [input, candidate] {
                    for rel in ["Library/Preferences", "Preferences"] {
                        let url = base.appendingPathComponent(rel)
                        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { config = url; break }
                    }
                    if config != nil { break }
                }
                if config == nil {
                    let files = try fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".DS_Store" }
                    guard !files.isEmpty, files.allSatisfy({ $0.pathExtension.lowercased() == "plist" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else {
                        throw PathDiagnostic("识别 ZIP 配置", input.lastPathComponent, "无法自动识别。支持 WCMigrate 配置包、Preferences 文件夹、Library/Preferences，或根目录全为 plist 的压缩包。")
                    }
                    for file in files { _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) }
                    config = candidate
                }
                let normal = work.appendingPathComponent(Self.relativePath)
                try fm.createDirectory(at: normal.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: config!, to: normal); source = work
            }
        }
        let app = AppInstance(displayName: identity?.displayName ?? displayName ?? input.deletingPathExtension().lastPathComponent, bundleIdentifier: identity?.bundleIdentifier ?? "导入配置", root: source, origin: "导入配置")
        var manifest = try await backup.create(instance: app, selections: [Self.relativePath], systemVersion: systemVersion, deviceModel: deviceModel, progress: { _ in })
        manifest.importedSingleFile = single; manifest.plistOnly = plistOnly
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: store.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }
}
