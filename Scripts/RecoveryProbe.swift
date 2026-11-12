import Foundation
import Darwin

@main struct RecoveryProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("RecoveryProbe crash|resume copy|exchange|backup CASE_ROOT") }
        let action = args[1], mode = args[2], root = URL(fileURLWithPath: args[3], isDirectory: true)
        let fm = FileManager.default
        func app(_ name: String) -> AppInstance {
            AppInstance(displayName: name, bundleIdentifier: "test." + name, root: root.appendingPathComponent(name), origin: "process-recovery-test")
        }
        let source = app("source"), target = app("target")
        let prefs = PreferencesService(store: root.appendingPathComponent("Copies"))
        let service = DirectMigrationService(store: root.appendingPathComponent("Tasks"), preferCloning: false)
        if action == "crash" {
            for app in [source, target] {
                try fm.createDirectory(at: app.root.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
                try fm.createDirectory(at: app.root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
                for name in ["one", "two"] {
                    try Data(repeating: app.bundleIdentifier == source.bundleIdentifier ? 0x31 : 0x72, count: 8 * 1_048_576).write(to: app.root.appendingPathComponent("Documents/" + name))
                    try PropertyListSerialization.data(fromPropertyList: ["name": app.displayName, "file": name], format: .binary, options: 0).write(to: app.root.appendingPathComponent("Library/Preferences/" + name + ".plist"))
                }
            }
            if mode == "backup" {
                _ = try await prefs.save(instance: source, systemVersion: "host", deviceModel: "Mac") { p in
                    if p.stage == "复制配置与 SHA-256" && p.completed == 1 { _exit(77) }
                }
            } else {
                let mappings = mode == "exchange" ? [DirectoryMapping(source: "Documents/one", target: "Documents/one"), DirectoryMapping(source: "Documents/two", target: "Documents/two")] : [DirectoryMapping(source: "Documents", target: "Documents")]
                _ = try await service.migrate(source: source, target: target, mappings: mappings, mode: mode == "exchange" ? .exchange : .replace,
                    preferences: prefs, systemVersion: "host", deviceModel: "Mac", allowOverwrite: true) { p in
                        if mode == "exchange" && p.stage == "双向转换完成" && p.completed == 2 { _exit(77) }
                        if mode == "copy" && p.stage == "直接传输并校验" && p.completed == 1 { _exit(77) }
                    }
            }
            fatalError("crash point not reached")
        } else if mode == "backup" {
            let pending = try await prefs.pendingBackups()
            guard let task = pending.first else { fatalError("missing persisted backup plan") }
            let manifest = try await prefs.resumeBackup(task.id, instance: source, progress: { _ in })
            try await prefs.verify(manifest)
            guard manifest.files.count == 2 else { fatalError("incomplete backup") }
            print("PROCESS_RECOVERY backup persistedPlan=true resumed=true verified=true files=2")
        } else {
            let history = try await service.history()
            guard let task = history.first else { fatalError("missing persisted migration plan") }
            let result = try await service.resume(task.id, source: source, target: target, preferences: prefs, progress: { _ in })
            guard result.state == "filesVerified" else { fatalError("incomplete migration") }
            for name in ["one", "two"] {
                let a = try Data(contentsOf: source.root.appendingPathComponent("Documents/" + name))
                let b = try Data(contentsOf: target.root.appendingPathComponent("Documents/" + name))
                guard a == Data(repeating: mode == "exchange" ? 0x72 : 0x31, count: 8 * 1_048_576), b == Data(repeating: 0x31, count: 8 * 1_048_576) else { fatalError("content mismatch") }
            }
            print("PROCESS_RECOVERY \(mode) persistedPlan=true resumed=true fullBytesVerified=true duplicateExchange=false")
        }
    }
}
