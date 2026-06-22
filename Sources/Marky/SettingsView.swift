import KeyboardShortcuts
import MarkyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject var monitor: ClipboardMonitor

    var body: some View {
        TabView {
            GeneralPane(settings: self.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            HistoryPane(settings: self.settings, history: self.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutPane(conversionCount: self.monitor.conversionCount)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
        .padding()
    }
}

private struct HistoryPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore
    @State private var newPattern = ""
    @State private var patternError: String?

    private var isNewPatternValid: Bool {
        let trimmed = self.newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: trimmed, options: [])) != nil
    }

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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ignore Patterns")
                    .font(.headline)
                Text("Clipboard text matching any regex pattern is skipped (no history, no auto-convert).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(self.settings.ignorePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button {
                            self.settings.ignorePatterns.removeAll { $0 == pattern }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("e.g. ^\\s*(?:AKIA|ghp_)", text: self.$newPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onChange(of: self.newPattern) { _, value in
                            let trimmed = value.trimmingCharacters(in: .whitespaces)
                            if trimmed.isEmpty {
                                self.patternError = nil
                            } else if (try? NSRegularExpression(pattern: trimmed, options: [])) == nil {
                                self.patternError = "Invalid regex"
                            } else {
                                self.patternError = nil
                            }
                        }
                    Button("Add") {
                        let trimmed = self.newPattern.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !self.settings.ignorePatterns.contains(trimmed) else { return }
                        self.settings.ignorePatterns.append(trimmed)
                        self.newPattern = ""
                        self.patternError = nil
                    }
                    .disabled(!self.isNewPatternValid)
                }

                if let error = self.patternError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    /// Running apps shown in the exclusion list (refreshed on appear).
    @State private var runningApps: [NSRunningApplication] = []
    @State private var appFilter = ""

    private var filteredApps: [NSRunningApplication] {
        let trimmed = self.appFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return self.runningApps }
        return self.runningApps.filter { app in
            (app.localizedName ?? "").lowercased().contains(trimmed)
        }
    }

    var body: some View {
        Form {
            Toggle("Auto-convert Markdown on copy", isOn: self.$settings.autoConvertEnabled)
            Text("Converts copied text when it clearly looks like Markdown. Shell commands, source code, and bare URLs are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Stepper(
                "Output font size: \(self.settings.outputFontSize) px",
                value: self.$settings.outputFontSize,
                in: 10...20,
                step: 1)
            Text("Base text size for the converted rich text.")
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Excluded Apps")
                    .font(.headline)
                Text("Clipboard writes from these apps are skipped (no history, no auto-convert).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Filter apps...", text: self.$appFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(self.filteredApps, id: \.bundleIdentifier) { app in
                            if let bundleID = app.bundleIdentifier, let name = app.localizedName {
                                Toggle(name, isOn: Binding(
                                    get: { !self.settings.excludedApps.contains(bundleID) },
                                    set: { isIncluded in
                                        if isIncluded {
                                            self.settings.excludedApps.removeAll { $0 == bundleID }
                                        } else {
                                            self.settings.excludedApps.append(bundleID)
                                        }
                                    }))
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)

                if self.runningApps.isEmpty {
                    Text("No running apps detected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .onAppear { self.refreshRunningApps() }
        }
        .padding(.vertical, 8)
    }

    private func refreshRunningApps() {
        self.runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
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
            KeyboardShortcuts.Recorder("Open Clipboard History:", name: .openHistory)
            KeyboardShortcuts.Recorder("Convert to Rich Text:", name: .convertToRichText)
            KeyboardShortcuts.Recorder("Restore Original Markdown:", name: .restoreOriginal)
            KeyboardShortcuts.Recorder("Copy as Plain Text:", name: .copyPlainText)
            Text("Open the panel with a global shortcut, then use ↑↓ to navigate, Enter to copy, Esc to close.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Other shortcuts rewrite the clipboard (and show up in History); paste with ⌘V.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct AboutPane: View {
    let conversionCount: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
            Text("Marky")
                .font(.title2.bold())
            Text("Copy Markdown, paste rich text.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(self.conversionCount) conversions this session")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("MIT licensed.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 220)

            HStack(spacing: 4) {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                if let url = URL(string: "mailto:sunnymodi21@proton.me") {
                    Link("Contact Developer", destination: url)
                        .font(.caption)
                } else {
                    Text("sunnymodi21@proton.me")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension Bundle {
    var shortVersion: String {
        (self.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var buildVersion: String {
        (self.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
