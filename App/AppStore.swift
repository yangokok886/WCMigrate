import SwiftUI
import SQLite3

@MainActor final class AppStore: ObservableObject {
    let certificateReminder = CertificateReminder()
    @Published var renameStatus = ""
    @Published var renameError = false
    @Published var renamePrompt = false
    @Published var renameItems: [ConfigurationRename] = []
    private var renameApproved = false
    private var renameReady = false
    private var renameDeclined = false
    private var renaming = false
    private let renameQueue: ConfigurationRenameQueue
    @Published var instances: [AppInstance] = []
    @Published var stagedData: [StagedData] = []
    @Published var stagingOperationTitle: String?
    let staging: DataStagingService
    @Published var copies: [BackupManifest] = []
    @Published var pendingBackups: [PendingConfigurationBackup] = []
    @Published var records: [MigrationReceipt] = []
    @Published var preview: MigrationSummary?
    @Published var source: AppInstance?
    @Published var target: AppInstance?
    @Published var selections: Set<String> = []
    @Published var mappings: [DirectoryMapping] = []
    @Published var keepMigrationSource = false { didSet { preview = nil } }
    @Published var transferMode: TransferMode = .replace { didSet { preview = nil } }
    @Published var busy = false { didSet { UIApplication.shared.isIdleTimerDisabled = busy } }
    @Published var configurationImportStatus = ""
    @Published var scanning = false
    @Published var estimate = OperationEstimate()
    @Published var progress: BackupProgress? { didSet { if let progress { estimate.update(progress) } else { estimate.reset(); stagingOperationTitle = nil } } }
    @Published var message: String?
    @Published var accessMessage = "尚未检测容器访问能力"
    @Published var logs: [String] = []
    @Published var diagnostic = ""
    @Published var diagnosticIsError = true
    @Published var showDiagnostic = false
    @Published var configurationPath = UserDefaults.standard.string(forKey: "configurationPath") ?? "Library/Preferences"
    @Published var operationIsMigration = true
    @Published var operationIsConfigurationRestore = false
    @Published var operationMode: TransferMode = .replace
    @Published var operationFinished = false
    @Published var operationSucceeded = false
    private var operation: Task<Void, Never>?
    @Published var preferencesURL: URL
    let support: URL
    var preferences: PreferencesService
    let migration: DirectMigrationService
    private let discoveryQueue = DispatchQueue(label: "XChatTransfer.discovery", qos: .userInitiated)
    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XChatTransfer")
        renameQueue = ConfigurationRenameQueue(file: support.appendingPathComponent("configuration-renames.json"), prepareAccess: { _ = XCTContainerBridge.prepareRead($0.path) })
        let legacyPreferencesURL = support.appendingPathComponent("PreferencesCopies")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var storageError: Error?
        let initialPreferencesURL: URL
        do { initialPreferencesURL = try ConfigurationStorage.prepare(legacy: legacyPreferencesURL, destination: documents.appendingPathComponent("插件配置备份")) }
        catch { initialPreferencesURL = legacyPreferencesURL; storageError = error }
        preferencesURL = initialPreferencesURL
        preferences = PreferencesService(store: initialPreferencesURL, relativePath: UserDefaults.standard.string(forKey: "configurationPath") ?? "Library/Preferences", prepareAccess: { _ = XCTContainerBridge.prepareRead($0.path) })
        migration = DirectMigrationService(store: support.appendingPathComponent("MigrationTasks"), prepareAccess: { url in _ = XCTContainerBridge.prepareRead(url.path) })
        staging = DataStagingService(root: documents.appendingPathComponent("数据暂存"), ownContainer: documents.deletingLastPathComponent(), migration: migration)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? (support as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        var needsApplicationRefresh = false
        if let data = try? Data(contentsOf: support.appendingPathComponent("instances.json")), let saved = try? JSONDecoder().decode([AppInstance].self, from: data) { needsApplicationRefresh = saved.contains { $0.origin.hasPrefix("系统容器") && !$0.origin.contains("应用分类v1") }; instances = saved.filter { !$0.origin.hasPrefix("系统容器") || ($0.origin.contains("应用分类v1") && ApplicationListingPolicy.rejection(bundlePath: $0.bundlePath) == nil) } }
        if !instances.isEmpty { accessMessage = "已载入 \(instances.count) 个应用记录；本次启动尚未复查访问" }
        // iOS can relocate this app's data container after reinstall/update.
        for i in instances.indices where instances[i].origin.hasPrefix("独立测试") {
            instances[i].root = support.appendingPathComponent("Fixtures").appendingPathComponent(instances[i].root.lastPathComponent)
        }
        if let data = try? Data(contentsOf: support.appendingPathComponent("audit.json")), let saved = try? JSONDecoder().decode([String].self, from: data) { logs = saved }
        // Manual configuration copies always stay in this application's sandbox.
        // Previously selected external folders are not opened or modified.
        UserDefaults.standard.removeObject(forKey: "configurationStorageBookmark")
        Task {
            await refreshRecords()
            if let storageError { fail(storageError) }
            await certificateReminder.refresh()
            await recoverConfigurationRenames()
            #if !targetEnvironment(simulator)
            if needsApplicationRefresh { await discover() }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-long-diagnostic") {
                let report = (1...3000).map { "长日志测试 \($0) · /var/mobile/Containers/Data/Application/QA/Library/Preferences/Plugin/options.json · errno=1 Operation not permitted · parent grant=YES item grant=NO" }.joined(separator: "\n")
                XCTContainerBridge.recordDiscoveryExclusion("local.wcmigrate.qa", reason: report + "\nEND-LONG-DIAGNOSTIC")
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-log-demo") {
                logs = [
                    "2026/11/12, 16:30:26 · 文件操作校验通过 · Documents → Documents · 来源数据保留",
                    "2026/11/12, 16:28:04 · 保存插件配置 · 108 个文件 · Library/Preferences",
                    "2026/11/12, 16:24:18 · 操作终止 · Library/Preferences · errno=1 Operation not permitted",
                    "2026/11/12, 16:21:03 · 容器发现完成 · 350 个应用"
                ]
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-demo") {
                while instances.filter({ $0.origin.hasPrefix("独立测试") }).count < 2 { await makeFixture(); if message != nil { break } }
                var fixtures = instances.filter { $0.origin.hasPrefix("独立测试") }
                if fixtures.count >= 2 {
                    if ProcessInfo.processInfo.arguments.contains("-ui-rename-demo") {
                        UserDefaults.standard.set(!ProcessInfo.processInfo.arguments.contains("-ui-rename-ask"), forKey: "automaticConfigurationRename")
                        for i in 0..<2 {
                            fixtures[i].bundleIdentifier = i == 0 ? "local.test.wechat" : "local.test.clone"
                            let directory = fixtures[i].root.appendingPathComponent("Library/Preferences")
                            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let plist = try? PropertyListSerialization.data(fromPropertyList: ["rename-test": i], format: .binary, options: 0)
                            try? plist?.write(to: directory.appendingPathComponent(fixtures[i].bundleIdentifier + ".plist"))
                            if let index = instances.firstIndex(where: { $0.id == fixtures[i].id }) { instances[index] = fixtures[i] }
                        }
                    }
                    for (i, app) in fixtures.prefix(2).enumerated() {
                        let file = app.root.appendingPathComponent("standalone.txt")
                        if !FileManager.default.fileExists(atPath: file.path) { try? Data("WCMigrate test file \(i)".utf8).write(to: file) }
                    }
                    if !ProcessInfo.processInfo.arguments.contains("-ui-no-selection") { choose(fixtures[0], asSource: true); choose(fixtures[1], asSource: false) }
                    if ProcessInfo.processInfo.arguments.contains("-ui-config-import") {
                        let input = support.appendingPathComponent("UITestPlugin.plist")
                        let data = try? PropertyListSerialization.data(fromPropertyList: ["test": true], format: .xml, options: 0)
                        try? data?.write(to: input)
                        await importConfiguration(input)
                        if let saved = copies.first, let zip = try? await exportConfiguration(saved) { await importConfiguration(zip) }
                        message = nil
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-operation-progress") {
                operationIsMigration = true; operationFinished = false; operationSucceeded = false; busy = true
                progress = BackupProgress("直接传输并校验", 3, 10, 350_000_000, fraction: 0.35)
                estimate.reset()
                estimate.update(BackupProgress("传输", 0, 10, 0, fraction: 0.1), now: Date().addingTimeInterval(-5))
                estimate.update(progress!)
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-resume-demo"), let a = instances.first(where: { $0.origin.hasPrefix("独立测试") }),
               let b = instances.last(where: { $0.origin.hasPrefix("独立测试") }), a.id != b.id {
                do {
                    for (app, value) in [(a, "A"), (b, "B")] {
                        try Data((value + "-one").utf8).write(to: app.root.appendingPathComponent("resume-one"))
                        try Data((value + "-two").utf8).write(to: app.root.appendingPathComponent("resume-two"))
                    }
                    let task = Task {
                        try await migration.migrate(source: a, target: b,
                            mappings: [DirectoryMapping(source: "resume-one", target: "resume-one"), DirectoryMapping(source: "resume-two", target: "resume-two")], mode: .exchange,
                            preferences: preferences, systemVersion: "UI fixture", deviceModel: "simulator", allowOverwrite: true) { p in
                                if p.stage == "双向转换完成" && p.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                            }
                    }
                    _ = try? await task.value
                    await refreshRecords()
                } catch { fail(error) }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-failed-progress") {
                progress = BackupProgress("检查目录与空间", 0, 0, 0)
                operationIsMigration = false; operationFinished = true; operationSucceeded = false
                fail(PathDiagnostic.system("读取路径元信息", support.appendingPathComponent("Fixtures/WeChatNeo/AnimatedEmoji/test.json").path, code: 1))
            }
            #endif
        }
    }
    var group: String { XCTContainerBridge.appGroup() ?? "未提供 App Group" }
    private var checkingAccess = false
    @Published var probingIconCache = false
    func refreshAccessStatus() async {
        guard !checkingAccess, !scanning, !busy else { return }
        checkingAccess = true; defer { checkingAccess = false }
        let apps = Array(AppInstance.prioritized(instances.filter { $0.origin.hasPrefix("系统容器") }).prefix(3))
        guard !apps.isEmpty else {
            accessMessage = "没有已保存的系统应用；请先检测本机应用"
            return
        }
        accessMessage = "正在复查已保存应用的数据容器…"
        let results = await Task.detached {
            apps.map { app -> (Bool, String) in
                _ = XCTContainerBridge.prepareRead(app.root.path)
                if let error = XCTContainerBridge.directoryReadError(app.root.path) { return (false, app.bundleIdentifier + " · " + error) }
                return (true, app.bundleIdentifier + " · 根目录读取成功（未检查全部子项）")
            }
        }.value
        let readable = results.filter { $0.0 }.count
        accessMessage = "本次复查 \(apps.count) 个数据容器，\(readable) 个可读取；不代表安装包可读或写入已验证"
        audit("容器只读复查 · " + results.map { $0.1 }.joined(separator: "; "))
    }
    func probeIconCache() async {
        guard !probingIconCache, !busy, !scanning else { return }
        probingIconCache = true; defer { probingIconCache = false }
        let report = await Task.detached { XCTContainerBridge.probeIconCaches() }.value
        diagnosticIsError = false; message = nil
        diagnostic = report + "\n\n" + diagnosticText()
        showDiagnostic = true
    }
    func audit(_ text: String) {
        logs.insert("\(Date().formatted(date: .numeric, time: .standard)) · \(text)", at: 0)
        if logs.count > 1000 { logs.removeLast(logs.count - 1000) }
        if let data = try? JSONEncoder().encode(logs) { try? data.write(to: support.appendingPathComponent("audit.json"), options: .atomic) }
    }
    func fail(_ error: Error) {
        diagnosticIsError = true
        message = error is CancellationError ? "操作已停止，可能已部分完成；请核对两边内容和任务记录。" : error.localizedDescription
        let ns = error as NSError
        audit("操作终止 · \(String(describing: type(of: error))) · \(error.localizedDescription) · \(ns.domain)/\(ns.code) · \(ns.userInfo)")
        diagnostic = diagnosticText(error: error)
        showDiagnostic = true
    }
    func saveInstances() {
        if let data = try? JSONEncoder().encode(instances) { try? data.write(to: support.appendingPathComponent("instances.json"), options: .atomic) }
    }
    func choose(_ instance: AppInstance, asSource: Bool) {
        preview = nil
        if asSource { source = instance; selections = []; mappings = []; if target?.id == instance.id { target = nil } }
        else { target = instance; mappings = []; if source?.id == instance.id { source = nil; selections = [] } }
    }
    func swap() { preview = nil; let old = source; source = target; target = old; selections = []; mappings = [] }
    func discover(fullScan: Bool = false) async {
        guard !scanning, !busy else { return }; scanning = true; defer { scanning = false }
        do {
            let found: [AppInstance] = try await withCheckedThrowingContinuation { continuation in
                discoveryQueue.async {
                    do {
                        var bridgeError: NSError?
                        let records = XCTContainerBridge.discover(fullScan, error: &bridgeError)
                        if let bridgeError { throw bridgeError }
                        let found = records.compactMap { item -> AppInstance? in
                            if let reason = ApplicationListingPolicy.rejection(bundlePath: item["bundlePath"], excludedReason: item["excludedReason"]) {
                                XCTContainerBridge.recordDiscoveryExclusion(item["id"] ?? "未知", reason: reason)
                                return nil
                            }
                            return AppInstance(id: item["id"]!, displayName: item["name"]!, bundleIdentifier: item["id"]!,
                            version: item["version"], build: item["build"], root: URL(fileURLWithPath: item["path"]!), origin: "系统容器 · 应用分类v1", executableName: item["executable"], bundlePath: item["bundlePath"]) }
                        continuation.resume(returning: found)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if let source, source.origin.hasPrefix("系统容器"), !found.contains(where: { $0.id == source.id }) {
                self.source = nil; selections = []; mappings = []; preview = nil
            }
            if let target, target.origin.hasPrefix("系统容器"), !found.contains(where: { $0.id == target.id }) {
                self.target = nil; mappings = []; preview = nil
            }
            instances.removeAll { $0.origin.hasPrefix("系统容器") }; instances.append(contentsOf: found)
            saveInstances(); accessMessage = "已发现 \(found.count) 个应用路径；正在复查数据容器"; audit("容器发现完成 · \(found.count) 个")
            Task { [weak self] in await Task.yield(); await self?.refreshAccessStatus() }
        } catch { accessMessage = error.localizedDescription; fail(error) }
    }
    func addImported(_ url: URL, name: String, bundleID: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TransferError.invalidPath }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let instance = AppInstance(displayName: name, bundleIdentifier: bundleID.isEmpty ? "未提供（导入目录）" : bundleID, root: url, origin: "用户导入 · 身份未验证", bookmark: bookmark)
        instances.append(instance); saveInstances(); audit("用户导入目录 · 元数据未验证")
    }
    func resolveRoot(_ instance: AppInstance) throws -> URL {
        if let bookmark = instance.bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw TransferError.unavailable }; return url
        }
        if instance.origin.hasPrefix("系统容器") {
            guard XCTContainerBridge.appGroup() != nil else { throw PathDiagnostic("准备应用容器访问", instance.root.path, "缺少可用 App Group。当前签名未授予 Group，或 Group 容器无法打开；请保留有效的 com.apple.security.application-groups entitlement 后重签。") }
            _ = XCTContainerBridge.prepareRead(instance.root.path)
        }
        return instance.root
    }
    func entries(_ instance: AppInstance, relative: String?) async throws -> [DirectoryEntry] {
        let root = try resolveRoot(instance)
        return try await Task.detached {
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            if instance.origin.hasPrefix("系统容器") { _ = XCTContainerBridge.prepareRead(relative.map { root.appendingPathComponent($0).path } ?? root.path) }
            return try PathSafety.children(at: relative, root: root)
        }.value
    }
    func refreshRecords() async {
        do { copies = try await preferences.list(); records = try await migration.history(); pendingBackups = try await preferences.pendingBackups(); stagedData = try await staging.list() } catch { fail(error) }
    }
    @discardableResult
    func deleteStagedData(_ record: StagedData) async -> Bool {
        guard !busy, !scanning, !renaming else { return false }
        busy = true
        defer { busy = false }
        do { try await staging.delete(record.id); await refreshRecords(); return true }
        catch { fail(error); return false }
    }
    func savePreferences(_ instance: AppInstance) {
        guard !busy, !scanning else { return }
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false; operationIsMigration = false; operationIsConfigurationRestore = false
        progress = BackupProgress("保存插件配置", 0, 0, 0)
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                var app = instance; app.root = try resolveRoot(instance)
                let scope = app.root.startAccessingSecurityScopedResource(); defer { if scope { app.root.stopAccessingSecurityScopedResource() } }
                _ = XCTContainerBridge.prepareRead(app.root.appendingPathComponent("Library").path)
                _ = XCTContainerBridge.prepareRead(app.root.appendingPathComponent(configurationPath).path)
                guard let saved = try await preferences.save(instance: app, systemVersion: UIDevice.current.systemVersion,
                    deviceModel: UIDevice.current.model, plistOnly: UserDefaults.standard.bool(forKey: "backupPlistOnly"), progress: { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } }) else {
                    progress = BackupProgress("该应用没有设置的配置目录", 0, 0, 0); return
                }
                operationSucceeded = true
                progress = BackupProgress("插件配置已保存", saved.files.count, saved.files.count, saved.totalBytes, fraction: 1)
                audit("保存完整 Preferences 配置 · \(saved.files.count) 个文件")
            } catch { fail(error) }
            await refreshRecords()
        }
    }
    func resumeBackup(_ pending: PendingConfigurationBackup) {
        guard !busy, !scanning else { return }
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false; operationIsMigration = false; operationIsConfigurationRestore = false
        progress = BackupProgress("复查中断的配置备份", 0, 0, 0)
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                var app = pending.instance; app.root = try resolveRoot(app)
                let scope = app.root.startAccessingSecurityScopedResource(); defer { if scope { app.root.stopAccessingSecurityScopedResource() } }
                let saved = try await preferences.resumeBackup(pending.id, instance: app) { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } }
                operationSucceeded = true; progress = BackupProgress("插件配置已保存", saved.files.count, saved.files.count, saved.totalBytes, fraction: 1)
                audit("中断配置备份已继续并校验完成")
            } catch { fail(error) }
            await refreshRecords()
        }
    }
    private func resolvedPair() throws -> (AppInstance, AppInstance) {
        guard var s = source, var t = target else { throw TransferError.noSelection }
        s.root = try resolveRoot(s); t.root = try resolveRoot(t)
        return (s, t)
    }
    func prepareMigration() async {
        guard !busy, !scanning else { return }
        busy = true; preview = nil; defer { busy = false }
        do {
            audit("检查映射 · 模式=\(transferMode.rawValue) · \(mappings.map { $0.source + " → " + $0.target }.joined(separator: "; "))")
            let (s, t) = try resolvedPair()
            let a = s.root.startAccessingSecurityScopedResource(); let b = t.root.startAccessingSecurityScopedResource()
            defer { if a { s.root.stopAccessingSecurityScopedResource() }; if b { t.root.stopAccessingSecurityScopedResource() } }
            preview = try await migration.preview(source: s, target: t, mappings: mappings, mode: transferMode, keepSource: keepMigrationSource, detailed: false)
        } catch { fail(error) }
    }
    func startMigration(confirmed: Bool) {
        guard confirmed, !busy, !renaming, !scanning, preview != nil else { return }
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false; operationIsMigration = true; operationIsConfigurationRestore = false
        progress = BackupProgress("准备直接迁移", 0, 0, 0)
        let selectedMappings = mappings
        let selectedMode = transferMode
        let selectedKeepSource = keepMigrationSource
        operationMode = selectedMode
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                let (s, t) = try resolvedPair()
                let a = s.root.startAccessingSecurityScopedResource(); let b = t.root.startAccessingSecurityScopedResource()
                defer { if a { s.root.stopAccessingSecurityScopedResource() }; if b { t.root.stopAccessingSecurityScopedResource() } }
                beginConfigurationRenames(source: s, target: t, mappings: selectedMappings, mode: selectedMode)
                let result = try await migration.migrate(source: s, target: t, mappings: selectedMappings, mode: selectedMode, keepSource: selectedKeepSource, preferences: preferences,
                    systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, allowOverwrite: confirmed,
                    diagnostic: { [weak self] text in Task { @MainActor in self?.audit(text) } },
                    progress: { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } })
                await finishConfigurationRenames()
                operationSucceeded = true; progress = BackupProgress("文件操作校验完成", result.files, result.files, result.bytes, fraction: 1); audit("文件操作校验通过 · 等待应用内验证")
            } catch { abandonUnfinishedRename(); fail(error) }
            preview = nil; await refreshRecords()
        }
    }
    func resumeMigration(_ receipt: MigrationReceipt, confirmed: Bool) {
        if confirmed, let staged = stagedData.first(where: { ($0.state == .incoming && $0.incomingTask == receipt.id) || ($0.state == .returning && $0.returnTask == receipt.id) }) {
            resumeStagedData(staged); return
        }
        guard confirmed, !busy, !renaming, !scanning else { return }
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false
        operationIsMigration = receipt.configurationID == nil; operationIsConfigurationRestore = receipt.configurationID != nil; operationMode = receipt.mode
        progress = BackupProgress("复查中断任务与两边身份", 0, receipt.files, 0)
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                let apps = try await migration.recoveryApplications(receipt.id)
                var a = apps[0], b = apps[1]
                a.root = try resolveRoot(a); b.root = try resolveRoot(b)
                let sa = a.root.startAccessingSecurityScopedResource(), sb = b.root.startAccessingSecurityScopedResource()
                defer { if sa { a.root.stopAccessingSecurityScopedResource() }; if sb { b.root.stopAccessingSecurityScopedResource() } }
                beginConfigurationRenames(source: a, target: b, mappings: receipt.mappings, mode: receipt.mode, checkExistence: false)
                let result = try await migration.resume(receipt.id, source: a, target: b, preferences: preferences) { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } }
                await finishConfigurationRenames()
                operationSucceeded = true; progress = BackupProgress("文件操作校验完成", result.files, result.files, result.bytes, fraction: 1); audit("中断迁移已继续并校验完成")
            } catch { abandonUnfinishedRename(); fail(error) }
            await refreshRecords()
        }
    }
    func stageData(from application: AppInstance, paths: Set<String>, keepSource: Bool = false) {
        guard !busy, !scanning, !renaming else { return }
        runStaging(title: "数据暂存") {
            var source = application; source.root = try self.resolveRoot(source)
            let scoped = source.root.startAccessingSecurityScopedResource()
            defer { if scoped { source.root.stopAccessingSecurityScopedResource() } }
            let record = try await self.staging.create(source: source, selections: paths.sorted(), keepSource: keepSource)
            return try await self.staging.run(record.id, preferences: self.preferences,
                systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, diagnostic: self.stagingDiagnostic(), progress: self.stagingProgress())
        }
    }
    func returnStagedData(_ record: StagedData, to application: AppInstance) {
        guard !busy, !scanning, !renaming else { return }
        runStaging(title: "数据迁回") {
            var target = application; target.root = try self.resolveRoot(target)
            let scoped = target.root.startAccessingSecurityScopedResource()
            defer { if scoped { target.root.stopAccessingSecurityScopedResource() } }
            let source = try await self.staging.application(for: record.id)
            try await self.staging.beginReturn(record.id, target: target)
            self.beginConfigurationRenames(source: source, target: target, mappings: record.mappings, mode: .replace)
            let result = try await self.staging.run(record.id, preferences: self.preferences,
                systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, diagnostic: self.stagingDiagnostic(), progress: self.stagingProgress())
            await self.finishConfigurationRenames()
            return result
        }
    }
    func resumeStagedData(_ record: StagedData) {
        guard !busy, !scanning, !renaming else { return }
        runStaging(title: record.state == .incoming ? "数据暂存" : "数据迁回") {
            // Resolve access again, but do not substitute a new container into a partially moved task.
            let external = record.state == .incoming ? record.application : record.returnTarget
            guard let external else { throw TransferError.corruptBackup }
            let root = try self.resolveRoot(external)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            if record.state == .returning, let target = record.returnTarget {
                let source = try await self.staging.application(for: record.id)
                self.beginConfigurationRenames(source: source, target: target, mappings: record.mappings, mode: .replace, checkExistence: false)
            }
            let result = try await self.staging.run(record.id, preferences: self.preferences,
                systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, diagnostic: self.stagingDiagnostic(), progress: self.stagingProgress())
            if record.state == .returning { await self.finishConfigurationRenames() }
            return result
        }
    }
    private func stagingDiagnostic() -> @Sendable (String) -> Void {
        { [weak self] text in Task { @MainActor in self?.audit(text) } }
    }
    private func stagingProgress() -> @Sendable (BackupProgress) -> Void {
        { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } }
    }
    private func runStaging(title: String, action: @escaping @MainActor () async throws -> MigrationReceipt) {
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false
        operationIsMigration = true; operationIsConfigurationRestore = false; operationMode = .exchange
        stagingOperationTitle = title; progress = BackupProgress("检查权限和暂存任务", 0, 0, 0)
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                let receipt = try await action()
                operationSucceeded = true
                progress = BackupProgress(title + "校验完成", receipt.files, receipt.files, receipt.bytes, fraction: 1)
                audit(title + " · 所选路径文件操作校验完成；需在目标应用内确认兼容性")
            } catch { abandonUnfinishedRename(); fail(error) }
            await refreshRecords()
        }
    }
    func cancel(reason: String = "用户点击停止") {
        guard let operation, !operation.isCancelled else { return }
        audit("请求停止操作 · " + reason)
        operation.cancel()
    }
    func verifyPreferences(_ copy: BackupManifest) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await preferences.verify(copy); message = "Preferences 配置副本校验通过。" } catch { fail(error) }
    }
    func diagnosticText(error: Error? = nil) -> String {
        let ns = error as NSError?
        return ["WCMigrate \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")) / iOS \(UIDevice.current.systemVersion)",
            "App Group: \(group)", "容器访问: \(accessMessage)", "屏幕常亮: \(UIApplication.shared.isIdleTimerDisabled ? "开启" : "关闭")",
            "来源: \(source?.bundleIdentifier ?? "未选择")\n\(source?.root.path ?? "")",
            "目标: \(target?.bundleIdentifier ?? "未选择")\n\(target?.root.path ?? "")",
            "模式: \(transferMode.title)", "来源文件: \(transferMode.sourceNote(keepSource: keepMigrationSource))", "映射: " + mappings.map { $0.source + " → " + $0.target }.joined(separator: "; "),
            "配置路径: \(configurationPath)\n配置保存位置: \(preferencesURL.path)",
            error.map { "错误: \($0.localizedDescription)\n\(ns?.domain ?? "") code=\(ns?.code ?? 0)\n\(ns?.userInfo ?? [:])" } ?? "",
            "运行记录:\n" + logs.prefix(60).joined(separator: "\n"),
            "WQ 原始诊断:\n" + XCTContainerBridge.diagnostics()].joined(separator: "\n\n")
    }
    func setConfigurationPath(_ path: String) throws {
        guard !busy else { throw PathDiagnostic("修改配置目录", path, "请等待当前操作完成。") }
        _ = try PathSafety.potential(path, in: support)
        configurationPath = path; UserDefaults.standard.set(path, forKey: "configurationPath")
        preferences = PreferencesService(store: preferencesURL, relativePath: path, prepareAccess: { _ = XCTContainerBridge.prepareRead($0.path) })
    }
    func deleteConfiguration(_ copy: BackupManifest) async {
        guard !busy else { return }
        do { try await preferences.delete(copy.id); await refreshRecords() } catch { fail(error) }
    }
    func exportConfiguration(_ copy: BackupManifest) async throws -> URL {
        guard !busy else { throw PathDiagnostic("分享配置", copy.id.uuidString, "请等待当前操作完成。") }
        busy = true; defer { busy = false }
        try await preferences.verify(copy)
        let dir = preferencesURL.appendingPathComponent(copy.id.uuidString)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("WCMigrate-" + copy.id.uuidString + ".zip")
        try? FileManager.default.removeItem(at: output)
        try await Task.detached { try XCTContainerBridge.createConfigurationZIP(dir.path, output: output.path) }.value
        return output
    }
    func importConfiguration(_ input: URL) async {
        guard !busy else { return }; busy = true; configurationImportStatus = "正在读取配置文件…"
        defer { busy = false; configurationImportStatus = "" }
        let scope = input.startAccessingSecurityScopedResource(); defer { if scope { input.stopAccessingSecurityScopedResource() } }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigImport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            audit("收到配置文件 · " + input.lastPathComponent)
            let ext = input.pathExtension.lowercased()
            guard ext == "zip" || ext == "plist" else { throw PathDiagnostic("识别配置文件", input.lastPathComponent, "只支持 plist 文件或 ZIP 配置包。") }
            let url: URL
            if ext == "zip" {
                configurationImportStatus = "正在解压 ZIP 配置…"
                audit("开始解压配置 ZIP · " + input.lastPathComponent)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try await Task.detached { try XCTContainerBridge.extractConfigurationZIP(input.path, output: staging.path) }.value
                url = staging
            } else { url = input }
            configurationImportStatus = "正在校验并导入配置…"
            let saved = try await preferences.importConfiguration(at: url, systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, displayName: input.deletingPathExtension().lastPathComponent)
            audit("导入配置成功 · \(saved.files.count) 个文件")
            await refreshRecords(); message = "配置已导入，可选择应用执行替换或合并。"
        } catch { fail(error) }
    }
    func applyConfiguration(_ copy: BackupManifest, to instance: AppInstance, mode: TransferMode) {
        guard !busy, !renaming, mode != .exchange else { return }
        estimate.reset(); busy = true; operationFinished = false; operationSucceeded = false; operationIsMigration = false; operationIsConfigurationRestore = false
        operationIsConfigurationRestore = true
        progress = BackupProgress("校验并应用配置", 0, copy.files.count, 0)
        operation = Task {
            defer { busy = false; operationFinished = true; operation = nil }
            do {
                try await preferences.verify(copy)
                let root = preferencesURL.appendingPathComponent(copy.id.uuidString).appendingPathComponent("payload")
                var configSource = AppInstance(displayName: "本地配置 · " + copy.instance.displayName, bundleIdentifier: copy.instance.bundleIdentifier, root: root, origin: "本地配置")
                var app = instance; app.root = try resolveRoot(instance)
                let scope = app.root.startAccessingSecurityScopedResource(); defer { if scope { app.root.stopAccessingSecurityScopedResource() } }
                if configSource.bundleIdentifier == "导入配置" {
                    let known = Set(instances.map(\.bundleIdentifier) + ["com.tencent.xin", "com.tencent.qy.xin"])
                    let matches = known.filter { id in copy.files.contains { $0.path == PreferencesService.relativePath + "/" + id + ".plist" } }
                    if matches.count == 1 { configSource.bundleIdentifier = matches.first! }
                    else { audit("导入配置来源包名不唯一或无法识别，保留原文件名；未猜测插件的配置域") }
                }
                let mappings = try PreferencesService.restorationMappings(copy, targetPath: configurationPath)
                beginConfigurationRenames(source: configSource, target: app, mappings: mappings, mode: mode, sourcePreferencesPath: PreferencesService.relativePath)
                _ = try await migration.migrate(source: configSource, target: app, mappings: mappings, mode: mode, preferences: preferences, systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model, allowOverwrite: true, configurationID: copy.id, progress: { [weak self] p in Task { @MainActor in if self?.busy == true { self?.progress = p } } })
                await finishConfigurationRenames()
                operationSucceeded = true; progress = BackupProgress("配置已" + mode.title + "到所选应用", copy.files.count, copy.files.count, copy.totalBytes, fraction: 1)
                audit("配置应用完成 · \(mode.title) · \(instance.bundleIdentifier)")
            } catch { abandonUnfinishedRename(); fail(error) }
            await refreshRecords()
        }
    }

    private var automaticallyRename: Bool { UserDefaults.standard.object(forKey: "automaticConfigurationRename") as? Bool ?? true }
    var renameExplanation: String {
        let names = renameItems.map { URL(fileURLWithPath: $0.source).lastPathComponent + " → " + URL(fileURLWithPath: $0.destination).lastPathComponent }.joined(separator: "\n")
        return names + (operationFinished ? "\n文件操作已结束。" : "\n文件操作继续进行。") + "\n\n是否按目标应用包名改名？已有同名配置将被替换。迁移继续运行；现在确认会在文件操作完成后执行，完成后确认则立即执行。其他插件配置名称保持原样。"
    }
    private func beginConfigurationRenames(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping], mode: TransferMode, sourcePreferencesPath: String = "Library/Preferences", checkExistence: Bool = true) {
        // Pending confirmed work is handled independently of transfer progress.
        renameItems = []; renameStatus = ""; renameError = false; renameReady = false; renameDeclined = false; renameApproved = automaticallyRename
        func plan(_ a: AppInstance, _ b: AppInstance, _ maps: [DirectoryMapping], _ path: String) -> [ConfigurationRename] {
            if checkExistence {
                let file = a.root.appendingPathComponent(path).appendingPathComponent(a.bundleIdentifier + ".plist")
                _ = XCTContainerBridge.prepareRead(file.deletingLastPathComponent().path); _ = XCTContainerBridge.prepareRead(file.path)
                guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            }
            return ConfigurationRename.plan(source: a, target: b, mappings: maps, preferencesPath: path)
        }
        renameItems = plan(source, target, mappings, sourcePreferencesPath)
        if mode == .exchange {
            renameItems += plan(target, source, mappings.map { DirectoryMapping(source: $0.target, target: $0.source) }, "Library/Preferences")
        }
        if !renameItems.isEmpty { renameStatus = renameApproved ? "文件校验后将自动适配配置文件名" : "是否适配配置文件名，等待确认（迁移继续）" }
        renamePrompt = !renameApproved && !renameItems.isEmpty
    }
    private func finishConfigurationRenames() async {
        do {
            renameItems = try await renameQueue.enqueue(renameItems)
            renameReady = true
            if renameItems.isEmpty { renamePrompt = false; renameStatus = "" }
            if renameDeclined { try await renameQueue.discard(Set(renameItems.map(\.id))); renameItems = [] }
            else if renameApproved { await applyConfigurationRenames() }
            else { renamePrompt = !renameItems.isEmpty }
        } catch { renameError = true; renameStatus = "文件操作完成，配置文件名适配失败，请查看诊断"; renamePrompt = false; audit("文件操作已完成，配置改名待处理：" + error.localizedDescription); diagnostic = String(describing: error); message = "文件操作已完成，配置改名失败，可复制诊断日志。" }
    }
    private func abandonUnfinishedRename() {
        if !renameReady { renamePrompt = false; renameItems = [] }
    }
    func confirmConfigurationRename() {
        renameApproved = true; renamePrompt = false; renameStatus = renameReady ? "正在适配配置文件名" : "已确认，文件校验完成后适配配置文件名"
        if renameReady { Task { await applyConfigurationRenames() } }
    }
    func skipConfigurationRename() {
        renameDeclined = true; renamePrompt = false; renameStatus = "保留原配置文件名"
        if renameReady {
            let ids = Set(renameItems.map(\.id))
            Task { do { try await renameQueue.discard(ids); renameItems = [] } catch { fail(error) } }
        }
    }
    private func applyConfigurationRenames() async {
        guard !renaming else { return }; renaming = true
        defer { renaming = false }
        do {
            let count = try await renameQueue.apply(Set(renameItems.map(\.id)))
            if count > 0 { renameError = false; renameStatus = "已适配配置文件名：\(count) 项"; audit("配置文件名已按目标应用包名适配：\(count) 项") }
            renameItems = []; renamePrompt = false
        } catch {
            renameError = true; renameStatus = "文件操作完成，配置文件名适配失败，请查看诊断"
            audit("文件操作已完成，配置改名失败：" + String(describing: error))
            diagnostic = "配置改名失败（已完成的文件操作不会回滚）\n" + String(describing: error)
            message = "文件操作已完成，但配置改名失败，请查看运行日志。"; renamePrompt = false
        }
    }
    func recoverConfigurationRenames() async {
        guard !busy, !renaming else { return }
        do {
            renameItems = try await renameQueue.pending(); renameReady = true; renameApproved = automaticallyRename; renameDeclined = false
            if renameApproved { await applyConfigurationRenames() } else { renamePrompt = !renameItems.isEmpty }
        } catch { fail(error) }
    }
    #if DEBUG
    private func makeFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("-ui-demo"), !busy else { return }; busy = true; defer { busy = false }
        let fixtureRoot = support.appendingPathComponent("Fixtures").appendingPathComponent(UUID().uuidString)
        do {
            try await Task.detached {
                let docs = fixtureRoot.appendingPathComponent("Documents/Sample")
                try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: fixtureRoot.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
                let plist = try PropertyListSerialization.data(fromPropertyList: ["theme": "system", "enabled": true] as [String: Any], format: .binary, options: 0)
                try plist.write(to: fixtureRoot.appendingPathComponent("Library/Preferences/local.test.plugin.plist"))
                try Data("WCMigrate disposable fixture. No real chats.".utf8).write(to: docs.appendingPathComponent("readme.txt"))
                var db: OpaquePointer?; defer { sqlite3_close(db) }
                guard sqlite3_open(docs.appendingPathComponent("sample.sqlite").path, &db) == SQLITE_OK,
                      sqlite3_exec(db, "CREATE TABLE sample_metadata(id INTEGER PRIMARY KEY, label TEXT); INSERT INTO sample_metadata(label) VALUES('disposable fixture'); CREATE INDEX label_idx ON sample_metadata(label);", nil, nil, nil) == SQLITE_OK else { throw TransferError.unavailable }
            }.value
            let instance = AppInstance(displayName: instances.contains(where: { $0.origin.hasPrefix("独立测试") }) ? "微信 · 测试目标" : "微信 · 测试来源", bundleIdentifier: "local.xchat.fixture", version: "1.0", root: fixtureRoot, origin: "独立测试目录 · 非微信")
            instances.append(instance); saveInstances(); choose(instance, asSource: true); audit("创建独立测试数据")
        } catch { fail(error) }
    }
    #endif
}
