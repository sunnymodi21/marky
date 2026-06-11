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
    @StateObject private var hotkeys: HotkeyManager
    @State private var isMenuPresented = false
    @State private var statusItem: NSStatusItem?

    init() {
        let settings = AppSettings()
        let history = ClipboardHistoryStore(settings: settings)
        let monitor = ClipboardMonitor(settings: settings, history: history)
        monitor.start()
        let hotkeys = HotkeyManager(monitor: monitor)
        _settings = StateObject(wrappedValue: settings)
        _history = StateObject(wrappedValue: history)
        _monitor = StateObject(wrappedValue: monitor)
        _hotkeys = StateObject(wrappedValue: hotkeys)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                settings: self.settings,
                monitor: self.monitor,
                history: self.history,
                hotkeys: self.hotkeys,
                isPresented: self.$isMenuPresented)
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
            SettingsView(settings: self.settings, history: self.history)
        }
        .windowResizability(.contentSize)
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
            Image(systemName: "doc.richtext")
                .symbolRenderingMode(.hierarchical)
        }
        .opacity(self.isEnabled ? 1.0 : 0.45)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
