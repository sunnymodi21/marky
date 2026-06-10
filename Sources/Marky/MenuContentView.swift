import KeyboardShortcuts
import MarkyCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var permissions: AccessibilityPermissionManager
    let hotkeys: HotkeyManager

    var body: some View {
        Toggle("Auto-Convert Markdown", isOn: self.$settings.autoConvertEnabled)

        if !self.monitor.lastSummary.isEmpty {
            Text("Last: \(self.monitor.lastSummary)")
        }

        Divider()

        Button("Paste as Rich Text to \(self.monitor.frontmostAppName)") {
            self.hotkeys.pasteRichTextNow()
        }

        Button("Paste Original Markdown") {
            self.hotkeys.pasteOriginalNow()
        }

        Button("Convert Clipboard Now") {
            self.monitor.convertClipboardIfNeeded(force: true)
        }

        Divider()

        Picker("Sensitivity", selection: self.$settings.sensitivity) {
            ForEach(Sensitivity.allCases, id: \.self) { level in
                Text(level.displayName).tag(level)
            }
        }

        if !self.permissions.isTrusted {
            Divider()
            Button("Grant Accessibility Permission…") {
                self.permissions.requestIfNeeded()
                self.permissions.openSystemSettings()
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
