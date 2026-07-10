import AppKit
import SwiftUI

/// A borderless/titled panel that can take key focus (for the search field) without
/// activating Marky — so the user's current app stays active and its menu bar
/// responsive while the overlay floats on top.
private final class FloatingHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

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
    let pasteboard: PasteboardService
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
        pasteboard: PasteboardService,
        actions: ClipboardActions,
        permissions: AccessibilityPermissionManager)
    {
        self.settings = settings
        self.history = history
        self.monitor = monitor
        self.pasteboard = pasteboard
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

    /// Called after the hosted view has already restored `entry` to the clipboard.
    /// Pastes it into the previously focused app when possible.
    func pick(_ entry: ClipboardEntry) {
        // The view's restore wrote plain text to the pasteboard; mark it as our own
        // so the monitor doesn't re-record or auto-convert it before we paste.
        self.pasteboard.markOwnWrite()
        self.performPaste()
    }

    /// "Paste as" buttons already rewrote (and marked) the clipboard; just paste it.
    func pasteCurrent() {
        self.performPaste()
    }

    /// Closes the overlay and, when auto-paste is on and Accessibility is granted,
    /// reactivates the previously focused app and synthesizes ⌘V.
    private func performPaste() {
        self.hide()

        guard self.settings.autoPasteEnabled else { return }

        self.permissions.refresh()
        guard self.permissions.isTrusted else {
            // Clip is on the clipboard; prompt for the permission so it works next time.
            self.permissions.requestIfNeeded()
            return
        }

        let target = self.previousApp
        target?.activate()
        // Let the target app regain focus before the synthetic keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteService.sendPasteCommand()
        }
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = FloatingHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // NOTE: .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive —
        // setting both raises an NSException. Pick one.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

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
        guard let hosting = panel.contentView else { return }
        let fitting = hosting.fittingSize
        let width: CGFloat = 340
        let height = (fitting.height > 120 ? fitting.height : 480)
        panel.setContentSize(NSSize(width: width, height: min(height, 760)))
    }

    /// Centers horizontally and sits in the upper third of the screen with the cursor,
    /// clamped so the whole window stays on-screen.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        // Re-fit in case the content height changed (history grew/shrank).
        self.fitContent(panel)
        let screen = self.screenWithCursor() ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // NSWindow origin is the bottom-left; place the window's TOP ~12% below the
        // screen top, then clamp so it never spills off either edge.
        let topInset = frame.height * 0.12
        let x = frame.midX - size.width / 2
        var y = frame.maxY - topInset - size.height
        y = max(frame.minY + 8, min(y, frame.maxY - size.height - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenWithCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
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
        MenuContentView(
            settings: self.controller.settings,
            monitor: self.controller.monitor,
            history: self.controller.history,
            actions: self.controller.actions,
            isPresented: Binding(
                get: { self.controller.isPresented },
                set: { self.controller.isPresented = $0 }),
            surface: .overlay,
            onPick: { self.controller.pick($0) },
            onPasteCurrent: { self.controller.pasteCurrent() })
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
