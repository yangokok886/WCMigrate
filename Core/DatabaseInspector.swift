import Foundation
import SQLite3

public enum DatabaseInspector {
    // Call only with a verified backup; every database and sidecar is copied again to a disposable workspace.
    public static func inspect(manifest: BackupManifest, backupDirectory: URL) throws -> [DatabaseReport] {
        let payload = backupDirectory.appendingPathComponent("payload")
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        var reports: [DatabaseReport] = []
        for file in manifest.files {
            try Task.checkCancellation()
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard ["db", "sqlite", "sqlite3"].contains(ext) else { continue }
            let original = try PathSafety.resolve(file.path, in: payload)
            let copy = workspace.appendingPathComponent(UUID().uuidString + ".db")
            try fm.copyItem(at: original, to: copy)
            var sides: [String: Bool] = [:]
            for suffix in ["-wal", "-shm"] {
                let found = manifest.files.contains { $0.path == file.path + suffix }
                sides[suffix] = found
                if found { try fm.copyItem(at: PathSafety.resolve(file.path + suffix, in: payload), to: URL(fileURLWithPath: copy.path + suffix)) }
            }
            var db: OpaquePointer?
            let status = sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            var tables: [String] = []; var indices = 0; var result = "无法解析：可能加密、格式不支持或文件损坏"
            if status == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 1000)
                // A bounded VM budget prevents malicious/corrupt schemas or huge checks stalling forever.
                let budget = UnsafeMutablePointer<Int32>.allocate(capacity: 1); budget.initialize(to: 0)
                sqlite3_progress_handler(db, 1000, { context in
                    guard let context else { return 1 }
                    let count = context.assumingMemoryBound(to: Int32.self); count.pointee += 1
                    return count.pointee > 20_000 ? 1 : 0
                }, budget)
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT type,name FROM sqlite_master WHERE type IN ('table','index') ORDER BY name LIMIT 5000", -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let kind = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) {
                            if String(cString: kind) == "table" { tables.append(String(cString: name)) } else { indices += 1 }
                        }
                    }
                }
                sqlite3_finalize(stmt); stmt = nil
                if sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
                   let text = sqlite3_column_text(stmt, 0) {
                    result = String(cString: text) == "ok" ? "SQLite quick_check 通过（非聊天恢复验证）" : "SQLite 完整性异常"
                }
                sqlite3_finalize(stmt)
                sqlite3_progress_handler(db, 0, nil, nil); budget.deinitialize(count: 1); budget.deallocate()
            }
            sqlite3_close(db)
            reports.append(DatabaseReport(path: file.path, bytes: file.bytes, hasWAL: sides["-wal"] == true, hasSHM: sides["-shm"] == true,
                                          tables: tables, indexCount: indices, result: result))
        }
        return reports
    }
}
