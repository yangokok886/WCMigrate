import SwiftUI

enum DirectoryMode { case source, target((String) -> Void) }
struct DirectoryBrowser: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var instance: AppInstance
    var relative: String?
    var mode: DirectoryMode
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
                            Button { toggle(entry.path) } label: { Image(systemName: store.selections.contains(entry.path) ? "checkmark.circle.fill" : "circle").font(.title3).frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityIdentifier("selectDirectory-" + entry.path).accessibilityLabel("选择 \(entry.name)").disabled(store.busy)
                        }
                        if entry.isDirectory {
                            NavigationLink { DirectoryBrowser(instance: instance, relative: entry.path, mode: mode) } label: {
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
        .navigationTitle("文件与文件夹").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if case .source = mode { Button("完成") { dismiss() }.fontWeight(.semibold) } } }
        .safeAreaInset(edge: .bottom) {
            if case .target(let select) = mode, let relative {
                BottomAction { Button("使用此目标目录") { select(relative) }.buttonStyle(PrimaryButton()) }
            } else if case .source = mode {
                BottomAction { HStack { Text("已选 \(store.selections.count) 项").font(.subheadline); Spacer(); Text(store.transferMode.sourceNote).font(.caption).foregroundStyle(.secondary) } }
            }
        }
        .task { do { entries = try await store.entries(instance, relative: relative) } catch { failure = error.localizedDescription; store.audit("目录读取失败 · " + error.localizedDescription) }; loading = false }
    }
    private func toggle(_ path: String) {
        store.preview = nil; store.mappings = []
        if store.selections.contains(path) { store.selections.remove(path) }
        else { store.selections = store.selections.filter { !$0.hasPrefix(path + "/") && !path.hasPrefix($0 + "/") }; store.selections.insert(path) }
    }
}
struct MappingView: View {
    @EnvironmentObject var store: AppStore
    struct MappingSelection: Identifiable { let path: String; var id: String { path } }
    @State private var mappingSource: MappingSelection?
    @State private var showPreview = false
    @State private var manualSource: String?
    @State private var manualTarget = ""
    var body: some View {
        Screen {
            SectionLabel(title: "确认数据去向", detail: "\(store.selections.count) 项")
            Label(store.transferMode.title, systemImage: store.transferMode.symbol).font(.title3.weight(.semibold)).foregroundStyle(Color.xctAccent)
            Text(store.transferMode.explanation).font(.subheadline).foregroundStyle(.secondary)
            ForEach(store.selections.sorted(), id: \.self) { path in
                mappingCard(path)
            }
            Text("默认写入目标应用的对应位置。点击目标卡片浏览目录，也可手动输入相对路径。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 9) { Image(systemName: "slider.horizontal.3").foregroundStyle(Color.xctAccent); Text("迁移直接操作所选内容，不自动备份。插件配置可在配置页单独手动保存。").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            for path in store.selections where !store.mappings.contains(where: { $0.source == path }) { setTarget(path, for: path) }
            store.mappings.removeAll { !store.selections.contains($0.source) }
        }
        .navigationTitle("位置映射").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BottomAction {
            Button { Task { await store.prepareMigration(); if store.preview != nil { showPreview = true } } } label: { HStack { if store.busy { SwiftUI.ProgressView().tint(.white) }; Text(store.busy ? "正在检查目录…" : "检查并继续") } }.buttonStyle(PrimaryButton()).disabled(store.mappings.count != store.selections.count || store.selections.isEmpty || store.busy)
        } }
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
        let destination = store.mappings.first(where: { $0.source == path })?.target ?? path
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text("来源位置").font(.caption).foregroundStyle(.secondary)
                    Text(path).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button { mappingSource = MappingSelection(path: path) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.xctAccent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(destination == path ? "目标位置 · 对应路径" : "目标位置 · 自定义").font(.caption).foregroundStyle(.secondary)
                        Text(destination).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.xctAccent)
                }.padding(15).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).contentShape(Rectangle())
                    .background(Color.xctAccent.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.xctAccent.opacity(0.15), lineWidth: 0.7))
            }.buttonStyle(.plain).accessibilityIdentifier("mapTarget-" + path)
            Button { manualSource = path; manualTarget = destination } label: {
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
                }.buttonStyle(.plain).foregroundStyle(Color.xctAccent).accessibilityIdentifier("samePath-" + path)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 20))
    }
    private func setTarget(_ target: String, for source: String) {
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
                    Text(byteText(plan.bytes)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("\(plan.files) 个文件 · \(plan.mode.title)").font(.subheadline).foregroundStyle(.secondary)
                }
                Panel {
                    InfoRow(title: "1 · 来源 · \(plan.sourceName)", value: plan.sourceBundleID)
                    Divider()
                    InfoRow(title: "2 · 目标 · \(plan.targetName)", value: plan.targetBundleID)
                    ForEach(plan.mappings) { m in Text(m.source + " → " + m.target).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(plan.mode.sourceNote, systemImage: plan.mode.symbol).foregroundStyle(Color.xctAccent)
                    Label("不自动备份插件配置", systemImage: "slider.horizontal.3")
                    Label("不创建完整聊天备份", systemImage: "externaldrive.badge.xmark")
                }.font(.footnote).padding(.horizontal, 2)
                Panel {
                    Text("覆盖前确认").font(.subheadline.weight(.semibold))
                    Text(plan.mode.explanation + " 已执行的操作不能自动整任务回滚；文件完成不保证应用内数据兼容。").font(.caption).foregroundStyle(.secondary)
                    Toggle("两个应用均已退出", isOn: $closedApps).font(.subheadline)
                    Toggle("确认执行所选操作", isOn: $acceptsOverwrite).font(.subheadline)
                }
                Text(plan.mode == .exchange ? "转换用同文件系统原子交换，每组映射分别执行；若目标不存在则移动到目标。系统不支持时终止，不降级为全量复制。" : "文件以单个临时文件写入、校验后覆盖；需要最大单文件及目标增长的空间，不生成完整聊天备份。").font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("请重新检查目录", systemImage: "folder", description: Text("任务已执行或选择发生变化。")) }
        }
        .navigationTitle("确认迁移").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BottomAction {
            Button("开始迁移") { confirm = true }.buttonStyle(PrimaryButton()).disabled(!closedApps || !acceptsOverwrite || store.preview == nil || store.busy)
        } }
        .alert("执行所选文件操作？", isPresented: $confirm) {
            Button("确认开始迁移", role: .destructive) { store.startMigration(confirmed: true) }; Button("取消", role: .cancel) {}
        } message: { Text(store.transferMode == .exchange ? "两边所选数据会互换。多组映射中断时可能只完成部分交换，请按任务记录核对。" : "不会备份目标聊天记录。目标可能部分更新；来源保留。") }
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
                    Text(store.busy ? (store.operationIsMigration ? "正在迁移" : (store.operationIsConfigurationRestore ? "正在应用配置" : "正在保存配置")) : (store.operationSucceeded ? (store.operationIsMigration ? "文件迁移完成" : (store.operationIsConfigurationRestore ? "配置已应用" : "插件配置已保存")) : "操作未完成")).font(.title2.weight(.semibold))
                }.padding(.vertical, 28).frame(maxWidth: .infinity)
                if let p = store.progress {
                    Panel {
                        Text(p.stage).font(.subheadline.weight(.medium))
                        if let fraction = store.estimate.fraction {
                            SwiftUI.ProgressView(value: fraction)
                            HStack {
                                Text(fraction, format: .percent.precision(.fractionLength(0))).font(.headline.monospacedDigit())
                                Spacer()
                                if let remaining = store.estimate.remaining { Text("预计剩余 " + OperationEstimate.timeText(remaining)) }
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
                if store.operationFinished && !store.operationSucceeded {
                    Text(store.message ?? "操作未完成，两边可能已部分更新；请核对任务记录。").font(.subheadline).foregroundStyle(.orange)
                    DisclosureGroup("查看完整诊断", isExpanded: $expandedDiagnostic) {
                        DiagnosticReportView(text: store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic).frame(height: 320)
                    }.font(.subheadline)
                } else {
                    Text(store.operationIsMigration ? "文件操作完成后，请在两边应用内核对内容。转换会互换所选内容；文件校验不代表应用内兼容。" : "仅处理所选配置目录。请在应用退出时操作，并核对配置生效情况。").font(.subheadline).foregroundStyle(.secondary)
                }
            }.navigationTitle(store.operationIsMigration ? store.operationMode.title : "插件配置").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { BottomAction {
                if store.busy { Button("停止操作", role: .destructive) { store.cancel() }.frame(minHeight: 44); Text("停止不会回滚已覆盖的文件。").font(.caption2).foregroundStyle(.secondary) }
                else if !store.operationSucceeded {
                    HStack(spacing: 12) {
                        DiagnosticCopyButton(title: "复制诊断日志") { store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic }
                        ShareLink(item: store.diagnostic.isEmpty ? store.diagnosticText() : store.diagnostic) { Image(systemName: "square.and.arrow.up").font(.system(size: 20)).frame(width: 52, height: 52).background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 16)) }.accessibilityLabel("分享诊断日志")
                    }
                    Button("完成") { store.progress = nil; store.message = nil; store.showDiagnostic = false }.frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Button("完成") { store.progress = nil; store.message = nil; store.showDiagnostic = false }.buttonStyle(PrimaryButton())
                }
            } }
        }
    }
}
