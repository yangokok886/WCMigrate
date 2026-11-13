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
            .liquidSurface(cornerRadius: 22)
    }
}
struct Screen<Content: View>: View {
    var tourStep: String? = nil
    var bottomPadding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView { VStack(alignment: .leading, spacing: 20) { content }.frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 18).padding(.bottom, bottomPadding).frame(maxWidth: .infinity) }
            .background { LiquidBackdrop() }.scrollIndicators(.hidden)
            .onChange(of: tourStep) { _, step in if let step { withAnimation { proxy.scrollTo(step, anchor: .center) } } }
        }
    }
}
/// System button styles retain native Liquid Glass interaction and accessibility.
struct PrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
        }.buttonStyle(LiquidActionStyle(prominent: true))
    }
}
struct LiquidActionStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent).tint(.xctAction).buttonBorderShape(.capsule)
            } else {
                Button(configuration).buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else { fallback(configuration) }
        #else
        fallback(configuration)
        #endif
    }
    private func fallback(_ configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(LegacyActionStyle(prominent: prominent))
    }
}
private struct LegacyActionStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 16).padding(.vertical, 2)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? (enabled ? Color.xctAction : Color(uiColor: .tertiaryLabel)) : Color.xctSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : (enabled ? 1 : 0.5))
    }
}
struct Badge: View {
    var text: String
    var body: some View { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5).liquidSurface(cornerRadius: 18, tint: .xctAccent.opacity(0.08)).foregroundStyle(Color.xctAccent) }
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
    var body: some View {
        VStack(spacing: 9) { content }.frame(maxWidth: 640)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(stops: [
                    .init(color: .xctBackground.opacity(0), location: 0),
                    .init(color: .xctBackground.opacity(0.97), location: 0.2),
                    .init(color: .xctBackground, location: 1)
                ], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom)
            }
    }
}
extension View {
    func transferGlass() -> some View { modifier(LiquidSurfaceModifier(shape: Circle(), interactive: true)) }
    func liquidSurface(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidSurfaceModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive))
    }
}
private struct LiquidSurfaceModifier<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color.xctSurface, in: shape) }
        else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            } else { content.background(.regularMaterial, in: shape) }
            #else
            content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}
/// A quiet backdrop provides depth while keeping long paths and diagnostics readable.
struct LiquidBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.xctBackground
            if !reduceTransparency {
                LinearGradient(colors: [Color.xctAccent.opacity(0.1), Color.clear, Color.blue.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
    }
}
func byteText(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

struct PathActionStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(Color.primary).font(.subheadline.weight(.medium))
                .padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(LiquidActionStyle())
    }
}
