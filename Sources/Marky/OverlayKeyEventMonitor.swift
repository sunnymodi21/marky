import AppKit
import SwiftUI

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
