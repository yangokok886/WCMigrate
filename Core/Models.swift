import Foundation

public enum TransferError: Error, LocalizedError {
    case invalidPath, unsupportedFile, changedSource, insufficientSpace, corruptBackup, noSelection, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "路径越界、包含链接或目录选择冲突，操作已停止。"
        case .unsupportedFile: return "含有符号链接或特殊文件，操作已停止。"
        case .changedSource: return "保存配置期间源数据发生变化，请退出来源应用后重试。"
        case .insufficientSpace: return "本机可用空间不足，操作已停止。"
        case .corruptBackup: return "文件、目录结构或 SHA-256 校验不一致。"
        case .noSelection: return "请明确选择至少一个文件或文件夹。"
        case .unavailable: return "该能力尚未通过当前设备验证。"
        }
    }
}
public struct AppInstance: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var bundleIdentifier: String
    public var version: String?
    public var build: String?
    public var root: URL
    public var origin: String
    // Keep the persisted classification marker separate from the displayed source.
    public var originDisplayName: String { origin.hasPrefix("系统容器") ? "系统容器" : origin }
    public var bookmark: Data?
    public var executableName: String?
    public var bundlePath: String?
    public init(id: String = UUID().uuidString, displayName: String, bundleIdentifier: String, version: String? = nil, build: String? = nil, root: URL, origin: String, bookmark: Data? = nil, executableName: String? = nil, bundlePath: String? = nil) {
        self.id = id; self.displayName = displayName; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.build = build; self.root = root; self.origin = origin; self.bookmark = bookmark; self.executableName = executableName; self.bundlePath = bundlePath
    }
}
public extension AppInstance {
    var isWeChat: Bool { executableName == "WeChat" && bundlePath != nil }
    var isTencent: Bool { bundleIdentifier.hasPrefix("com.tencent") }
    static func prioritized(_ apps: [AppInstance]) -> [AppInstance] {
        func rank(_ id: String) -> Int {
            if id == "com.tencent.xin" { return 0 }
            if id == "com.tencent.qy.xin" { return 1 }
            if id.hasPrefix("com.tencent.xin") { return 2 }
            if id.hasPrefix("com.tencent.qy.xin") { return 3 }
            return id.hasPrefix("com.tencent") ? 4 : 5
        }
        return apps.sorted {
            let a = rank($0.bundleIdentifier), b = rank($1.bundleIdentifier)
            if a != b { return a < b }
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }
}
public enum TransferMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case replace, exchange, merge
    public var id: String { rawValue }
    public var title: String { switch self { case .replace: return "替换"; case .exchange: return "转换"; case .merge: return "合并" } }
    public var symbol: String { switch self { case .replace: return "arrow.right.square"; case .exchange: return "arrow.left.arrow.right"; case .merge: return "arrow.triangle.merge" } }
    public var explanation: String {
        switch self {
        case .replace: return "1 覆盖到 2，清除目标所选文件夹内来源没有的内容；1 保留。"
        case .exchange: return "双向交换所选文件或文件夹：1 的内容到 2，2 的原内容到 1。"
        case .merge: return "1 覆盖到 2，同名直接替换，目标独有内容保留；1 保留。"
        }
    }
    public var sourceNote: String { self == .exchange ? "两边所选内容互换" : "来源数据保留" }
}
public struct FileRecord: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var modified: Date
    public var sha256: String
}
public struct BackupManifest: Identifiable, Codable, Sendable {
    public var format: Int = 1
    public var id: UUID
    public var instance: AppInstance
    public var created: Date
    public var systemVersion: String
    public var deviceModel: String
    public var selections: [String]
    public var directories: [String]
    public var files: [FileRecord]
    public var compatibility: String = "Preferences 配置副本；不包含聊天数据恢复能力"
    public var unsupportedCount: Int = 0
    public var importedSingleFile: Bool? = nil
    public var plistOnly: Bool? = nil
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}
public struct BackupProgress: Sendable {
    public var stage: String
    public var completed: Int
    public var total: Int
    public var bytes: Int64
    public var fraction: Double?
    public init(_ stage: String, _ completed: Int, _ total: Int, _ bytes: Int64, fraction: Double? = nil) {
        self.stage = stage; self.completed = completed; self.total = total; self.bytes = bytes; self.fraction = fraction
    }
}
public struct DirectoryMapping: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}
public struct DirectoryEntry: Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var bytes: Int64
}
public struct DatabaseReport: Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var bytes: Int64
    public var hasWAL: Bool
    public var hasSHM: Bool
    public var tables: [String]
    public var indexCount: Int
    public var result: String
}
