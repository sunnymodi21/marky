import AppKit
import SwiftUI

/// Non-activating panel shared by Marky's floating overlays.
final class FloatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum OverlayPanelLayout {
    static func configure(_ panel: NSPanel, delegate: NSWindowDelegate? = nil) {
        panel.becomesKeyOnlyIfNeeded = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = delegate
    }

    static func fit(_ panel: NSPanel, width: CGFloat, fallbackHeight: CGFloat, maxHeight: CGFloat = 760) {
        let fittingHeight = panel.contentView?.fittingSize.height ?? 0
        let height = fittingHeight > 120 ? fittingHeight : fallbackHeight
        panel.setContentSize(NSSize(width: width, height: min(height, maxHeight)))
    }

    static func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let proposedY = frame.maxY - frame.height * 0.12 - size.height
        let y = max(frame.minY + 8, min(proposedY, frame.maxY - size.height - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Shared material and shape for standalone overlay content.
struct OverlayPanelSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        self.content
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Observes key-down events for the NSWindow hosting this representable.
///
/// SwiftUI's `onKeyPress` is sufficient in the menu-bar dropdown, but the
/// standalone non-activating panel hosts a focused NSTextField that handles
/// arrows and Escape before ancestor views receive them. A window-scoped local
/// monitor lets the overlay handle picker commands without stealing ordinary
/// typing or events destined for another Marky window.
struct OverlayKeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: self.onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onKeyDown = self.onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
        }

        func start() {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let monitoredWindow = self.view?.window,
                      event.window === monitoredWindow
                else { return event }

                return self.onKeyDown(event) ? nil : event
            }
        }

        func stop() {
            guard let monitor = self.monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

    }
}
