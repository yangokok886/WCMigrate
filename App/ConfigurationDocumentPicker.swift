import SwiftUI
import UniformTypeIdentifiers

/// Present once from a stable controller and deliver the result after actual dismissal.
/// No dependency on SwiftUI sheet onDismiss, which can be lost when the system picker closes itself.
struct ConfigurationDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (URL) -> Void
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, !context.coordinator.presenting else { return }
        context.coordinator.presenting = true
        DispatchQueue.main.async {
            guard controller.view.window != nil, controller.presentedViewController == nil else {
                context.coordinator.presenting = false
                context.coordinator.parent.isPresented = false
                context.coordinator.parent.onCancel()
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content, .zip, .propertyList], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            picker.delegate = context.coordinator
            controller.present(picker, animated: true)
        }
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: ConfigurationDocumentPicker
        var presenting = false
        init(parent: ConfigurationDocumentPicker) { self.parent = parent }
        private func finish(_ controller: UIDocumentPickerViewController, url: URL?) {
            let done = { [self] in
                presenting = false
                parent.isPresented = false
                if let url { parent.onPick(url) } else { parent.onCancel() }
            }
            if controller.presentingViewController != nil { controller.dismiss(animated: true, completion: done) }
            else { done() }
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(controller, url: urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(controller, url: nil) }
    }
}
