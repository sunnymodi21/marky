import AppKit
import SwiftUI

/// First-launch window so a reviewer (and new users) can find a menu-bar app
/// that otherwise has no Dock icon.
struct WelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Marky")
                        .font(.title2.bold())
                    Text("Copy Markdown, paste rich text.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Marky lives in the menu bar — look for its icon near the clock, at the top of the screen. Click that icon for clipboard history and settings. There is no Dock icon after this window.")
                .fixedSize(horizontal: false, vertical: true)

            Text("⌥⌘V opens the floating history window. Picking a clip copies it; with Paste on click enabled, Marky also pastes into the app you were using.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: "https://marky.click/privacy") {
                Link("Privacy Policy", destination: url)
            }

            HStack {
                Spacer()
                Button("Continue") {
                    self.onContinue()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

@MainActor
enum WelcomeWindowController {
    private static var window: NSWindow?
    private static let closeObserver = CloseObserver()
    private static var isDismissing = false

    static var hasBeenShown: Bool {
        UserDefaults.standard.bool(forKey: "didShowWelcome")
    }

    static func showIfNeeded() {
        guard !self.hasBeenShown else { return }

        let root = WelcomeView {
            self.dismiss()
        }
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Welcome to Marky"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self.closeObserver
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    static func dismiss() {
        guard !self.isDismissing else { return }
        self.isDismissing = true
        UserDefaults.standard.set(true, forKey: "didShowWelcome")
        let window = self.window
        self.window = nil
        window?.delegate = nil
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Marks the welcome as seen if the user closes the window with the traffic light.
private final class CloseObserver: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            WelcomeWindowController.dismiss()
        }
    }
}
