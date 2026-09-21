import KeyboardShortcuts
import MarkyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var permissions: AccessibilityPermissionManager
    @ObservedObject var updates: UpdateController

    var body: some View {
        TabView {
            GeneralPane(settings: self.settings, permissions: self.permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            HistoryPane(settings: self.settings, history: self.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutPane(conversionCount: self.monitor.conversionCount, updates: self.updates)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .padding()
    }
}

private struct HistoryPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistoryStore
    @State private var newPattern = ""

    var body: some View {
        let trimmedPattern = self.newPattern.trimmingCharacters(in: .whitespaces)
        let isPatternValid = !trimmedPattern.isEmpty
            && (try? NSRegularExpression(pattern: trimmedPattern, options: [])) != nil

        Form {
            Toggle("Keep clipboard history", isOn: self.$settings.historyEnabled)
            Text("Records text and images you copy. Click an entry in the menu to copy it back.")
                .settingsDescription()

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
                .settingsDescription()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ignore Patterns")
                    .font(.headline)
                Text("Clipboard text matching any regex pattern is skipped (no history, no auto-convert).")
                    .settingsDescription()

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
                    Button("Add") {
                        guard !self.settings.ignorePatterns.contains(trimmedPattern) else { return }
                        self.settings.ignorePatterns.append(trimmedPattern)
                        self.newPattern = ""
                    }
                    .disabled(!isPatternValid)
                }

                if !trimmedPattern.isEmpty, !isPatternValid {
                    Text("Invalid regex")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: AccessibilityPermissionManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    /// Running apps shown in the exclusion list (refreshed on appear).
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        Form {
            Toggle("Auto-convert Markdown on copy", isOn: self.$settings.autoConvertEnabled)
            Text("Converts copied text when it clearly looks like Markdown. Shell commands, source code, and bare URLs are left alone.")
                .settingsDescription()

            Divider()

            Stepper(
                "Output font size: \(self.settings.outputFontSize) px",
                value: self.$settings.outputFontSize,
                in: 10...20,
                step: 1)
            Text("Base text size for the converted rich text.")
                .settingsDescription()

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

            Toggle("Paste on click in the history window", isOn: self.$settings.autoPasteEnabled)
            #if APPSTORE
            Text("When you pick a clip in the floating history window (global shortcut), Marky pastes it into the app you were using. macOS may ask to allow Marky to control System Events the first time.")
                .settingsDescription()
            #else
            Text("When you pick a clip in the floating history window (global shortcut), Marky pastes it into the app you were using. Requires Accessibility permission.")
                .settingsDescription()

            if self.settings.autoPasteEnabled {
                HStack(spacing: 6) {
                    Image(systemName: self.permissions.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(self.permissions.isTrusted ? .green : .orange)
                    if self.permissions.isTrusted {
                        Text("Accessibility permission granted.")
                            .settingsDescription()
                    } else {
                        Text("Accessibility permission needed to paste.")
                            .settingsDescription()
                        Button("Grant…") { self.permissions.requestIfNeeded() }
                            .controlSize(.small)
                        Button("Open Settings") { self.permissions.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                .onAppear { self.permissions.refresh() }
            }
            #endif

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Excluded Apps")
                    .font(.headline)
                Text("Clipboard writes from these apps are skipped (no history, no auto-convert).")
                    .settingsDescription()

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(self.runningApps, id: \.bundleIdentifier) { app in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { self.permissions.refresh() }
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
            KeyboardShortcuts.Recorder("Smart Fill:", name: .smartFill)
            KeyboardShortcuts.Recorder("Convert to Rich Text:", name: .convertToRichText)
            KeyboardShortcuts.Recorder("Restore Original Markdown:", name: .restoreOriginal)
            KeyboardShortcuts.Recorder("Copy as Plain Text:", name: .copyPlainText)
            Text("Opens a floating history window. Use ↑↓ to navigate, Enter or click to paste the clip into the app you were using, Esc to close.")
                .settingsDescription()
            Text("Smart Fill defaults to ⌥⌘F. Its first use downloads the model from Marky; detection and filling then run entirely on-device. Requires Accessibility.")
                .settingsDescription()
            #if APPSTORE
            Text("Other shortcuts rewrite the clipboard (and show up in History); paste with ⌘V. Paste on click may ask to control System Events.")
                .settingsDescription()
            #else
            Text("Other shortcuts rewrite the clipboard (and show up in History); paste with ⌘V.")
                .settingsDescription()
            #endif
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsDescription() -> some View {
        self
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AboutPane: View {
    let conversionCount: Int
    @ObservedObject var updates: UpdateController
    #if !APPSTORE
    @State private var automaticallyChecksForUpdates: Bool
    #endif

    init(conversionCount: Int, updates: UpdateController) {
        self.conversionCount = conversionCount
        self.updates = updates
        #if !APPSTORE
        _automaticallyChecksForUpdates = State(initialValue: updates.updater.automaticallyChecksForUpdates)
        #endif
    }

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

            #if !APPSTORE
            Divider()
                .frame(width: 220)

            Button("Check for Updates…") {
                self.updates.checkForUpdates()
            }
            .disabled(!self.updates.canCheckForUpdates)
            .controlSize(.regular)

            Toggle("Automatically check for updates", isOn: self.$automaticallyChecksForUpdates)
                .onChange(of: self.automaticallyChecksForUpdates) { _, newValue in
                    self.updates.updater.automaticallyChecksForUpdates = newValue
                }
                .toggleStyle(.checkbox)
                .font(.caption)
            #endif

            Divider()
                .frame(width: 220)

            HStack(spacing: 12) {
                if let url = URL(string: "https://marky.click/privacy") {
                    Link("Privacy Policy", destination: url)
                        .font(.caption)
                }
                if let url = URL(string: "https://marky.click") {
                    Link("Website", destination: url)
                        .font(.caption)
                }
            }

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
