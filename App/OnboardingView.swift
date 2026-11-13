import SwiftUI

enum AppPage: String, CaseIterable {
    case migration, configurations, staging, settings
    var title: String { switch self { case .migration: return "迁移"; case .configurations: return "插件配置"; case .staging: return "数据暂存"; case .settings: return "设置" } }
    var icon: String { switch self { case .migration: return "arrow.left.arrow.right"; case .configurations: return "slider.horizontal.3"; case .staging: return "tray.and.arrow.down"; case .settings: return "gearshape" } }
}

/// The tour owns demo choices only. Never passes them to any file operation service.
@MainActor final class ProductTour: ObservableObject {
    enum Step: String, CaseIterable {
        case source, sourceChoice, target, targetChoice, mode, files, documents, library, filesDone, next, check
        case configurationTab, configurationSave, configurationImport, stagingTab, stagingCreate, stagingSource, stagingChoice, stagingClosed, stagingAccepted, stagingStart, finish
        var copy: (String, String) {
            switch self {
            case .source: return ("先点原来的微信", "想搬哪个微信的数据，就先点这里选它。现在是演练，不会动你的聊天记录。")
            case .sourceChoice: return ("点这一个微信", "这只是示例应用。平时在这里找你原来的微信，掉签了也先别删。")
            case .target: return ("再点要搬过去的微信", "这里选接收数据的应用。只有一个微信、准备重装？后面会带你看“数据暂存”。")
            case .targetChoice: return ("点接收数据的应用", "来源和目标要选清楚：数据从 1 到 2。这里也只是演示。")
            case .mode: return ("点一下“转换”", "转换就是两边互换；替换会清掉目标对应文件夹的旧内容；合并会保留目标里来源没有的文件，同名的覆盖。")
            case .files: return ("点这里选要搬的内容", "只会处理你勾选的文件或文件夹，不会自动把整个微信都搬走。")
            case .documents: return ("点左边的圆圈", "先勾选 Documents。微信的聊天数据通常在这里；点文件夹名字则是进去看里面的内容。")
            case .library: return ("再勾选 Library", "插件配置通常在 Library/Preferences 里。勾选整个 Library，就会带上里面的配置和其他文件。")
            case .filesDone: return ("点“完成”回去", "这两个目录只是演示列表，没有读取你的真实微信。")
            case .next: return ("点“下一步”看看去向", "选好应用、操作方式和内容后，下一步会让你核对数据放到哪里，还不会直接开始迁移。")
            case .check: return ("这里核对对应路径", "默认 Documents 对 Documents，Library 对 Library。实际操作还会检查权限，再让你确认。点这里结束这段演练，不会真的迁移。")
            case .configurationTab: return ("插件配置有单独的页面", "只想保存、分享或恢复插件设置，就点下面的“插件配置”，不用在迁移页面里找。")
            case .configurationSave: return ("保存配置从这里开始", "点这里选择应用，保存它的插件配置。只保存配置目录，不保存几十 GB 的聊天记录。这次点一下认识位置，不会真的备份。")
            case .configurationImport: return ("别人给的配置从这里导入", "这里可以选 plist 或 ZIP，导入后再选应用替换或合并。本地配置也可以左滑分享、删除。这次不会打开文件或导入数据。")
            case .stagingTab: return ("只有一个微信就点这里", "微信掉签又没有多开？先用“数据暂存”把数据搬出来，再重装微信。不要先删旧微信。")
            case .stagingCreate: return ("点这里建一份暂存", "暂存放在 WCMigrate 里面的独立文件夹，不会覆盖 WCMigrate 自己的设置。")
            case .stagingSource: return ("先选掉签的旧微信", "来源还是你手机上的旧应用。我们继续用示例演练，不读真实数据。")
            case .stagingChoice: return ("点这一个示例微信", "真正使用时选要重装的旧微信。暂存列表与迁移列表按相同规则排列，官方微信优先。")
            case .stagingClosed: return ("操作前先退出旧微信", "实际暂存前，把旧微信从后台划掉；WCMigrate 留在当前页面运行。演练中点一下这个开关。")
            case .stagingAccepted: return ("记住：暂存是搬走", "成功的内容会离开旧微信。暂存期间千万别卸载 WCMigrate，数据就保存在它里面。点一下确认。")
            case .stagingStart: return ("最后才检查并暂存", "点这个按钮结束演练，不会移动数据。真正使用时，等全部显示“已暂存”再重装；装好后从暂存记录选新微信迁回。")
            case .finish: return ("你已经走过一遍了", "迁移管两个应用间搬数据；插件配置管设置文件；数据暂存管单个微信重装。退出演练后，刚才的示例选择会全部清掉。")
            }
        }
    }
    @Published var page: AppPage = .migration
    @Published private(set) var step: Step?
    @Published private(set) var session = UUID()
    @Published var source: AppInstance?
    @Published var target: AppInstance?
    @Published var selections: Set<String> = []
    @Published var mode: TransferMode = .replace
    var active: Bool { step != nil }
    var index: Int { step.flatMap { Step.allCases.firstIndex(of: $0) } ?? 0 }
    static let original = AppInstance(id: "tour-original", displayName: "微信 · 演示", bundleIdentifier: "com.tencent.xin", root: URL(fileURLWithPath: "/tour-never-read/original"), origin: "导览示例")
    static let clone = AppInstance(id: "tour-clone", displayName: "微信多开 · 演示", bundleIdentifier: "com.tencent.qy.xin", root: URL(fileURLWithPath: "/tour-never-read/clone"), origin: "导览示例")
    func start() { source = nil; target = nil; selections = []; mode = .replace; page = .migration; session = UUID(); step = .source }
    func advance(_ expected: Step) {
        guard step == expected, let index = Step.allCases.firstIndex(of: expected), index + 1 < Step.allCases.count else { return }
        step = Step.allCases[index + 1]
    }
    func finish() { step = nil; source = nil; target = nil; selections = []; mode = .replace; page = .migration; session = UUID() }
}

