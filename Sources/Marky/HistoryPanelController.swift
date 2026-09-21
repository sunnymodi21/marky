import AppKit
import SwiftUI

/// A floating, Spotlight-style window (separate from the menu-bar dropdown) that
/// shows the clipboard history. Opened by the global hotkey. Picking a clip
/// restores it to the clipboard and — when auto-paste is on and Accessibility is
/// granted — reactivates the previously focused app and synthesizes ⌘V so the
/// clip lands in whatever input box you were in.
@MainActor
final class HistoryPanelController: NSObject, ObservableObject, NSWindowDelegate {
    let settings: AppSettings
    let history: ClipboardHistoryStore
    let monitor: ClipboardMonitor
    let actions: ClipboardActions
    let permissions: AccessibilityPermissionManager

    /// Bound into the hosted view. The view flips this false (Esc, convert action,
    /// click-away) and that orders the window out.
    @Published var isPresented = false {
        didSet {
            guard oldValue != self.isPresented, !self.isPresented else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// App that was frontmost when the window opened — the paste target.
    private weak var previousApp: NSRunningApplication?
    private var panel: NSPanel?

    /// True briefly while presenting, so the activation race (status item / app
    /// activation momentarily taking key) doesn't trigger an immediate close.
    private var isActivating = false

    init(
        settings: AppSettings,
        history: ClipboardHistoryStore,
        monitor: ClipboardMonitor,
        actions: ClipboardActions,
        permissions: AccessibilityPermissionManager)
    {
        self.settings = settings
        self.history = history
        self.monitor = monitor
        self.actions = actions
        self.permissions = permissions
        super.init()
    }

    func toggle() {
        if self.isPresented {
            self.hide()
        } else {
            self.show()
        }
    }

    func show() {
        // Remember who to paste back into before we steal focus.
        self.previousApp = NSWorkspace.shared.frontmostApplication
        self.permissions.refresh()

        let panel = self.panel ?? self.makePanel()
        self.positionOnActiveScreen(panel)
        self.isActivating = true
        // Don't NSApp.activate: Marky is an accessory app with no menu bar, so
        // activating it would leave the previous app's menus on screen but inactive
        // (unresponsive). A non-activating panel becomes key for typing while the
        // user's app stays active underneath.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.isPresented = true
        // Release the resign-key guard once presentation has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.isActivating = false
        }
    }

    func hide() {
        self.isPresented = false
    }

    /// Called after the hosted view has restored a clip to the clipboard.
    func pick() {
        self.performPaste()
    }

    /// "Paste as" buttons already rewrote (and marked) the clipboard; just paste it.
    func pasteCurrent() {
        self.performPaste()
    }

    /// Closes the overlay and, when auto-paste is on, reactivates the previously
    /// focused app and synthesizes ⌘V. Direct-download builds need Accessibility;
    /// the App Store build uses System Events (Automation) instead.
    private func performPaste() {
        self.hide()

        guard self.settings.autoPasteEnabled else { return }

        #if !APPSTORE
        self.permissions.refresh()
        guard self.permissions.isTrusted else {
            // Clip is on the clipboard; prompt for the permission so it works next time.
            self.permissions.requestIfNeeded()
            return
        }
        #endif

        let target = self.previousApp
        target?.activate()
        // Let the target app regain focus before the synthetic keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteService.sendPasteCommand()
        }
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        OverlayPanelLayout.configure(panel, delegate: self)

        let hosting = NSHostingView(rootView: HistoryPanelRoot(controller: self))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.fitContent(panel)

        self.panel = panel
        return panel
    }

    /// Sizes the panel to the hosted content, clamped to sane bounds (the view's
    /// fittingSize can read 0 before first layout).
    private func fitContent(_ panel: NSPanel) {
        OverlayPanelLayout.fit(panel, width: 340, fallbackHeight: 480)
    }

    /// Centers horizontally and sits in the upper third of the screen with the cursor,
    /// clamped so the whole window stays on-screen.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        // Re-fit in case the content height changed (history grew/shrank).
        self.fitContent(panel)
        OverlayPanelLayout.position(panel)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Ignore the transient resign during presentation/activation.
        guard !self.isActivating else { return }
        // Click-away / focus loss closes the picker, like a popover.
        self.hide()
    }
}

/// Hosts the shared menu content inside the floating panel, wiring click/Return to
/// the paste flow instead of the menu-bar panel's copy-and-close behavior.
private struct HistoryPanelRoot: View {
    @ObservedObject var controller: HistoryPanelController

    var body: some View {
        OverlayPanelSurface {
            MenuContentView(
                settings: self.controller.settings,
                monitor: self.controller.monitor,
                history: self.controller.history,
                actions: self.controller.actions,
                isPresented: Binding(
                    get: { self.controller.isPresented },
                    set: { self.controller.isPresented = $0 }),
                surface: .overlay,
                onPick: { self.controller.pick() },
                onPasteCurrent: { self.controller.pasteCurrent() })
        }
    }
}
