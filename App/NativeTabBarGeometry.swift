import SwiftUI
import UIKit

/// Reads the native bar's actual item frames for the product tour, without styling or replacing it.
struct NativeTabBarGeometry: UIViewRepresentable {
    var blocked: Bool
    var onFrames: ([CGRect]) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.blocked = blocked
        view.onFrames = onFrames
        view.setNeedsLayout()
    }

    final class Probe: UIView {
        var blocked = false
        var onFrames: (([CGRect]) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            // UIKit completes the tab controller layout after its SwiftUI children.
            DispatchQueue.main.async { [weak self] in self?.readBar() }
        }
        private func readBar() {
            guard let window, let bar = findBar(in: window), let items = bar.items,
                  items.count == AppPage.allCases.count else { return }
            bar.isUserInteractionEnabled = !blocked
            let controls = bar.subviews.compactMap { $0 as? UIControl }
                .filter { !$0.isHidden && $0.bounds.width > 0 }
                .sorted { $0.frame.midX < $1.frame.midX }
            for (index, item) in items.enumerated() {
                let identifier = "tab-" + AppPage.allCases[index].rawValue
                item.accessibilityIdentifier = identifier
                if controls.count == items.count { controls[index].accessibilityIdentifier = identifier }
            }
            let frames: [CGRect]
            if controls.count == items.count {
                frames = controls.map { $0.convert($0.bounds, to: self) }
            } else {
                // A system version may host the controls deeper in its view hierarchy.
                let bounds = bar.bounds.insetBy(dx: 8, dy: 0)
                let width = bounds.width / CGFloat(items.count)
                frames = items.indices.map { index in
                    bar.convert(CGRect(x: bounds.minX + CGFloat(index) * width, y: bounds.minY,
                                       width: width, height: min(bounds.height, 56)), to: self)
                }
            }
            onFrames?(frames)
        }
        private func findBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar, !bar.isHidden, bar.alpha > 0 { return bar }
            for child in view.subviews {
                if let bar = findBar(in: child) { return bar }
            }
            return nil
        }
    }
}
