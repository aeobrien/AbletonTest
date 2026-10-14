#if os(macOS)
import SwiftUI
import AppKit

// View modifier that embeds an NSView catching scroll-wheel events
private struct ScrollWheelModifier: ViewModifier {
    let handler: (NSEvent) -> Void
    func body(content: Content) -> some View {
        content.background(ScrollWheelCatcher(onScroll: handler))
    }
}

// NSViewRepresentable that forwards NSEvent .scrollWheel to SwiftUI
private struct ScrollWheelCatcher: NSViewRepresentable {
    final class HostView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
            // Don’t call super to avoid unintended ScrollView interactions.
        }
    }

    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        v.postsFrameChangedNotifications = false
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        nsView.onScroll = onScroll
    }
}

// ✅ Public SwiftUI-style API that mirrors your existing usage
extension View {
    /// Receive raw macOS scroll-wheel events anywhere in a view hierarchy.
    func onScrollWheel(_ handler: @escaping (NSEvent) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}
#endif
