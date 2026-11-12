import Foundation
import Darwin
#if canImport(CSupport)
import CSupport
#endif

public struct PathDiagnostic: Error, LocalizedError, Sendable {
    public let action: String
    public let path: String
    public let reason: String
    public let code: Int32?
    public init(_ action: String, _ path: String, _ reason: String, code: Int32? = nil) { self.action = action; self.path = path; self.reason = reason; self.code = code }
    public var errorDescription: String? { "步骤：\(action)\n路径：\(path)\n原因：\(reason)" + (code.map { "\nPOSIX errno=\($0)：" + String(cString: strerror($0)) } ?? "") }
    public static func system(_ action: String, _ path: String, code: Int32) -> PathDiagnostic {
        PathDiagnostic(action, path, code == EPERM ? "系统沙盒拒绝访问；检查签名 App Group 和容器授权。" : code == EACCES ? "文件权限不允许当前用户访问。" : code == ENOENT ? "文件或目录不存在。" : "文件系统调用失败。", code: code)
    }
}
public enum PathSafety {
    public static func resolve(_ relative: String, in root: URL, prepareAccess: (URL) -> Void = { _ in }) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw PathDiagnostic("检查相对路径", relative, "路径为空或包含绝对路径、空段、.、..。") }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var current = canonicalRoot
        prepareAccess(canonicalRoot)
        for part in parts {
            current.appendPathComponent(String(part))
            prepareAccess(current)
            var info = stat()
            if lstat(current.path, &info) != 0 { throw PathDiagnostic.system("读取路径元信息", current.path, code: errno) }
            guard XCTModeIsSymlink(UInt32(info.st_mode)) == 0 else { throw PathDiagnostic("检查符号链接", current.path, "所选范围含符号链接，禁止跟随。") }
        }
        guard current.path.hasPrefix(canonicalRoot.path + "/") else { throw TransferError.invalidPath }
        return current
    }
    public static func validateSelections(_ paths: [String], root: URL, prepareAccess: (URL) -> Void = { _ in }) throws {
        guard !paths.isEmpty else { throw TransferError.noSelection }
        guard Set(paths).count == paths.count else { throw PathDiagnostic("检查重复路径", paths.joined(separator: "\n"), "多个项目映射到了同一位置。") }
        for p in paths {
            let url = try resolve(p, in: root, prepareAccess: prepareAccess)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw TransferError.invalidPath }
            for q in paths where p != q {
                if p.hasPrefix(q + "/") { throw TransferError.invalidPath }
            }
        }
    }
    /// Resolves existing ancestors and permits an absent destination, never traversing a link.
    public static func potential(_ relative: String, in root: URL, prepareAccess: (URL) -> Void = { _ in }) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw PathDiagnostic("检查相对路径", relative, "禁止空路径、绝对路径、.、.. 或空段。") }
        var current = root.resolvingSymlinksInPath().standardizedFileURL
        prepareAccess(current)
        var missing = false
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            if missing { continue }
            prepareAccess(current)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else { throw PathDiagnostic.system("检查目标路径", current.path, code: errno) }
                missing = true; continue
            }
            guard XCTModeIsSymlink(UInt32(info.st_mode)) == 0 else { throw PathDiagnostic("检查符号链接", current.path, "所选范围含符号链接，禁止跟随。") }
            if index < parts.count - 1 {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw PathDiagnostic("检查路径父级", current.path, "父级是文件，不能在其下创建子项目。") }
            }
        }
        return current
    }
    public static func validateItems(_ paths: [String], root: URL, allowMissing: Bool = false) throws {
        guard !paths.isEmpty else { throw TransferError.noSelection }
        guard Set(paths).count == paths.count else { throw PathDiagnostic("检查重复路径", paths.joined(separator: "\n"), "多个项目映射到了同一位置。") }
        for path in paths {
            let url = try allowMissing ? potential(path, in: root) : resolve(path, in: root)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard allowMissing && errno == ENOENT else { throw PathDiagnostic.system("检查所选项目", url.path, code: errno) }
            } else {
                let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { throw PathDiagnostic("检查文件类型", url.path, "不是普通文件或文件夹；可能是链接或特殊文件。") }
            }
            for other in paths where path != other {
                if path.hasPrefix(other + "/") { throw PathDiagnostic("检查选择冲突", path, "与父目录 \(other) 重复选择。") }
            }
        }
    }
    public static func validateMappings(_ mappings: [DirectoryMapping], source: URL, target: URL, allowMissingSource: Bool = false) throws {
        try validateItems(mappings.map(\.source), root: source, allowMissing: allowMissingSource)
        try validateItems(mappings.map(\.target), root: target, allowMissing: true)
        let s = source.resolvingSymlinksInPath().path; let t = target.resolvingSymlinksInPath().path
        guard s != t, !s.hasPrefix(t + "/"), !t.hasPrefix(s + "/") else { throw PathDiagnostic("检查应用边界", s + " → " + t, "来源和目标是同一容器，或两者存在父子关系。") }
    }
    public static func children(at relative: String?, root: URL) throws -> [DirectoryEntry] {
        let folder = try relative.map { try resolve($0, in: root) } ?? root
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { url in
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attrs[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else { throw TransferError.unsupportedFile }
                return DirectoryEntry(path: relative.map { $0 + "/" + url.lastPathComponent } ?? url.lastPathComponent,
                    name: url.lastPathComponent, isDirectory: type == .typeDirectory,
                    bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
            }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
