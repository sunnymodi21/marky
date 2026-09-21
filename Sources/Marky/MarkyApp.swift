import AppKit
import MenuBarExtraAccess
import QuartzCore
import SwiftUI

@main
@MainActor
struct MarkyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var history: ClipboardHistoryStore
    @StateObject private var monitor: ClipboardMonitor
    @StateObject private var actions: ClipboardActions
    @StateObject private var hotkeys: HotkeyManager
    @StateObject private var permissions: AccessibilityPermissionManager
    @StateObject private var historyPanel: HistoryPanelController
    @StateObject private var smartFill: SmartFillController
    @StateObject private var updates: UpdateController
    @State private var isMenuPresented = false
    @State private var statusItem: NSStatusItem?

    init() {
        let settings = AppSettings()
        let pasteboardService = PasteboardService()
        let policy = ClipboardPolicy(settings: settings)
        let history = ClipboardHistoryStore(settings: settings)
        let monitor = ClipboardMonitor(
            settings: settings,
            pasteboardService: pasteboardService,
            policy: policy,
            history: history)
        monitor.start()
        let actions = ClipboardActions(monitor: monitor, pasteboard: pasteboardService)
        let hotkeys = HotkeyManager(actions: actions)
        let permissions = AccessibilityPermissionManager()
        let historyPanel = HistoryPanelController(
            settings: settings,
            history: history,
            monitor: monitor,
            actions: actions,
            permissions: permissions)
        let smartFill = SmartFillController(
            pasteboard: pasteboardService,
            policy: policy,
            permissions: permissions)
        hotkeys.onOpenHistory = { [weak historyPanel] in historyPanel?.toggle() }
        hotkeys.onSmartFill = { [weak smartFill] in smartFill?.start() }
        _settings = StateObject(wrappedValue: settings)
        _history = StateObject(wrappedValue: history)
        _monitor = StateObject(wrappedValue: monitor)
        _actions = StateObject(wrappedValue: actions)
        _hotkeys = StateObject(wrappedValue: hotkeys)
        _permissions = StateObject(wrappedValue: permissions)
        _historyPanel = StateObject(wrappedValue: historyPanel)
        _smartFill = StateObject(wrappedValue: smartFill)
        _updates = StateObject(wrappedValue: UpdateController())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                settings: self.settings,
                monitor: self.monitor,
                history: self.history,
                actions: self.actions,
                isPresented: self.$isMenuPresented,
                surface: .menuDropdown)
        } label: {
            StatusLabel(isEnabled: self.settings.autoConvertEnabled)
        }
        // menuBarExtraAccess must come directly after MenuBarExtra (it extends
        // that scene type, not `some Scene`).
        .menuBarExtraAccess(isPresented: self.$isMenuPresented) { item in
            self.statusItem = item
            self.applyStatusItemAppearance()
        }
        // Window style so the panel can host a live search field
        // (native .menu style menus can't contain text input).
        .menuBarExtraStyle(.window)
        .onChange(of: self.settings.autoConvertEnabled) { _, _ in
            self.applyStatusItemAppearance()
        }
        .onChange(of: self.monitor.convertPulseID) { _, _ in
            self.pulseStatusItem()
        }
        Settings {
            SettingsView(
                settings: self.settings,
                history: self.history,
                monitor: self.monitor,
                permissions: self.permissions,
                updates: self.updates)
        }
        .windowResizability(.contentSize)
        #if !APPSTORE
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    self.updates.checkForUpdates()
                }
                .disabled(!self.updates.canCheckForUpdates)
            }
        }
        #endif
    }

    private func applyStatusItemAppearance() {
        self.statusItem?.button?.appearsDisabled = !self.settings.autoConvertEnabled
    }

    /// Brief opacity pulse on the status icon when a conversion happens.
    private func pulseStatusItem() {
        guard let button = self.statusItem?.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.opacity
        animation.toValue = max(0.25, layer.opacity * 0.4)
        animation.duration = 0.18
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.removeAnimation(forKey: "convertPulse")
        layer.add(animation, forKey: "convertPulse")
    }
}

private struct StatusLabel: View {
    var isEnabled: Bool

    var body: some View {
        Label {
            Text("Marky")
        } icon: {
            StatusIcon()
        }
        .opacity(self.isEnabled ? 1.0 : 0.45)
    }
}

private struct StatusIcon: View {
    var body: some View {
        Image(nsImage: StatusIconImage.image)
            .resizable()
            .interpolation(.high)
        .frame(width: 22, height: 18)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum StatusIconImage {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let accent = NSBezierPath(roundedRect: NSRect(x: 2.4, y: 8.3, width: 2.5, height: 5.2), xRadius: 1.25, yRadius: 1.25)
        accent.fill()

        let mark = NSBezierPath()
        mark.lineWidth = 3.05
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 7.1, y: 4.4))
        mark.line(to: NSPoint(x: 7.1, y: 10.2))
        mark.curve(
            to: NSPoint(x: 11.4, y: 10.2),
            controlPoint1: NSPoint(x: 7.1, y: 12.5),
            controlPoint2: NSPoint(x: 11.4, y: 12.5))
        mark.line(to: NSPoint(x: 11.4, y: 4.4))
        mark.move(to: NSPoint(x: 11.4, y: 10.2))
        mark.curve(
            to: NSPoint(x: 15.7, y: 10.2),
            controlPoint1: NSPoint(x: 11.4, y: 12.5),
            controlPoint2: NSPoint(x: 15.7, y: 12.5))
        mark.line(to: NSPoint(x: 15.7, y: 4.4))
        mark.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if WelcomeWindowController.hasBeenShown {
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Stay a regular app until the welcome window is dismissed so the
            // reviewer (and first-run users) can find Marky in the Dock.
            NSApp.setActivationPolicy(.regular)
            WelcomeWindowController.showIfNeeded()
        }
    }
}
