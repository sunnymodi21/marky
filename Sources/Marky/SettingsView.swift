import KeyboardShortcuts
import MarkyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore

    var body: some View {
        TabView {
            GeneralPane(settings: self.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            HistoryPane(settings: self.settings, history: self.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
        .padding()
    }
}

private struct HistoryPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore

    var body: some View {
        Form {
            Toggle("Keep clipboard history", isOn: self.$settings.historyEnabled)
            Text("Records text and images you copy. Click an entry in the menu to copy it back.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Stepper(
                "Remember \(self.settings.historyRememberLimit) clippings",
                value: self.$settings.historyRememberLimit,
                in: 5...500,
                step: 5)
            Stepper(
                "Display \(self.settings.historyDisplayLimit) in menu",
                value: self.$settings.historyDisplayLimit,
                in: 5...50,
                step: 5)

            Divider()

            LabeledContent("Stored clippings") {
                Text("\(self.history.entries.count)")
            }
            Button("Clear History", role: .destructive) {
                self.history.clear()
            }

            Text("Content marked confidential by password managers is never recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("Auto-convert Markdown on copy", isOn: self.$settings.autoConvertEnabled)
            Text("Converts copied text when it clearly looks like Markdown. Shell commands, source code, and bare URLs are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Launch at login", isOn: self.$launchAtLogin)
                .onChange(of: self.launchAtLogin) { _, newValue in
                    self.updateLaunchAtLogin(newValue)
                }
            if let error = self.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        }
        .padding(.vertical, 8)
    }

    private func updateLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.launchAtLoginError = nil
        } catch {
            self.launchAtLoginError = "Couldn't update login item (run from a bundled Marky.app)."
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Convert to Rich Text:", name: .convertToRichText)
            KeyboardShortcuts.Recorder("Restore Original Markdown:", name: .restoreOriginal)
            KeyboardShortcuts.Recorder("Copy as Plain Text:", name: .copyPlainText)
            Text("Shortcuts rewrite the clipboard (and show up in History); paste with ⌘V.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
            Text("Marky")
                .font(.title2.bold())
            Text("Copy Markdown, paste rich text.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.shortVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("MIT licensed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension Bundle {
    var shortVersion: String {
        (self.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
