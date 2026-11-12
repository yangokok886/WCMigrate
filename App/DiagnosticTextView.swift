import SwiftUI
import UIKit

/// Keep large, selectable reports in a bounded native scrolling text view.
/// A single unbounded SwiftUI Text can leave a very tall blank layout on device.
struct DiagnosticTextView: UIViewRepresentable {
    var text: String
    var accessibilityID = "diagnosticBody"
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        view.textContainer.lineBreakMode = .byCharWrapping
        view.accessibilityIdentifier = accessibilityID
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityIdentifier = accessibilityID
        if view.text != text { view.text = text }
    }
}

struct DiagnosticReportView: View {
    private let pages: [String]
    var accessibilityID: String
    @State private var page = 0
    init(text: String, accessibilityID: String = "diagnosticBody") {
        pages = DiagnosticPages.split(text)
        self.accessibilityID = accessibilityID
    }
    var body: some View {
        VStack(spacing: 4) {
            DiagnosticTextView(text: pages[min(page, pages.count - 1)], accessibilityID: accessibilityID)
            if pages.count > 1 {
                HStack(spacing: 12) {
                    Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(page == 0).accessibilityLabel("上一页")
                    Text("第 \(min(page + 1, pages.count)) / \(pages.count) 页").font(.caption).foregroundStyle(.secondary)
                    Button { page = min(pages.count - 1, page + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(page >= pages.count - 1).accessibilityLabel("下一页")
                    Spacer(minLength: 0)
                    Button("末页") { page = pages.count - 1 }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier(accessibilityID + "-lastPage")
                }
            }
        }.onChange(of: pages) { _, _ in page = 0 }
    }
}
