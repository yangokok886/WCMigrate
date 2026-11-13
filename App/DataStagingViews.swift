import SwiftUI

struct DataStagingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tour: ProductTour
    @State private var create = false
    @State private var deleteRecord: StagedData?
    var body: some View {
        List {
            Section {
                Button { create = true; if tour.active { tour.advance(.stagingCreate) } } label: { Label("暂存一个应用的数据", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(PathActionStyle()).foregroundStyle(Color.xctAccent).disabled(store.busy).accessibilityIdentifier("createStaging").tourTarget("stagingCreate", action: { create = true; tour.advance(.stagingCreate) })
            } footer: {
                Text("没有第二个微信也能先搬出数据。可选择移动，或开启“保留原应用数据”进行复制。原应用退出，WCMigrate 保持前台。")
            }
            Section("暂存记录") {
                if store.stagedData.isEmpty { Text("尚无暂存数据").foregroundStyle(.secondary) }
                ForEach(store.stagedData) { item in
                    NavigationLink { StagedDataDetail(id: item.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.application.displayName).font(.headline)
                            Text(item.state.title).font(.subheadline).foregroundStyle(item.state == .stored ? Color.xctAccent : Color.secondary)
                            Text(item.created, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", systemImage: "trash", role: .destructive) { deleteRecord = item }
                            .disabled(store.busy || store.scanning).accessibilityIdentifier("deleteStaging")
                    }
                }
            }
            Section {
                Label("暂存期间不要卸载 WCMigrate", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                Text("数据位于本软件 Documents/数据暂存，卸载本软件会一并删除。仅当所选内容全部校验完成，且确认需要的数据均已选中后，才处理旧应用。暂存内容不包含所选路径之外的数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("数据暂存").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $create) { CreateStagingView() }
            .task { await store.refreshRecords() }
            .refreshable { await store.refreshRecords() }
            .alert("删除暂存记录？", isPresented: Binding(get: { deleteRecord != nil }, set: { if !$0 { deleteRecord = nil } })) {
                Button("删除暂存数据", role: .destructive) { if let item = deleteRecord { Task { await store.deleteStagedData(item) } }; deleteRecord = nil }
                Button("取消", role: .cancel) { deleteRecord = nil }
            } message: { Text("这会永久删除本记录的暂存文件和续传记录，不会自动迁回。若暂存时关闭了保留原数据，暂存区可能是唯一副本，请确认不再需要。") }
    }
}

struct CreateStagingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tour: ProductTour
    @State private var source: AppInstance?
    @State private var paths: Set<String> = ["Documents", "Library"]
    @State private var picker = false
    @State private var browse = false
    @State private var custom = false
    @State private var path = ""
    @State private var closed = false
    @State private var accepted = false
    @State private var keepSource = false
    @State private var confirm = false
    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        List {
            Section("来源应用") {
                Button { picker = true; if tour.active { tour.advance(.stagingSource) } } label: {
                    HStack {
                        ApplicationIcon(application: source, size: 40)
                        Text(source?.displayName ?? "选择掉签或需要暂存的应用").foregroundStyle(.primary)
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("stagingSource").tourTarget("stagingSource", action: { picker = true; tour.advance(.stagingSource) })
            }
            Section {
                ForEach(paths.sorted(), id: \.self) { item in
                    HStack { Label(item, systemImage: "folder").font(.subheadline); Spacer(); Button { paths.remove(item) } label: { Image(systemName: "minus.circle").foregroundStyle(.red).frame(width: 44, height: 44) }.accessibilityLabel("移除 " + item) }
                }
                Button { browse = true } label: { Label("浏览并选择文件或文件夹", systemImage: "folder.badge.plus") }.disabled(source == nil)
                Button { custom = true } label: { Label("手动添加相对路径", systemImage: "plus.circle") }
            } header: { Text("暂存内容") } footer: {
                Text("默认选择 Documents 和 Library，包含其中的 Preferences。可以浏览沙盒改选任意文件或文件夹，也可手动填写相对路径；不要重复选择父目录及其子目录。路径不存在或访问被拒绝时会停止并显示诊断。")
            }
            Section("暂存方式") {
                Toggle("保留原应用数据", isOn: $keepSource)
                Text(keepSource ? "复制到暂存区，原应用里的所选文件保留不动。" : "移动到暂存区，成功后原应用里的所选文件会被移走。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("目标") {
                Label("WCMigrate · 独立数据暂存区", systemImage: "tray.full")
                Text("不会替换本软件自己的 Documents、Library 或插件配置备份。以独立记录保留目录结构，供重装后迁回。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack { Text("来源应用已退出后台"); Spacer(); Toggle("来源应用已退出后台", isOn: $closed).labelsHidden().tourTarget("stagingClosed", action: { closed = true; tour.advance(.stagingClosed) }) }.onChange(of: closed) { _, value in if tour.active && value { tour.advance(.stagingClosed) } }
                HStack { Text("已了解暂存方式，并保留 WCMigrate"); Spacer(); Toggle("已了解暂存方式，并保留 WCMigrate", isOn: $accepted).labelsHidden().tourTarget("stagingAccepted", action: { accepted = true; tour.advance(.stagingAccepted) }) }.onChange(of: accepted) { _, value in if tour.active && value { tour.advance(.stagingAccepted) } }
            } footer: {
                Text("不要先删除旧应用。等待全部校验完成再处理。若中断，不要打开来源应用，先从暂存记录继续。")
            }
        }.navigationTitle("暂存数据").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(tour.active)
            .disabled(store.busy)
        BottomAction {
                    Button("检查并暂存") { if tour.active { tour.advance(.stagingStart) } else { confirm = true } }.buttonStyle(PrimaryButton()).tourTarget("stagingStart")
                        .disabled(source == nil || paths.isEmpty || !closed || !accepted || store.busy || store.scanning)
        }
        }
            .productTourOverlay()
            .sheet(isPresented: $browse) {
                if let source { NavigationStack { DirectoryBrowser(instance: source, relative: nil, mode: .source, selectionOverride: $paths) } }
            }
            .sheet(isPresented: $picker) {
                if tour.active { TourApplicationPicker(choice: .stagingChoice) { source = $0; picker = false } }
                else { StagingApplicationPicker { source = $0; picker = false } }
            }
            .alert("添加相对路径", isPresented: $custom) {
                TextField("例如 Library/Preferences", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加") { if !path.isEmpty { paths.insert(path); path = "" } }; Button("取消", role: .cancel) {}
            } message: { Text("相对于来源应用的沙盒根目录。文件和文件夹均可选择。") }
            .alert(keepSource ? "复制所选数据到暂存区？" : "把所选数据移入暂存区？", isPresented: $confirm) {
                Button(keepSource ? "开始复制" : "开始移动", role: .destructive) { if !tour.active, let source { store.stageData(from: source, paths: paths, keepSource: keepSource) } }
                Button("取消", role: .cancel) {}
            } message: { Text(keepSource ? "所选数据会复制到暂存区，原应用文件保持不变。请确认暂存区有足够空间。" : "成功移动的内容不再保留在来源应用中；不会创建完整副本。请勿离开当前页面，WCMigrate 会保持屏幕常亮。") }
            .onChange(of: tour.step) { _, step in if let step { withAnimation { proxy.scrollTo(step.rawValue, anchor: .center) } } }
        }
    }
}

struct StagedDataDetail: View {
    @State private var deleteConfirm = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    var id: UUID
    @State private var picker = false
    @State private var target: AppInstance?
    @State private var closed = false
    @State private var confirm = false
    private var record: StagedData? { store.stagedData.first { $0.id == id } }
    var body: some View {
        List {
            if let record {
                Section {
                    InfoRow(title: "原应用", value: record.application.displayName + " · " + record.application.bundleIdentifier)
                    InfoRow(title: "状态", value: record.state.title)
                    if let directoryName = record.directoryName { InfoRow(title: "暂存目录", value: directoryName) }
                    InfoRow(title: "原文件处理", value: record.keepSource ? "复制，保留原数据" : "移动，成功项目移出原应用")
                    if record.state == .stored || record.state == .returned { InfoRow(title: "任务文件统计", value: "\(record.files) 个文件 · " + byteText(record.bytes)) }
                }
                Section("对应路径") { ForEach(record.selections, id: \.self) { Text($0).font(.subheadline.monospaced()) } }
                if record.state == .deleting {
                    Section {
                        Text("上次删除未完成，此记录不能继续迁移。请重试删除。")
                        Button("重试删除", systemImage: "trash", role: .destructive) { deleteConfirm = true }.disabled(store.busy || store.scanning)
                    }
                } else if record.state == .incoming || record.state == .returning {
                    Section {
                        Text("不要删除或打开正在操作的应用，也不要手动改动暂存目录。两边可能只完成了部分路径，继续时会先核对原任务。").font(.footnote).foregroundStyle(.secondary)
                        Toggle(record.state == .incoming ? "原应用已退出后台" : "目标应用已退出后台", isOn: $closed)
                        Button("核对并继续未完成任务") { store.resumeStagedData(record) }.disabled(!closed || store.busy || store.scanning)
                        Button("删除未完成暂存", systemImage: "trash", role: .destructive) { deleteConfirm = true }.disabled(store.busy || store.scanning)
                    }
                } else if record.state == .stored {
                    Section {
                        Text("所选路径已完成迁入及文件身份校验。确认需要的数据已全部选中，再删除旧微信并安装新微信。请选择新应用迁回，WCMigrate 保持前台。").font(.footnote).foregroundStyle(.secondary)
                        Button { picker = true } label: {
                            HStack { Text(target?.displayName ?? "选择重装后的应用"); Spacer(); Image(systemName: "chevron.right").font(.caption) }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        Toggle("目标应用已退出后台", isOn: $closed)
                        Button("检查并迁回") { confirm = true }.disabled(target == nil || !closed || store.busy || store.scanning)
                    } header: { Text("迁回应用") } footer: {
                        Text("按原相对路径互换。目标现有内容会移入本记录的暂存目录，暂存的数据进入目标应用；不会把两个微信的数据库拼接。")
                    }
                } else {
                    Section {
                        Label("请打开目标应用核对数据", systemImage: "checkmark.circle").foregroundStyle(Color.xctAccent)
                        Text("迁回任务已完成文件校验，不代表应用内数据一定兼容。暂存目录现在存放目标原有内容，可能为空；不要当成原聊天记录再次恢复。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("暂存详情").navigationBarTitleDisplayMode(.inline)
            .task { await store.refreshRecords() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("删除", systemImage: "trash", role: .destructive) { deleteConfirm = true }.disabled(store.busy || store.scanning) } }
            .sheet(isPresented: $picker) { StagingApplicationPicker { target = $0; picker = false } }
            .alert("将暂存数据迁回所选应用？", isPresented: $confirm) {
                Button("开始迁回", role: .destructive) { if let record, let target { store.returnStagedData(record, to: target) } }
                Button("取消", role: .cancel) {}
            } message: { Text("所选路径与目标互换。目标原有内容移入暂存区。操作中不要打开目标应用；中断后从此记录继续。") }
            .alert("删除暂存记录？", isPresented: $deleteConfirm) {
                Button("删除暂存数据", role: .destructive) { if let record { Task { if await store.deleteStagedData(record) { dismiss() } } } }
                Button("取消", role: .cancel) {}
            } message: { Text("这会永久删除本记录的暂存文件和续传记录，不会自动迁回。若暂存时关闭了保留原数据，暂存区可能是唯一副本，请确认不再需要。") }
    }
}

struct StagingApplicationPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var select: (AppInstance) -> Void
    @State private var search = ""
    private var apps: [AppInstance] {
        AppInstance.prioritized(store.instances.filter { app in
            let path = app.root.resolvingSymlinksInPath().path
            let own = NSHomeDirectory()
            return path != own && !path.hasPrefix(own + "/") &&
                (search.isEmpty || app.displayName.localizedCaseInsensitiveContains(search) || app.bundleIdentifier.localizedCaseInsensitiveContains(search))
        })
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(apps) { app in Button { select(app) } label: { InstanceRow(instance: app) }.buttonStyle(.plain) }
                    if apps.isEmpty { Text("没有可选应用，请检测本机应用。").foregroundStyle(.secondary) }
                }
                Section { Button(store.scanning ? "正在检测…" : "检测本机应用") { Task { await store.discover() } }.disabled(store.scanning || store.busy) }
            }.navigationTitle("选择应用").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "名称或 Bundle ID")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
