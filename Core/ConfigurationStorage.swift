import Foundation

/// Move existing copies within our own container, preserving manifests and partial tasks.
public enum ConfigurationStorage {
    public static func prepare(legacy: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: legacy.path) else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            return destination
        }
        if !fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: legacy, to: destination)
            return destination
        }
        let oldEntries = try fm.contentsOfDirectory(atPath: legacy.path)
        if oldEntries.isEmpty {
            try fm.removeItem(at: legacy)
            return destination
        }
        guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
            throw NSError(domain: "WCMigrate.ConfigurationStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "新旧配置备份目录同时含有内容，保留并继续使用旧备份；未覆盖文件，请查看诊断日志。"])
        }
        // Move the complete directory as a unit; never leave a partially moved store.
        try fm.removeItem(at: destination)
        try fm.moveItem(at: legacy, to: destination)
        return destination
    }
}
