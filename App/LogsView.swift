import SwiftUI

private struct ActivityLine: Identifiable {
    let id: Int
    let raw: String
    var parts: [String] { raw.components(separatedBy: " · ") }
    var date: String { parts.count > 1 ? parts[0] : "运行记录" }
    var title: String { parts.count > 1 ? parts[1] : raw }
    var detail: String { parts.dropFirst(2).joined(separator: " · ") }
    var failed: Bool { raw.contains("终止") || raw.contains("失败") || raw.contains("错误") }
    var category: String { failed ? "异常" : (raw.contains("配置") || raw.contains("Preferences") ? "配置" : "迁移") }
    var symbol: String { failed ? "exclamationmark.circle" : (category == "配置" ? "slider.horizontal.3" : "arrow.left.arrow.right") }
}
struct LogsView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var category = "全部"
    @State private var selected: ActivityLine?
    private var lines: [ActivityLine] {
        store.logs.enumerated().map { ActivityLine(id: $0.offset, raw: $0.element) }.filter {
            (category == "全部" || $0.category == category) && (query.isEmpty || $0.raw.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("每一步，都有记录").font(.title2.weight(.bold))
                        Text("共 \(store.logs.count) 条 · 按最新时间排列").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "text.alignleft").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.xctAccent)
                        .frame(width: 54, height: 54).background(Color.xctAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                }
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索操作、路径或错误", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("logSearch")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清除搜索") }
                    }.padding(14).background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 14))
                    Picker("日志分类", selection: $category) {
                        ForEach(["全部", "迁移", "配置", "异常"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("logCategory")
                }
                VStack(spacing: 0) {
                    NavigationLink { RawLogView() } label: {
                        toolRow("原始诊断", detail: "授权、容器和图标来源", icon: "doc.text.magnifyingglass")
                    }.buttonStyle(.plain).accessibilityIdentifier("rawDiagnostics")
                    Divider().padding(.leading, 54)
                    Button { Task { await store.probeIconCache() } } label: {
                        toolRow(store.probingIconCache ? "正在探测图标缓存…" : "检测图标缓存（只读）", detail: "查看当前权限与文件格式", icon: "square.stack.3d.up")
                    }.buttonStyle(.plain).accessibilityLabel("检测图标缓存（只读）").disabled(store.probingIconCache || store.busy || store.scanning)
                }.background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 18))
                SectionLabel(title: "操作记录", detail: "\(lines.count) 条")
                if lines.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: query.isEmpty ? "clock" : "magnifyingglass").font(.system(size: 28, weight: .light))
                        Text(query.isEmpty && category == "全部" ? "暂无运行记录" : "没有匹配的记录").font(.subheadline)
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(lines) { line in
                            Button { selected = line } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: line.symbol).font(.system(size: 18)).foregroundStyle(line.failed ? Color.orange : Color.xctAccent)
                                        .frame(width: 36, height: 36).background((line.failed ? Color.orange : Color.xctAccent).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(line.date).font(.caption).foregroundStyle(.secondary)
                                        Text(line.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        if !line.detail.isEmpty { Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 14)
                                }.padding(15).background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("logEntry-\(line.id)")
                        }
                    }
                }
            }.frame(maxWidth: 640).padding(20).frame(maxWidth: .infinity)
        }.background(Color.xctBackground).scrollIndicators(.hidden)
            .navigationTitle("运行日志").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                BottomAction {
                    HStack(spacing: 12) {
                        DiagnosticCopyButton(title: "复制完整诊断日志") { store.diagnosticText() }
                        ShareLink(item: store.diagnosticText()) { Image(systemName: "square.and.arrow.up").font(.system(size: 20)).frame(width: 52, height: 52).background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 16)) }.accessibilityLabel("分享诊断日志")
                    }
                }
            }
            .sheet(item: $selected) { line in
                NavigationStack {
                    ScrollView { Text(line.raw).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                        .navigationTitle("记录详情").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { selected = nil } } }
                        .safeAreaInset(edge: .bottom) { BottomAction { DiagnosticCopyButton(title: "复制这条记录") { line.raw } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
    private func toolRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Color.xctAccent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 72).contentShape(Rectangle())
    }
}
private struct RawLogView: View {
    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    @State private var report = ""
    var body: some View {
        Screen {
            Panel {
                Label("诊断摘要", systemImage: "stethoscope").font(.headline)
                InfoRow(title: "容器读取", value: store.accessMessage)
                InfoRow(title: "App Group", value: store.group)
            }
            Panel {
                DisclosureGroup("查看原始授权与图标日志", isExpanded: $expanded) {
                    if report.isEmpty {
                        Text("本次启动暂无原始授权与图标日志。检测应用或图标后，点击刷新。").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        Text("\(report.utf8.count) 字节 · 可在下方独立滚动与选择").font(.caption).foregroundStyle(.secondary)
                        DiagnosticReportView(text: report, accessibilityID: "rawDiagnosticBody").frame(height: 360)
                    }
                    Button("刷新原始日志") { report = XCTContainerBridge.diagnostics() }.frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("refreshRawDiagnostic")
                }.font(.subheadline.weight(.medium))
            }
        }.navigationTitle("原始诊断").navigationBarTitleDisplayMode(.inline)
            .task { report = XCTContainerBridge.diagnostics() }
    }
}