private struct TourTarget {
    let bounds: Anchor<CGRect>
    let action: (() -> Void)?
}
private struct TourAnchors: PreferenceKey {
    static let defaultValue: [String: TourTarget] = [:]
    static func reduce(value: inout [String: TourTarget], nextValue: () -> [String: TourTarget]) { value.merge(nextValue(), uniquingKeysWith: { _, latest in latest }) }
}
extension View {
    func tourTarget(_ name: String, action: (() -> Void)? = nil) -> some View { anchorPreference(key: TourAnchors.self, value: .bounds) { [name: TourTarget(bounds: $0, action: action)] }.id(name) }
    func productTourOverlay() -> some View { modifier(ProductTourOverlay()) }
}
private struct ProductTourOverlay: ViewModifier {
    @EnvironmentObject var tour: ProductTour
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourAnchors.self) { anchors in
            GeometryReader { geo in
                if let step = tour.step, let anchor = anchors[step.rawValue] {
                    TourSpotlight(rect: geo[anchor.bounds], size: geo.size, onNext: {
                        if let action = anchor.action { action() } else { tour.advance(step) }
                    }).environmentObject(tour)
                }
            }.allowsHitTesting(tour.step.map { anchors[$0.rawValue] != nil } ?? false)
        }.transformPreference(TourAnchors.self) { $0 = [:] }
    }
}
private struct SpotlightMask: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect); path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14)); return path
    }
}
private struct TourSpotlight: View {
    @EnvironmentObject var tour: ProductTour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var rect: CGRect
    var size: CGSize
    var onNext: () -> Void
    @State private var bubbleHeight: CGFloat = 230
    private var hole: CGRect { rect.insetBy(dx: -5, dy: -5) }
    private var below: Bool { rect.midY < size.height * 0.48 }
    private var bubbleY: CGFloat {
        let ideal = below ? hole.maxY + 14 + bubbleHeight / 2 : hole.minY - 14 - bubbleHeight / 2
        return min(max(bubbleHeight / 2 + 10, ideal), max(bubbleHeight / 2 + 10, size.height - bubbleHeight / 2 - 10))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Forward spotlight taps through the same demo action as the Next button. The rest blocks taps.
            SpotlightMask(hole: hole).fill(Color.black.opacity(0.68), style: FillStyle(eoFill: true))
                .contentShape(SpotlightMask(hole: hole), eoFill: true).onTapGesture {}.accessibilityHidden(true)
            RoundedRectangle(cornerRadius: 14).stroke(Color.white, lineWidth: 2)
                .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY).allowsHitTesting(false)
            Color.clear.frame(width: hole.width, height: hole.height)
                .contentShape(Rectangle()).position(x: hole.midX, y: hole.midY)
                .onTapGesture { if tour.step != .finish { onNext() } }.accessibilityHidden(true)
            if let step = tour.step {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("操作演练 · 不动真实数据", systemImage: "hand.point.up.left.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.xctAccent)
                        Spacer()
                        Text("\(tour.index + 1)/\(ProductTour.Step.allCases.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(step.copy.0).font(.title3.weight(.bold)).accessibilityIdentifier("tourTitle")
                    Text(step.copy.1).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("退出导览") { tour.finish() }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44).accessibilityIdentifier("skipOnboarding")
                        Spacer()
                        if step == .finish {
                            Button("完成导览") { tour.finish() }.buttonStyle(TourNextButton()).accessibilityIdentifier("finishTour")
                        } else {
                            Button(action: onNext) { Label("下一步", systemImage: "arrow.right") }.buttonStyle(TourNextButton()).accessibilityIdentifier("tourNext")
                        }
                    }
                }.padding(18).frame(width: min(size.width - 28, 390)).liquidSurface(cornerRadius: 22)
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                    .background(GeometryReader { bubble in Color.clear.onAppear { bubbleHeight = bubble.size.height }.onChange(of: bubble.size.height) { _, h in bubbleHeight = h } })
                    .position(x: size.width / 2, y: bubbleY)
                    .accessibilityElement(children: .contain)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tour.step)
    }
}

private struct TourNextButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20).frame(minHeight: 46)
        }.buttonStyle(LiquidActionStyle(prominent: true))
    }
}

/// Uses the same picker row layout, with local examples instead of querying app containers.
struct TourApplicationPicker: View {
    @EnvironmentObject var tour: ProductTour
    var choice: ProductTour.Step
    var select: (AppInstance) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        let app = choice == .targetChoice ? ProductTour.clone : ProductTour.original
                        select(app); tour.advance(choice)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "message.fill").font(.title2).foregroundStyle(.white).frame(width: 42, height: 42).background(Color.xctAction, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(choice == .targetChoice ? ProductTour.clone.displayName : ProductTour.original.displayName).font(.headline).foregroundStyle(.primary)
                                Text(choice == .targetChoice ? ProductTour.clone.bundleIdentifier : ProductTour.original.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(minHeight: 60).contentShape(Rectangle())
                    }.buttonStyle(.plain).tourTarget(choice.rawValue, action: {
                        select(choice == .targetChoice ? ProductTour.clone : ProductTour.original); tour.advance(choice)
                    }).accessibilityIdentifier("tourApplicationChoice")
                } footer: { Text("仅供导览演练，不会检测或读取真实应用。") }
            }.navigationTitle(choice == .targetChoice ? "目标应用" : "来源应用").navigationBarTitleDisplayMode(.inline)
        }.productTourOverlay().interactiveDismissDisabled(tour.active)
    }
}
