import KeyboardShortcuts
import MarkyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: AccessibilityPermissionManager

    var body: some View {
        TabView {
            GeneralPane(settings: self.settings, permissions: self.permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
        .padding()
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: AccessibilityPermissionManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("Auto-convert Markdown on copy", isOn: self.$settings.autoConvertEnabled)

            Picker("Detection sensitivity", selection: self.$settings.sensitivity) {
                ForEach(Sensitivity.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Text(self.sensitivityHelp)
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

            Divider()

            LabeledContent("Accessibility") {
                if self.permissions.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant…") {
                        self.permissions.requestIfNeeded()
                        self.permissions.openSystemSettings()
                    }
                }
            }
            Text("Required only for the paste hotkeys (synthetic ⌘V). Clipboard conversion works without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .onAppear { self.permissions.refresh() }
    }

    private var sensitivityHelp: String {
        switch self.settings.sensitivity {
        case .low: "Low: converts only clearly formatted Markdown (multiple strong cues)."
        case .normal: "Normal: converts typical Markdown like headings with lists or emphasis."
        case .high: "High: converts almost anything Markdown-shaped, even a lone heading."
        }
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
            KeyboardShortcuts.Recorder("Paste as Rich Text:", name: .pasteRichText)
            KeyboardShortcuts.Recorder("Paste Original Markdown:", name: .pasteOriginal)
            Text("Both shortcuts convert/restore the clipboard and then paste into the frontmost app.")
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
