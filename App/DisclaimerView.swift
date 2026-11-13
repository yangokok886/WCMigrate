import SwiftUI

/// An initial full-screen gate, deliberately not a dismissible sheet.
struct DisclaimerView: View {
    var accept: () -> Void
    @State private var reachedEnd = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.xctAccent)
                    .accessibilityHidden(true)
                Text("使用前，请先阅读")
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("WCMigrate 使用须知与免责声明")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 22)

            Divider()
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("本应用可以移动、覆盖和删除你选择的数据。开始前，请了解每种操作会带来什么结果，再决定是否使用。")
                            .font(.body.weight(.medium))

                        paragraph("1. 关于本应用", "WCMigrate 是独立的文件迁移与配置管理工具，与腾讯、微信及 Apple 无隶属或官方授权关系。本应用处理你选择的文件，不保证聊天记录、登录状态或插件在另一应用中一定可用；这些数据还可能依赖加密信息、钥匙串、共享容器及应用版本。")

                        paragraph("2. 先看清操作方式", "替换：目标所选路径中的原有内容会被整体替换，目标独有的内容也会被移除。\n合并：同名文件直接覆盖，目标独有的内容保留。\n转换：交换两边所选路径的内容。\n“保留原文件”默认关闭，迁移会移动来源数据；开启后改用复制，通常更慢。请以执行前显示的模式、开关和路径为准。被覆盖或删除的内容可能无法找回。")

                        paragraph("3. 暂存在哪里", "暂存数据和插件配置备份保存在 WCMigrate 自己的沙盒内。暂存时关闭“保留原文件”，来源中的对应数据也会被移走。删除 WCMigrate 会连同其中的本地数据一起删除。删除来源应用前，请确认暂存已完成、所需文件齐全，并自行保存重要数据的独立副本；暂存不等于外部备份。")

                        paragraph("4. 操作中请勿离开", "执行前请关闭涉及的其他应用，确认来源、目标、所选内容和可用空间。迁移、暂存或还原过程中，请勿离开当前页面、强制退出或同时改动相关文件。闪退、断电、空间不足、访问权限变化及系统或签名变化，都可能造成中断或部分完成。续传与恢复功能无法保证在所有情况下恢复数据。")

                        paragraph("5. 配置与使用范围", "请仅处理你有权访问和管理的数据。导入配置前，请确认文件来源可信；将配置应用到不同包名的应用时，可能需要适配 plist 文件名，自动改名也不保证插件完全兼容。请勿将本应用用于侵害他人隐私、未经授权获取数据或其他违法用途。")

                        paragraph("6. 风险与责任", "本应用按现有功能提供，无法承诺在所有设备、系统和数据规模下都稳定运行，也无法保证每次迁移都成功或数据绝不丢失。请根据数据的重要程度决定是否操作，并先用少量非重要文件验证。开发者会持续修复问题；本说明不排除依法不能排除的责任，也不限制你依法享有的权利。")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("阅读完毕")
                                .font(.headline).foregroundStyle(Color.xctAccent)
                            Text("点击“同意并进入”，表示你已阅读以上说明，了解移动、覆盖、删除及本地暂存的风险，并同意在此基础上使用 WCMigrate。不同意时，可直接退出应用。")
                        }
                        .accessibilityIdentifier("disclaimerEnd")
                    }
                    .font(.body).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(24).frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: DisclaimerBottomKey.self,
                                value: content.frame(in: .named("disclaimerScroll")).maxY)
                        }
                    }
                }
                .coordinateSpace(name: "disclaimerScroll")
                .accessibilityIdentifier("disclaimerScroll")
                .onPreferenceChange(DisclaimerBottomKey.self) { bottom in
                    // Geometry also handles content fitting without a scroll and VoiceOver scrolling.
                    if viewport.size.height > 0 && bottom > 0 && bottom <= viewport.size.height + 1 {
                        reachedEnd = true
                    }
                }
            }
            Divider()
            VStack(spacing: 12) {
                Text(reachedEnd ? "请确认你已了解以上操作风险" : "请向下滚动，阅读至文末后继续")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("disclaimerReadStatus")
                Button(action: accept) {
                    Label("同意并进入", systemImage: "checkmark")
                        .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 48)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(!reachedEnd)
                .accessibilityIdentifier("acceptDisclaimer")
                .accessibilityHint(reachedEnd ? "同意使用须知并进入应用" : "阅读至正文最底部后可用")
            }
            .frame(maxWidth: 640).padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color.xctBackground)
        .interactiveDismissDisabled()
    }

    private func paragraph(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct DisclaimerBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
