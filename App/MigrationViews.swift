import SwiftUI

enum DirectoryMode { case source, target((String) -> Void) }
struct DirectoryBrowser: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tour: ProductTour
    private var selectedPaths: Set<String> { selectionOverride?.wrappedValue ?? (tour.active ? tour.selections : store.selections) }
    @Environment(\.dismiss) var dismiss
    var instance: AppInstance
    var relative: String?
    var mode: DirectoryMode
    var selectionOverride: Binding<Set<String>>? = nil
    @State private var entries: [DirectoryEntry] = []
    @State private var loading = true
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                HStack { ApplicationIcon(application: instance, size: 32); VStack(alignment: .leading, spacing: 3) { Text(instance.displayName).font(.subheadline.weight(.medium)); Text(relative ?? "容器根目录").font(.caption.monospaced()).foregroundStyle(.secondary) } }
            }
            Section {
                if loading { SwiftUI.ProgressView("读取目录…") }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                    Button("复制目录诊断") { UIPasteboard.general.string = failure + "\n\n" + store.diagnosticText() }
                }
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        if case .source = mode {
                            Button { toggle(entry.path) } label: { Image(systemName: selectedPaths.contains(entry.path) ? "checkmark.circle.fill" : "circle").font(.title3).frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityIdentifier("selectDirectory-" + entry.path).tourTarget(entry.path == "Documents" ? "documents" : entry.path == "Library" ? "library" : "entry-" + entry.path, action: { toggle(entry.path) }).accessibilityLabel("选择 \(entry.name)").disabled(store.busy)
                        }
                        if entry.isDirectory {
                            NavigationLink { DirectoryBrowser(instance: instance, relative: entry.path, mode: mode, selectionOverride: selectionOverride) } label: {
                                HStack { Image(systemName: "folder").foregroundStyle(Color.xctAccent); Text(entry.name).font(.subheadline); Spacer() }.frame(minHeight: 44).contentShape(Rectangle())
                            }.accessibilityIdentifier("openDirectory-" + entry.path)
                        } else if case .target(let select) = mode {
                            Button { select(entry.path) } label: {
                                HStack { Image(systemName: "doc"); Text(entry.name).font(.subheadline); Spacer(); Text(byteText(entry.bytes)).font(.caption).foregroundStyle(.secondary) }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("targetFile-" + entry.path)
                        } else {
                            Image(systemName: "doc").foregroundStyle(.secondary); Text(entry.name).font(.subheadline); Spacer(); Text(byteText(entry.bytes)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3)
                }
                if !loading && entries.isEmpty && failure == nil { Text("空目录").foregroundStyle(.secondary) }
            } footer: {
                if case .source = mode { Text("可选任意文件或文件夹，包括沙盒根目录下的项目。子项和父文件夹不能重复选择。") }
            }
        }
        .navigationTitle("文件与文件夹").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(tour.active)
        
        .safeAreaInset(edge: .bottom) {
            if case .target(let select) = mode, let relative {
                BottomAction { Button("使用此目标目录") { select(relative) }.buttonStyle(PrimaryButton()) }
            } else if case .source = mode {
                BottomAction {
                    HStack { Text("已选 \(selectedPaths.count) 项").font(.subheadline); Spacer(); Text(selectionOverride != nil ? "保留所选项目的相对路径" : (tour.active ? tour.mode.sourceNote : store.transferMode.sourceNote(keepSource: store.keepMigrationSource))).font(.caption).foregroundStyle(.secondary) }
                    Button("完成") { if tour.active { tour.advance(.filesDone) }; dismiss() }.buttonStyle(PrimaryButton()).tourTarget("filesDone", action: { tour.advance(.filesDone); dismiss() })
                }
            }
        }
        .productTourOverlay()
        .task {
            if tour.active {
                entries = [DirectoryEntry(path: "Documents", name: "Documents", isDirectory: true, bytes: 0), DirectoryEntry(path: "Library", name: "Library", isDirectory: true, bytes: 0)]; loading = false; return
            }
            do { entries = try await store.entries(instance, relative: relative) } catch { failure = error.localizedDescription; store.audit("目录读取失败 · " + error.localizedDescription) }; loading = false }
    }
    private func toggle(_ path: String) {
        if let selectionOverride {
            var paths = selectionOverride.wrappedValue
            if paths.contains(path) { paths.remove(path) }
            else { paths = paths.filter { !$0.hasPrefix(path + "/") && !path.hasPrefix($0 + "/") }; paths.insert(path) }
            selectionOverride.wrappedValue = paths
            return
        }
        if tour.active {
            tour.selections.insert(path)
            if path == "Documents" { tour.advance(.documents) }; if path == "Library" { tour.advance(.library) }; return
        }
        store.preview = nil; store.mappings = []
        if store.selections.contains(path) { store.selections.remove(path) }
        else { store.selections = store.selections.filter { !$0.hasPrefix(path + "/") && !path.hasPrefix($0 + "/") }; store.selections.insert(path) }
    }
}
struct MappingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tour: ProductTour
    private var paths: Set<String> { tour.active ? tour.selections : store.selections }
    private var mode: TransferMode { tour.active ? tour.mode : store.transferMode }
    struct MappingSelection: Identifiable { let path: String; var id: String { path } }
    @State private var mappingSource: MappingSelection?
    @State private var showPreview = false
    @State private var manualSource: String?
    @State private var manualTarget = ""
    var body: some View {
        Screen(tourStep: tour.step?.rawValue) {
            SectionLabel(title: "确认数据去向", detail: "\(paths.count) 项")
            Label(mode.title, systemImage: mode.symbol).font(.title3.weight(.semibold)).foregroundStyle(Color.xctAccent)
            Text(mode.explanation(keepSource: store.keepMigrationSource)).font(.subheadline).foregroundStyle(.secondary)
            ForEach(paths.sorted(), id: \.self) { path in
                mappingCard(path)
            }
            Text("默认写入目标应用的对应位置。点击目标卡片浏览目录，也可手动输入相对路径。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 9) { Image(systemName: "slider.horizontal.3").foregroundStyle(Color.xctAccent); Text("迁移直接操作所选内容，不自动备份。插件配置可在配置页单独手动保存。").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            guard !tour.active else { return }
            for path in store.selections where !store.mappings.contains(where: { $0.source == path }) { setTarget(path, for: path) }
            store.mappings.removeAll { !store.selections.contains($0.source) }
        }
        .navigationTitle("位置映射").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(tour.active)
        .safeAreaInset(edge: .bottom) { BottomAction {
            Button { if tour.active { tour.advance(.check) } else { Task { await store.prepareMigration(); if store.preview != nil { showPreview = true } } } } label: { HStack { if store.busy { SwiftUI.ProgressView().tint(.white) }; Text(store.busy ? "正在检查目录…" : "检查并继续") } }.buttonStyle(PrimaryButton()).tourTarget("check").disabled(!tour.active && (store.mappings.count != paths.count || store.selections.isEmpty || store.busy))
        } }
        .productTourOverlay()
        .alert("目标相对路径", isPresented: Binding(get: { manualSource != nil }, set: { if !$0 { manualSource = nil } })) {
            TextField("例如 tmp/item.dat 或 Documents", text: $manualTarget).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("应用路径") { if let path = manualSource { setTarget(manualTarget, for: path) }; manualSource = nil }
            Button("取消", role: .cancel) { manualSource = nil }
        } message: { Text("相对于目标应用沙盒。支持不存在的新路径；禁止 ..、绝对路径和符号链接。") }
        .navigationDestination(isPresented: $showPreview) { MigrationPreview() }
        .sheet(item: $mappingSource) { selection in
            if let target = store.target {
                let path = selection.path
                NavigationStack { DirectoryBrowser(instance: target, relative: nil, mode: .target { selected in
                    setTarget(selected, for: path); mappingSource = nil
                }).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { mappingSource = nil } } } }.environmentObject(store)
            }
        }
    }
    private func mappingCard(_ path: String) -> some View {
        let destination = tour.active ? path : (store.mappings.first(where: { $0.source == path })?.target ?? path)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text("来源位置").font(.caption).foregroundStyle(.secondary)
                    Text(path).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button { if !tour.active { mappingSource = MappingSelection(path: path) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.xctAccent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(destination == path ? "目标位置 · 对应路径" : "目标位置 · 自定义").font(.caption).foregroundStyle(.secondary)
                        Text(destination).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.xctAccent)
                }.padding(15).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).contentShape(Rectangle())

            }.buttonStyle(LiquidActionStyle()).accessibilityIdentifier("mapTarget-" + path)
            Button { if !tour.active { manualSource = path; manualTarget = destination } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").font(.system(size: 16))
                    Text("手动输入路径").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }.buttonStyle(PathActionStyle()).accessibilityIdentifier("manualPath-" + path)
            if destination != path {
                Button { setTarget(path, for: path) } label: {
                    Label("恢复对应路径", systemImage: "arrow.uturn.backward").font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(PathActionStyle()).foregroundStyle(Color.xctAccent).accessibilityIdentifier("samePath-" + path)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .liquidSurface(cornerRadius: 22)
    }
    private func setTarget(_ target: String, for source: String) {
        guard !tour.active else { return }
        store.preview = nil; store.mappings.removeAll { $0.source == source }; store.mappings.append(DirectoryMapping(source: source, target: target))
    }

}
struct MigrationPreview: View {
    @EnvironmentObject var store: AppStore
    @State private var closedApps = false
    @State private var acceptsOverwrite = false
    @State private var confirm = false
    var body: some View {
        Screen(bottomPadding: 90) {
            if let plan = store.preview {
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.inventoryComplete == false ? "按所选路径迁移" : byteText(plan.bytes)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(plan.inventoryComplete == false ? "\(plan.mode.title) · 开始后统计文件与空间" : "\(plan.files) 个文件 · \(plan.mode.title)").font(.subheadline).foregroundStyle(.secondary)
                }
                Panel {
                    InfoRow(title: "1 · 来源 · \(plan.sourceName)", value: plan.sourceBundleID)
                    Divider()
                    InfoRow(title: "2 · 目标 · \(plan.targetName)", value: plan.targetBundleID)
                    ForEach(plan.mappings) { m in Text(m.source + " → " + m.target).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(plan.mode.sourceNote(keepSource: plan.preservesSource), systemImage: plan.mode.symbol).foregroundStyle(Color.xctAccent)
                    Label("不自动备份插件配置", systemImage: "slider.horizontal.3")
                }.font(.footnote).padding(.horizontal, 2)
                Panel {
                    Text("覆盖前确认").font(.subheadline.weight(.semibold))
                    Text(plan.mode.explanation(keepSource: plan.preservesSource) + " 已执行的操作不能自动整任务回滚；文件完成不保证应用内数据兼容。").font(.caption).foregroundStyle(.secondary)
                    Toggle("两个应用均已退出", isOn: $closedApps).font(.subheadline)
                    Toggle("确认执行所选操作", isOn: $acceptsOverwrite).font(.subheadline)
                }
                Text(plan.mode == .exchange ? "转换用同文件系统原子交换，每组映射分别执行；若目标不存在则移动到目标。系统不支持时终止，不降级为全量复制。" : !plan.preservesSource ? "关闭保留原文件：使用同文件系统直接移动；替换清除目标原内容，合并保留目标独有内容。中断后可从迁移记录继续。" : "文件以单个临时文件写入、校验后覆盖；需要最大单文件及目标增长的空间。").font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("请重新检查目录", systemImage: "folder", description: Text("任务已执行或选择发生变化。")) }
        }
        .navigationTitle("确认迁移").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BottomAction {
            Button("开始迁移") { confirm = true }.buttonStyle(PrimaryButton()).disabled(!closedApps || !acceptsOverwrite || store.preview == nil || store.busy)
        } }
        .alert("执行所选文件操作？", isPresented: $confirm) {
            Button("确认开始迁移", role: .destructive) { store.startMigration(confirmed: true) }; Button("取消", role: .cancel) {}
        } message: { Text(store.transferMode == .exchange ? "两边所选数据会互换。多组映射中断时可能只完成部分交换，请按任务记录核对。" : (store.keepMigrationSource ? "目标可能部分更新；来源保留。" : "直接移动：来源所选内容将移到目标，来源不再保留。目标可能部分更新，中断后请继续原任务。")) }
    }
}
struct ProgressViewScreen: View {
    @EnvironmentObject var store: AppStore
    @State private var expandedDiagnostic = false
    var body: some View {
        NavigationStack {
            Screen {
                VStack(spacing: 14) {
                    Image(systemName: store.operationFinished ? (store.operationSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle") : "arrow.left.arrow.right").font(.system(size: 44, weight: .light)).foregroundStyle(Color.xctAccent)
                    Text(store.stagingOperationTitle.map { store.busy ? "正在" + $0 : (store.operationSucceeded ? $0 + "完成" : "操作未完成") } ?? (store.busy ? (store.operationIsMigration ? "正在迁移" : (store.operationIsConfigurationRestore ? "正在应用配置" : "正在保存配置")) : (store.operationSucceeded ? (store.operationIsMigration ? "文件迁移完成" : (store.operationIsConfigurationRestore ? "配置已应用" : "插件配置已保存")) : "操作未完成"))).font(.title2.weight(.semibold))
                }.padding(.vertical, 28).frame(maxWidth: .infinity)
                if let p = store.progress {
                    Panel {
                        Text(p.stage).font(.subheadline.weight(.medium))
                        if let fraction = store.estimate.fraction {
                            SwiftUI.ProgressView(value: fraction)
                            HStack {
                                Text(fraction, format: .percent.precision(.fractionLength(0))).font(.headline.monospacedDigit())
                                Spacer()
                                if !store.busy && !store.operationSucceeded { Text("已停止") }
                                else if let remaining = store.estimate.remaining { Text("预计剩余 " + OperationEstimate.timeText(remaining)) }
                                else { Text(fraction >= 1 ? "已完成" : "正在估算剩余时间…") }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else {
                            SwiftUI.ProgressView()
                            Text("扫描 / 校验中，暂无法估算剩余时间").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack { Text("\(p.completed) / \(p.total) 个文件"); Spacer(); Text(byteText(p.bytes)) }.font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if store.busy { Label("请勿离开当前页面", systemImage: "iphone").font(.subheadline.weight(.semibold)).foregroundStyle(Color.xctAccent).frame(maxWidth: .infinity).accessibilityIdentifier("stayOnOperationPage").accessibilityValue(UIApplication.shared.isIdleTimerDisabled ? "屏幕常亮已开启" : "屏幕常亮未开启") }
                if !store.renameStatus.isEmpty && (store.operationIsMigration || store.operationIsConfigurationRestore) {
                    Panel {
                        Label(store.renameStatus, systemImage: store.renameError ? "exclamationmark.triangle" : "doc.badge.gearshape")
                            .font(.subheadline).foregroundStyle(store.renameError ? Color.orange : Color.xctAccent)
                        if store.renameError { DiagnosticCopyButton(title: "复制配置改名诊断") { store.diagnostic } }
                        else if !store.busy && !store.renameItems.isEmpty { Button("处理配置文件名") { store.renamePrompt = true }.frame(minHeight: 44) }
                    }
                }
                if store.operationFinished && !store.operationSucceeded {
                    Text(store.message ?? "操作未完成，两边可能已部分更新；请核对任务记录。").font(.subheadline).foregroundStyle(.orange)
                    DisclosureGroup("查看完整诊断", isExpanded: $expandedDiagnostic) {
                        DiagnosticReportView(text: store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic).frame(height: 320)
                    }.font(.subheadline)
                } else {
                    Text(store.stagingOperationTitle != nil ? "请保留 WCMigrate。迁入完成后从“数据暂存”查看记录并选择新应用迁回。中断时不要删除原应用；迁回后请打开目标应用核对数据。" : store.operationIsMigration ? "文件操作完成后，请在两边应用内核对内容。转换会互换所选内容；文件校验不代表应用内兼容。" : "仅处理所选配置目录。请在应用退出时操作，并核对配置生效情况。").font(.subheadline).foregroundStyle(.secondary)
                }
            }.modifier(ConfigurationRenameAlert(inProgress: true)).navigationTitle(store.stagingOperationTitle ?? (store.operationIsMigration ? store.operationMode.title : "插件配置")).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { BottomAction {
                if store.busy { Button("停止操作", role: .destructive) { store.cancel() }.frame(minHeight: 44); Text("停止不会回滚已覆盖的文件。").font(.caption2).foregroundStyle(.secondary) }
                else if !store.operationSucceeded {
                    HStack(spacing: 12) {
                        DiagnosticCopyButton(title: "复制诊断日志") { store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic }
                        ShareLink(item: store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic) { Image(systemName: "square.and.arrow.up").font(.system(size: 20)).frame(width: 52, height: 52) }.buttonStyle(LiquidActionStyle()).accessibilityLabel("分享诊断日志")
                    }
                    Button("完成") { store.progress = nil; store.message = nil; store.showDiagnostic = false }.frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Button("完成") { store.progress = nil; store.message = nil; store.showDiagnostic = false }.buttonStyle(PrimaryButton())
                }
            } }
        }
    }
}
