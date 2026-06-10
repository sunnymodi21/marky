import AppKit
import MenuBarExtraAccess
import QuartzCore
import SwiftUI

@main
@MainActor
struct MarkyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var permissions: AccessibilityPermissionManager
    @StateObject private var monitor: ClipboardMonitor
    @StateObject private var hotkeys: HotkeyManager
    @State private var isMenuPresented = false
    @State private var statusItem: NSStatusItem?

    init() {
        let settings = AppSettings()
        let permissions = AccessibilityPermissionManager()
        let monitor = ClipboardMonitor(settings: settings)
        monitor.start()
        let hotkeys = HotkeyManager(settings: settings, monitor: monitor, permissions: permissions)
        _settings = StateObject(wrappedValue: settings)
        _permissions = StateObject(wrappedValue: permissions)
        _monitor = StateObject(wrappedValue: monitor)
        _hotkeys = StateObject(wrappedValue: hotkeys)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                settings: self.settings,
                monitor: self.monitor,
                permissions: self.permissions,
                hotkeys: self.hotkeys)
            Divider()
            Button("Quit Marky") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            StatusLabel(isEnabled: self.settings.autoConvertEnabled)
        }
        .menuBarExtraAccess(isPresented: self.$isMenuPresented) { item in
            self.statusItem = item
            self.applyStatusItemAppearance()
        }
        .onChange(of: self.settings.autoConvertEnabled) { _, _ in
            self.applyStatusItemAppearance()
        }
        .onChange(of: self.monitor.convertPulseID) { _, _ in
            self.pulseStatusItem()
        }

        Settings {
            SettingsView(settings: self.settings, permissions: self.permissions)
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
