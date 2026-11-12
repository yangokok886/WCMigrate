import SwiftUI
import UniformTypeIdentifiers

@main struct XChatTransferApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene { WindowGroup {
        RootView().environmentObject(store).tint(.xctAccent)
            .onChange(of: scenePhase) { _, value in
                if value == .background { store.cancel() }
                if value == .active { Task { await store.certificateReminder.refresh(); await store.recoverConfigurationRenames() } }
            }
    } }
}
struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationStack { HomeView() }
            .modifier(ConfigurationRenameAlert(inProgress: false))
            .sheet(isPresented: Binding(get: { store.showDiagnostic && store.progress == nil }, set: { if !$0 { store.showDiagnostic = false; store.message = nil } })) { NavigationStack { DiagnosticView() }.environmentObject(store) }
            .alert("操作信息", isPresented: Binding(get: { store.message != nil && store.progress == nil && !store.showDiagnostic }, set: { if !$0 { store.message = nil } })) {
                Button("知道了", role: .cancel) { store.message = nil }
            } message: { Text(store.message ?? "") }
            .sheet(isPresented: Binding(get: { store.progress != nil }, set: { if !$0 && !store.busy { store.progress = nil } })) {
                ProgressViewScreen().environmentObject(store).interactiveDismissDisabled(store.busy)
            }
    }
}
struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var picking: PickMode?
    var body: some View {
        Screen {
            HStack {
                Label("WCMigrate", systemImage: "arrow.left.arrow.right").font(.caption.weight(.semibold)).foregroundStyle(Color.xctAccent)
                Spacer()
                Text("本机迁移").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("应用数据，按需迁移").font(.system(size: 26, weight: .bold))
                Text("替换、转换或合并，由你决定数据去向。").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.bottom, 2)
            VStack(spacing: 0) {
                instanceRow(store.source, source: true)
                HStack(spacing: 12) {
                    Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
                    Button { store.swap() } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34).transferGlass() }.accessibilityLabel("交换来源和目标").disabled(store.busy)
                    Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
                }.padding(.horizontal, 18)
                instanceRow(store.target, source: false)
            }.background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "操作方式")
                Picker("操作方式", selection: $store.transferMode) {
                    ForEach(TransferMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).accessibilityIdentifier("operationMode").disabled(store.busy)
                Text(store.transferMode.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                SectionLabel(title: "迁移内容", detail: store.selections.isEmpty ? "由你选择" : "\(store.selections.count) 项")
                VStack(spacing: 0) {
                    if let source = store.source {
                        NavigationLink { DirectoryBrowser(instance: source, relative: nil, mode: .source) } label: {
                            HomeOption(icon: "folder", title: "选择文件或文件夹", detail: store.selections.isEmpty ? "沙盒中的任意文件或文件夹" : store.selections.sorted().joined(separator: "、"))
                        }.buttonStyle(.plain).accessibilityIdentifier("chooseDirectories")
                    } else {
                        Button { picking = PickMode(id: 0) } label: { HomeOption(icon: "folder", title: "选择文件或文件夹", detail: "先选择来源应用") }.buttonStyle(.plain)
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink { PreferencesView() } label: { HomeOption(icon: "slider.horizontal.3", title: "插件配置", detail: "手动备份、导入和应用配置") }.buttonStyle(.plain).accessibilityIdentifier("configurationLibrary")
                }.background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 18))
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.shield").foregroundStyle(Color.xctAccent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("不创建整份数据备份").font(.footnote.weight(.semibold))
                    Text("不自动备份聊天或插件配置。替换／合并保留来源，转换互换两边所选内容。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 3)
            HStack {
                Circle().fill(store.scanning ? Color.orange : Color(uiColor: .tertiaryLabel)).frame(width: 6, height: 6)
                Text(store.scanning ? "正在检测应用…" : (store.instances.isEmpty ? "尚未检测本机应用" : "\(store.instances.count) 个可用目录 / 应用")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("管理应用") { picking = PickMode(id: 2) }.font(.caption.weight(.medium))
            }
            if let last = store.records.first {
                NavigationLink { MigrationHistoryView() } label: { HStack { Image(systemName: "clock.arrow.circlepath"); Text("最近迁移"); Spacer(); Text(last.state == "filesVerified" ? "文件校验完成" : "未完成").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption) }.font(.footnote).padding(.vertical, 8) }.buttonStyle(.plain)
            }
        }
        .navigationTitle("WCMigrate").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("设置与记录") } }
        .safeAreaInset(edge: .bottom) {
            BottomAction {
                NavigationLink { MappingView() } label: { HStack { Text("下一步"); Image(systemName: "arrow.right") } }.buttonStyle(PrimaryButton()).accessibilityIdentifier("nextStep")
                    .disabled(store.source == nil || store.target == nil || store.selections.isEmpty || store.busy || store.scanning)
                Text("选择来源 → 选择目标 → 确认迁移").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $picking) { mode in
            NavigationStack { InstancesView(selectSource: mode.id == 2 ? nil : mode.id == 0).toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { picking = nil } } } }.environmentObject(store)
        }
    }
    private func instanceRow(_ instance: AppInstance?, source: Bool) -> some View {
        Button { picking = PickMode(id: source ? 0 : 1) } label: {
            HStack(spacing: 13) {
                ApplicationIcon(application: instance, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source ? "1 · 来源应用" : "2 · 目标应用").font(.caption).foregroundStyle(.secondary)
                    Text(instance?.displayName ?? (source ? "选择来源" : "选择目标")).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if let instance { Text(instance.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(18).frame(minHeight: 88).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.busy).accessibilityIdentifier(source ? "sourceInstance" : "targetInstance")
    }
    struct PickMode: Identifiable { var id: Int }
}
struct HomeOption: View {
    var icon: String; var title: String; var detail: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color.xctAccent).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 8); Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(16).frame(minHeight: 68).contentShape(Rectangle())
    }
}
struct InstancesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var selectSource: Bool? = nil
    var onSelect: ((AppInstance) -> Void)? = nil
    @State private var search = ""
    @State private var importer = false
    @State private var importURL: URL?
    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var metadata = false
    @State private var confirmFullScan = false
        var filtered: [AppInstance] {
        AppInstance.prioritized(store.instances.filter { search.isEmpty || ($0.displayName + $0.bundleIdentifier).localizedCaseInsensitiveContains(search) })
    }
    var body: some View {
        List {
            Section {
                ForEach(filtered) { instance in
                    if let onSelect { Button { onSelect(instance); dismiss() } label: { InstanceRow(instance: instance) }.buttonStyle(.plain).accessibilityIdentifier("application-" + instance.id) }
                    else if let selectSource { Button { store.choose(instance, asSource: selectSource); dismiss() } label: { InstanceRow(instance: instance) }.buttonStyle(.plain).accessibilityIdentifier("application-" + instance.id) }
                    else { NavigationLink { InstanceDetail(instance: instance) } label: { InstanceRow(instance: instance) } }
                }
                if filtered.isEmpty { ContentUnavailableView("没有可用应用", systemImage: "square.stack", description: Text("检测本机应用，或导入已授权的数据目录。")) }
            }
            Section {
                Button { Task { await store.discover() } } label: { Label(store.scanning ? "正在检测…" : "检测本机应用", systemImage: "arrow.clockwise") }.disabled(store.scanning || store.busy)
                Button { importer = true } label: { Label("导入数据目录", systemImage: "folder.badge.plus") }.disabled(store.busy)
                Button("完整扫描（较慢）") { confirmFullScan = true }.font(.footnote).disabled(store.scanning || store.busy)
            } footer: { Text(store.accessMessage) }
        }
        .navigationTitle(selectSource.map { $0 ? "来源应用" : "目标应用" } ?? "应用管理").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索名称或 Bundle ID")
        .refreshable { await store.discover() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in
            switch result { case .success(let url): importURL = url; displayName = url.lastPathComponent; metadata = true
            case .failure(let error): store.fail(error) }
        }
        .alert("导入目录", isPresented: $metadata) {
            TextField("名称", text: $displayName); TextField("Bundle ID（选填）", text: $bundleID).textInputAutocapitalization(.never)
            Button("导入") { guard let url = importURL else { return }; do { try store.addImported(url, name: displayName, bundleID: bundleID) } catch { store.fail(error) }; bundleID = "" }; Button("取消", role: .cancel) { importURL = nil }
        } message: { Text("填写的身份仅作备注，未经系统验证。") }
        .alert("扫描可能耗时较长", isPresented: $confirmFullScan) { Button("开始完整扫描") { Task { await store.discover(fullScan: true) } }; Button("取消", role: .cancel) {} }
    }
}
struct InstanceRow: View {
    var instance: AppInstance
    var body: some View {
        HStack(spacing: 12) {
            ApplicationIcon(application: instance, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(instance.displayName).font(.subheadline.weight(.semibold))
                Text(instance.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                
                Text(instance.origin.hasPrefix("独立测试") ? "模拟测试数据 · 非真实微信" : instance.originDisplayName).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
    }
}
struct InstanceDetail: View {
    @EnvironmentObject var store: AppStore
    var instance: AppInstance
    var body: some View {
        List {
            Section { InstanceRow(instance: instance) }
            Section("身份信息") { InfoRow(title: "Bundle ID", value: instance.bundleIdentifier); InfoRow(title: "版本 / Build", value: "\(instance.version ?? "未知") / \(instance.build ?? "未知")"); InfoRow(title: "数据来源", value: instance.originDisplayName); InfoRow(title: "数据容器", value: instance.root.path); InfoRow(title: "可执行文件", value: instance.executableName ?? "未读取"); InfoRow(title: "安装目录", value: instance.bundlePath ?? "未读取") }
            Section {
                Button("用作来源") { store.choose(instance, asSource: true) }.disabled(store.busy)
                Button("用作目标") { store.choose(instance, asSource: false) }.disabled(store.busy)
                NavigationLink { IconDiagnosticView(application: instance) } label: { Text("图标读取诊断") }
                Button("保存此应用插件配置") { store.savePreferences(instance) }.disabled(store.busy)
            } footer: { Text("仅保存设置的配置目录，不备份聊天记录。") }
        }.navigationTitle("应用详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct ConfigurationRenameAlert: ViewModifier {
    @EnvironmentObject var store: AppStore
    var inProgress: Bool
    func body(content: Content) -> some View {
        content.alert("适配配置文件名", isPresented: Binding(get: { store.renamePrompt && (inProgress || store.progress == nil) }, set: { if !$0 { store.renamePrompt = false } })) {
            Button("暂不改名", role: .cancel) { store.skipConfigurationRename() }
            Button("确定改名") { store.confirmConfigurationRename() }
        } message: { Text(store.renameExplanation) }
    }
}
