import SwiftUI
import UniformTypeIdentifiers

private struct SharedZIP: Identifiable { var url: URL; var id: String { url.path } }
struct ConfigurationShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tour: ProductTour
    @AppStorage("backupPlistOnly") private var plistOnly = false
    @State private var pickApplication = false
    @State private var selectedSaveApplication: AppInstance?
    @State private var importFile = false
    @State private var editPath = false
    @State private var pathText = ""
    @State private var shared: SharedZIP?
    @State private var deleting: BackupManifest?
    @State private var resumeBackup: PendingConfigurationBackup?
    var body: some View {
        List {
            Section {
                Button { if !tour.active { pathText = store.configurationPath; editPath = true } } label: {
                    LabeledContent("应用内相对路径", value: store.configurationPath)
                }
            } header: { Text("配置目录") } footer: { Text("默认保存整个 Library/Preferences，包含隐藏文件、子目录和非 plist。仅在你手动备份时保存，不影响迁移。") }
            Section {
                Toggle("仅备份 plist 文件", isOn: $plistOnly).disabled(tour.active).accessibilityIdentifier("backupPlistOnly")
                Text("开启后递归保留所有 .plist 及其文件夹层级，忽略其他文件。关闭则保存整个配置目录。").font(.caption).foregroundStyle(.secondary)
                Button { if tour.active { tour.advance(.configurationSave) } else { pickApplication = true } } label: { Label("选择应用并备份配置", systemImage: "app.badge.checkmark").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(PathActionStyle()).foregroundStyle(Color.xctAccent).accessibilityIdentifier("saveConfigurationChooseApp").tourTarget("configurationSave")
                Button { if tour.active { tour.advance(.configurationImport) } else { importFile = true } } label: { Label("导入 plist 或 ZIP 配置", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(PathActionStyle()).foregroundStyle(Color.xctAccent).accessibilityIdentifier("importConfigurationFile").tourTarget("configurationImport")
                if !store.configurationImportStatus.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text(store.configurationImportStatus).font(.subheadline).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("configurationImportStatus")
                }
            }.disabled(store.busy)
            if !tour.active && !store.pendingBackups.isEmpty {
                Section("未完成的配置备份") {
                    ForEach(store.pendingBackups) { pending in
                        Button { resumeBackup = pending } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pending.instance.displayName)
                                Text("检查并继续备份 · " + (pending.plistOnly ? "仅 plist" : "全部配置")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(store.busy)
                    }
                }
            }
            Section("本地配置 · 左滑分享或删除") {
                if store.copies.isEmpty { Text("暂无配置。可选择应用备份，或导入配置文件。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(tour.active ? [] : store.copies) { copy in
                    NavigationLink { PreferencesDetail(copy: copy) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(copy.instance.displayName).font(.subheadline.weight(.medium))
                            Text("\(copy.files.count) 个配置文件 · \(byteText(copy.totalBytes))").font(.caption).foregroundStyle(.secondary)
                            Text(copy.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deleting = copy } label: { Label("删除", systemImage: "trash") }
                        Button { Task { do { shared = SharedZIP(url: try await store.exportConfiguration(copy)) } catch { store.fail(error) } } } label: { Label("分享 ZIP", systemImage: "square.and.arrow.up") }.tint(.xctAccent)
                    }.disabled(store.busy)
                }
            }
        }.navigationTitle("插件配置").navigationBarTitleDisplayMode(.inline).task { await store.refreshRecords() }
        .sheet(isPresented: $pickApplication, onDismiss: { if let app = selectedSaveApplication { selectedSaveApplication = nil; store.savePreferences(app) } }) { NavigationStack { InstancesView(onSelect: { selectedSaveApplication = $0 }).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pickApplication = false } } } }.environmentObject(store) }
        .sheet(item: $shared) { ConfigurationShareSheet(url: $0.url) }
        .background(ConfigurationDocumentPicker(isPresented: $importFile, onPick: { url in
            store.audit("文件选择器已选择 · " + url.lastPathComponent)
            Task { await store.importConfiguration(url) }
        }, onCancel: { store.audit("已取消选择配置文件") }).frame(width: 0, height: 0))
        .alert("应用内配置相对路径", isPresented: $editPath) {
            TextField("Library/Preferences", text: $pathText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("保存") { do { try store.setConfigurationPath(pathText) } catch { store.fail(error) } }
            Button("取消", role: .cancel) {}
        } message: { Text("相对于应用数据沙盒。手动备份和应用配置使用此路径。不要填写整个聊天目录。") }
        .alert("继续配置备份？", isPresented: Binding(get: { resumeBackup != nil }, set: { if !$0 { resumeBackup = nil } })) {
            Button("检查并继续备份") { if let pending = resumeBackup { store.resumeBackup(pending) }; resumeBackup = nil }
            Button("取消", role: .cancel) { resumeBackup = nil }
        } message: { Text("请先退出来源应用。将复查源数据并校验已保存的文件；未完成文件重新复制，源数据变化则停止。") }
        .alert("删除这份本地配置？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除配置", role: .destructive) { if let copy = deleting { Task { await store.deleteConfiguration(copy) } }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }
}
struct PreferencesDetail: View {
    @EnvironmentObject var store: AppStore
    var copy: BackupManifest
    @State private var shared: SharedZIP?
    var body: some View {
        List {
            Section {
                InfoRow(title: "应用", value: copy.instance.displayName)
                InfoRow(title: "Bundle ID", value: copy.instance.bundleIdentifier)
                InfoRow(title: "保存范围", value: copy.selections.joined(separator: ", "))
                InfoRow(title: "容量", value: "\(copy.files.count) 个文件 / \(byteText(copy.totalBytes))")
                if copy.plistOnly == true {
                    Text("此副本仅含 plist。替换整个配置目录会清除副本未包含的文件；需要保留其他配置时请选择合并。").font(.caption).foregroundStyle(.secondary)
                }
                Button("校验配置副本") { Task { await store.verifyPreferences(copy) } }
                Button { Task { do { shared = SharedZIP(url: try await store.exportConfiguration(copy)) } catch { store.fail(error) } } } label: { Label("分享 ZIP 配置包", systemImage: "square.and.arrow.up") }
                NavigationLink { ApplyConfigurationView(copy: copy) } label: { Label("选择应用 · 替换或合并配置", systemImage: "arrow.right.square") }
                    .accessibilityIdentifier("applySavedConfiguration")
            }.disabled(store.busy)
            Section("配置文件") {
                ForEach(copy.files, id: \.path) { file in
                    HStack { Image(systemName: "doc.text"); Text(file.path).font(.caption.monospaced()); Spacer(); Text(byteText(file.bytes)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("配置详情").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shared) { ConfigurationShareSheet(url: $0.url) }
    }
}
struct ApplyConfigurationView: View {
    @EnvironmentObject var store: AppStore
    var copy: BackupManifest
    @State private var application: AppInstance?
    @State private var pickApplication = false
    @State private var mode: TransferMode = .merge
    @State private var confirm = false
    var body: some View {
        List {
            Section("配置来源") { Text(copy.instance.displayName); Text("\(copy.files.count) 个文件 · \(byteText(copy.totalBytes))").font(.caption).foregroundStyle(.secondary) }
            Section("应用到") {
                Button { pickApplication = true } label: {
                    HStack { ApplicationIcon(application: application); Text(application?.displayName ?? "选择目标应用"); Spacer(); Image(systemName: "chevron.right") }.frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.accessibilityIdentifier("configurationTarget")
                InfoRow(title: "目标配置目录", value: store.configurationPath)
                Picker("写入方式", selection: $mode) { Text("替换").tag(TransferMode.replace); Text("合并").tag(TransferMode.merge) }.pickerStyle(.segmented)
                Text(copy.importedSingleFile == true ? "单个 plist 只处理对应同名文件，不清空整个配置目录。" : mode == .replace ? "替换整个目标配置目录，删除这份配置中没有的目标项目。" : "同名配置直接替换，目标独有的配置继续保留，不重命名。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Text("请先退出目标应用。此操作直接替换或合并配置，不自动备份；如需保留旧配置，请先手动备份。") .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("应用配置").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BottomAction { Button(mode.title + "配置") { confirm = true }.buttonStyle(PrimaryButton()).disabled(application == nil || store.busy) } }
        .sheet(isPresented: $pickApplication) { NavigationStack { InstancesView(onSelect: { application = $0 }).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pickApplication = false } } } }.environmentObject(store) }
        .alert("确认目标应用已退出并执行" + mode.title + "？", isPresented: $confirm) {
            Button("确认" + mode.title + "配置", role: .destructive) { if let application { store.applyConfiguration(copy, to: application, mode: mode) } }
            Button("取消", role: .cancel) {}
        }
    }
}
struct MigrationHistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var resuming: MigrationReceipt?
    var body: some View {
        List {
            if store.records.isEmpty { ContentUnavailableView("暂无迁移记录", systemImage: "clock.arrow.circlepath") }
            ForEach(store.records) { record in
                Section {
                    Text(record.mode.title + " · " + record.sourceName + (record.mode == .exchange ? " ⇄ " : " → ") + record.targetName).font(.subheadline.weight(.semibold))
                    Text(record.state == "filesVerified" ? "文件校验完成 · 应用内读取待验证" : "未完成 / 已中断 · 目标可能部分更新").font(.footnote).foregroundStyle(record.state == "filesVerified" ? Color.xctAccent : .orange)
                    Text(record.mode.sourceNote(keepSource: record.keepSource ?? true)).font(.caption).foregroundStyle(.secondary)
                    Text("\(record.completedFiles) / \(record.files) 个文件 · \(byteText(record.completedBytes))").font(.caption)
                    if let exchanges = record.exchanged, !exchanges.isEmpty { Text("已转换 \(exchanges.count) 组路径").font(.caption).foregroundStyle(.secondary) }
                    if let pending = record.pendingExchange { Text("中断时正在转换：" + pending.source + " ⇄ " + pending.target + "；继续时先核对是否已交换").font(.caption).foregroundStyle(.orange) }
                    if record.state != "filesVerified", record.resumable == true {
                        Button("检查并继续迁移") { resuming = record }.disabled(store.busy).accessibilityIdentifier("resumeMigration-" + record.id.uuidString)
                    }
                    Text(record.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("迁移记录").navigationBarTitleDisplayMode(.inline).task { await store.refreshRecords() }
            .alert("继续中断的迁移？", isPresented: Binding(get: { resuming != nil }, set: { if !$0 { resuming = nil } })) {
                Button("检查并继续", role: .destructive) { if let record = resuming { store.resumeMigration(record, confirmed: true) }; resuming = nil }
                Button("取消", role: .cancel) { resuming = nil }
            } message: { Text("请先退出两边应用。将核对原任务、源数据和目标状态；已完成的交换不会重复执行，发现不明变更则停止。") }
    }
}
struct SettingsRowLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.xctAccent).frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(title).font(.body).foregroundStyle(Color.primary)
        }
    }
}
struct SettingsValueRow: View {
    let title: String
    let icon: String
    let value: String
    var detail = false
    var body: some View {
        Group {
            if detail {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.xctAccent).frame(width: 26, height: 26).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.body).foregroundStyle(Color.primary)
                        Text(value).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                LabeledContent { Text(value).font(.body).foregroundStyle(Color.secondary) }
                    label: { SettingsRowLabel(title: title, icon: icon) }
            }
        }.padding(.vertical, 2).accessibilityElement(children: .combine)
    }
}
struct SettingsView: View {
    @EnvironmentObject var tour: ProductTour
    @AppStorage("storeIconsEnabled") private var storeIconsEnabled = true
    @AppStorage("automaticConfigurationRename") private var automaticConfigurationRename = true
    @EnvironmentObject var store: AppStore
    var body: some View {
        List {
            Section {
                Button { guard !store.busy else { return }; tour.start() } label: { SettingsRowLabel(title: "新手操作导览", icon: "hand.tap") }.tint(Color.primary).accessibilityIdentifier("replayOnboarding")
                NavigationLink { MigrationHistoryView() } label: { SettingsRowLabel(title: "迁移记录", icon: "clock.arrow.circlepath") }
                NavigationLink { LogsView() } label: { SettingsRowLabel(title: "运行日志", icon: "text.alignleft") }
            }
            Section {
                SettingsValueRow(title: "文件操作", icon: "arrow.left.arrow.right", value: "替换 · 转换 · 合并")
                SettingsValueRow(title: "来源数据", icon: "doc.on.doc", value: "替换／合并保留，转换互换", detail: true)
                SettingsValueRow(title: "配置备份", icon: "externaldrive", value: "独立手动操作")
            } header: { Text("迁移方式") } footer: {
                Text("替换清除目标多余内容，合并保留目标独有内容，转换双向互换。无整任务回滚，应用内兼容性需实机验证。")
            }
            Section {
                Toggle(isOn: $storeIconsEnabled) { SettingsRowLabel(title: "商店图标回退", icon: "photo") }
            } header: { Text("应用图标") } footer: {
                Text("本地图标不可用时，向 Apple 查询该应用的 Bundle ID 并下载商店图标。不会上传聊天或配置；分身可能查不到，图标可能与本机版本不同。")
            }
            Section {
                Toggle(isOn: $automaticConfigurationRename) { SettingsRowLabel(title: "自动适配配置文件名", icon: "doc.badge.arrow.up") }
                    .accessibilityIdentifier("automaticConfigurationRename")
            } header: { Text("配置适配") } footer: {
                Text("将来源应用的包名.plist 改为目标应用的包名.plist，其他插件文件名保持原样。关闭后询问是否改名；弹窗不暂停迁移，确认后在文件操作完成时处理。已有同名配置会被替换。")
            }
            CertificateReminderSection(reminder: store.certificateReminder)
            Section("环境诊断") {
                SettingsValueRow(title: "支持系统", icon: "iphone", value: "iOS 26–27.2")
                    .accessibilityLabel("支持系统：iOS 26–27.2").accessibilityIdentifier("supportedSystems")
                SettingsValueRow(title: "系统", icon: "gearshape", value: "iOS " + UIDevice.current.systemVersion)
                SettingsValueRow(title: "App Group", icon: "square.stack.3d.up", value: store.group, detail: true)
                SettingsValueRow(title: "容器状态", icon: "checkmark.shield", value: store.accessMessage, detail: true)
            }
            Section("关于 WCMigrate") {
                SettingsValueRow(title: "版本号", icon: "info.circle", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2")
                SettingsValueRow(title: "作者", icon: "person.crop.circle", value: "Xuegao")
                Link(destination: URL(string: "https://t.me/xxuegao6")!) {
                    HStack { SettingsRowLabel(title: "TG频道", icon: "paperplane"); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.secondary) }
                }.tint(Color.primary).accessibilityIdentifier("telegramChannel")
                Link(destination: URL(string: "https://github.com/yangokok886/WCMigrate")!) {
                    HStack { SettingsRowLabel(title: "开源地址", icon: "chevron.left.forwardslash.chevron.right"); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.secondary) }
                }.tint(Color.primary).accessibilityIdentifier("sourceRepository")
            }
            Section {
                NavigationLink { LicenseView() } label: { SettingsRowLabel(title: "开源许可", icon: "doc.text") }
            } header: { Text("开源") } footer: { Text("迁移在本机进行。商店图标回退仅查询 Apple 公开接口。真实应用容器访问与迁移需正确签名后实机验证。") }
        }.tint(Color.xctAccent).navigationTitle("设置与记录").navigationBarTitleDisplayMode(.inline)
            .task { await store.refreshAccessStatus() }
    }
}
struct LicenseView: View {
    private var text: String { guard let url = Bundle.main.url(forResource: "GPL", withExtension: "txt") else { return "请参阅源码 LICENSE" }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "请参阅源码 LICENSE" }
    private var notices: String { guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return "请参阅源码 Docs/THIRD_PARTY_NOTICES.md" }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    var body: some View {
        Screen { Text("GPL-3.0-or-later").font(.title3.weight(.semibold)); Text("容器访问采用 worse_query 漏洞利用，作者 Taj C (forcequit)。https://github.com/forcequitOS/worse_query。分发时遵循 GPL-3.0-or-later，提供对应源码与构建脚本；第三方版权声明保留在源码中。").font(.footnote); Text(notices).font(.footnote).textSelection(.enabled); Text(text).font(.caption.monospaced()).textSelection(.enabled) }.navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    private var report: String { store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(store.diagnosticIsError ? "操作未完成" : "图标缓存探测完成", systemImage: store.diagnosticIsError ? "exclamationmark.triangle" : "doc.text.magnifyingglass").font(.title3.weight(.semibold)).foregroundStyle(store.diagnosticIsError ? Color.orange : Color.xctAccent)
            Text(store.message ?? "诊断详情").font(.body).textSelection(.enabled)
            Text("以下包含实际路径、错误码与授权日志，可复制后反馈。").font(.caption).foregroundStyle(.secondary)
            Text("完整诊断 · \(report.utf8.count) 字节").font(.caption).foregroundStyle(.secondary)
            DiagnosticReportView(text: report).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(20)
        .navigationTitle("诊断详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { store.showDiagnostic = false; store.message = nil; dismiss() } } }
        .safeAreaInset(edge: .bottom) { BottomAction { DiagnosticCopyButton { report }; ShareLink(item: report) { Text("分享日志") } } }
    }
}

struct IconDiagnosticView: View {
    @EnvironmentObject var store: AppStore
    var application: AppInstance
    @State private var report = "正在读取安装目录和图标…"
    var body: some View {
        DiagnosticReportView(text: report).padding(.horizontal, 14)
            .navigationTitle("图标读取诊断").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { BottomAction { Button("复制图标诊断") { UIPasteboard.general.string = report }.buttonStyle(PrimaryButton()) } }
            .task {
                _ = await ApplicationIconCache.shared.load(application.bundleIdentifier)
                report = application.displayName + "\n" + application.bundleIdentifier + "\n\n" + XCTContainerBridge.iconDiagnostics(application.bundleIdentifier).sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "\n") + "\n\nApp Group: " + store.group + "\n\nWQ原始日志:\n" + XCTContainerBridge.diagnostics()
            }
    }
}
