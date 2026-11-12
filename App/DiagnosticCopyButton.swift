import SwiftUI
import UniformTypeIdentifiers

/// A full hit target, visible confirmation, and verified same-app clipboard write.
struct DiagnosticCopyButton: View {
    var title = "复制完整诊断"
    var text: () -> String
    @State private var copied = false
    @State private var failed = false
    var body: some View {
        VStack(spacing: 8) {
            Button {
                let value = text()
                guard !value.isEmpty else { failed = true; copied = false; return }
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
                copied = UIPasteboard.general.string == value
                failed = !copied
            } label: {
                Label(copied ? "已复制完整诊断" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            }.buttonStyle(PrimaryButton()).accessibilityIdentifier(title)
            if failed { Text("未能写入剪贴板，请使用分享导出日志。").font(.caption).foregroundStyle(.orange) }
        }.transaction { $0.animation = nil }
    }
}
