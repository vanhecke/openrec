import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var allowsHitTesting: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        allowsHitTesting: Bool = true
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.allowsHitTesting = allowsHitTesting
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view: NSVisualEffectView = allowsHitTesting
            ? NSVisualEffectView()
            : PassThroughVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Decorative blur. Left in the hit-test chain, this AppKit view eats the
/// click before SwiftUI can start a window drag on the chrome above it.
private final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
