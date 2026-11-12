import SwiftUI

extension Color {
    static let xctAction = Color(red: 0.035, green: 0.49, blue: 0.38)
    static let xctAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.78, blue: 0.63, alpha: 1)
            : UIColor(red: 0.035, green: 0.49, blue: 0.38, alpha: 1)
    })
    static let xctSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let xctBackground = Color(uiColor: .systemGroupedBackground)
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.xctSurface, in: RoundedRectangle(cornerRadius: 20))
    }
}
struct Screen<Content: View>: View {
    var bottomPadding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) { content }.frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 18).padding(.bottom, bottomPadding).frame(maxWidth: .infinity) }
            .background(Color.xctBackground).scrollIndicators(.hidden)
    }
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 52)
            .foregroundStyle(.white).background(enabled ? Color.xctAction : Color(uiColor: .tertiaryLabel), in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
struct Badge: View {
    var text: String
    var body: some View { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5).background(Color.xctAccent.opacity(0.08), in: Capsule()).foregroundStyle(Color.xctAccent) }
}
struct InfoRow: View {
    var title: String; var value: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
}
struct SectionLabel: View {
    var title: String; var detail: String = ""
    var body: some View { HStack(alignment: .firstTextBaseline) { Text(title).font(.subheadline.weight(.semibold)); Spacer(); if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } }.padding(.horizontal, 2) }
}
struct BottomAction<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 9) { content }.frame(maxWidth: 640).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10).frame(maxWidth: .infinity).background(.bar) }
}
extension View {
    func transferGlass() -> some View { modifier(TransferGlassModifier()) }
}
private struct TransferGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color.xctSurface, in: Circle()) }
        else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) { content.glassEffect(.regular, in: .circle) }
            else { content.background(.regularMaterial, in: Circle()) }
            #else
            content.background(.regularMaterial, in: Circle())
            #endif
        }
    }
}
func byteText(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

struct PathActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color.primary).padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
