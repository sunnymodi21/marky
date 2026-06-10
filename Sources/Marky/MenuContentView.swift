import KeyboardShortcuts
import MarkyCore
import SwiftUI

/// Window-style menu bar panel: search bar pinned on top, history list below,
/// then convert actions and settings. (.menu style can't host a TextField.)
struct MenuContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var permissions: AccessibilityPermissionManager
    @ObservedObject var history: ClipboardHistoryStore
    let hotkeys: HotkeyManager
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var copiedEntryID: UUID?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !self.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// While searching, look through the full remembered history;
    /// otherwise show the usual display-limited recent clippings.
    private var results: [ClipboardEntry] {
        let matches = self.history.search(self.query)
        return self.isSearching
            ? matches
            : Array(matches.prefix(max(1, self.settings.historyDisplayLimit)))
    }

    /// ScrollView has no intrinsic height inside the MenuBarExtra panel and
    /// collapses to zero with only maxHeight, so size it from the row count.
    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 38
        return min(240, CGFloat(self.results.count) * rowHeight + 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            self.searchBar

            if self.settings.historyEnabled {
                Divider()
                self.historyList
            }

            Divider()
            self.controls
            Divider()
            self.footer
        }
        .frame(width: 340)
        .onChange(of: self.isPresented) { _, presented in
            if presented {
                self.query = ""
                self.searchFocused = true
            }
        }
        .onAppear { self.searchFocused = true }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: self.$query)
                .textFieldStyle(.plain)
                .focused(self.$searchFocused)
            if self.isSearching {
                Button {
                    self.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        if self.results.isEmpty {
            Text(self.isSearching ? "No clippings match \"\(self.query)\"." : "Copied items will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(self.results) { entry in
                        HistoryRow(
                            title: self.history.title(for: entry),
                            date: entry.date,
                            thumbnail: self.history.thumbnail(for: entry),
                            isCopied: self.copiedEntryID == entry.id)
                        {
                            self.copy(entry)
                        }
                    }
                }
                .padding(4)
            }
            .frame(height: self.listHeight)

            HStack {
                Text(
                    self.isSearching
                        ? "\(self.results.count) of \(self.history.entries.count) clippings"
                        : "Click a clipping to copy it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") {
                    self.history.clear()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func copy(_ entry: ClipboardEntry) {
        self.history.restore(entry, to: .general)
        self.copiedEntryID = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if self.copiedEntryID == entry.id {
                self.copiedEntryID = nil
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto-convert Markdown", isOn: self.$settings.autoConvertEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)

            if !self.monitor.lastSummary.isEmpty {
                Text("Last: \(self.monitor.lastSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("Copy clipboard as")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Button {
                    self.hotkeys.convertToRichTextNow()
                    self.isPresented = false
                } label: {
                    Text("Rich Text")
                        .frame(maxWidth: .infinity)
                }
                .help("Convert clipboard Markdown to formatted rich text")

                Button {
                    self.hotkeys.restoreOriginalNow()
                    self.isPresented = false
                } label: {
                    Text("Markdown")
                        .frame(maxWidth: .infinity)
                }
                .help("Restore the original Markdown to the clipboard")

                Button {
                    self.hotkeys.copyPlainTextNow()
                    self.isPresented = false
                } label: {
                    Text("Plain Text")
                        .frame(maxWidth: .infinity)
                }
                .help("Strip all formatting from the clipboard")
            }
            .controlSize(.small)

            if self.settings.autoPasteEnabled, !self.permissions.isTrusted {
                Button("Grant Accessibility Permission…") {
                    self.permissions.requestIfNeeded()
                    self.permissions.openSystemSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .simultaneousGesture(TapGesture().onEnded {
                self.isPresented = false
                NSApp.activate(ignoringOtherApps: true)
            })

            Spacer()

            Button("Quit Marky") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let title: String
    let date: Date
    let thumbnail: NSImage?
    let isCopied: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                if let thumbnail = self.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.title)
                        .lineLimit(1)
                    Text(self.date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if self.isCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(self.hovering ? Color.primary.opacity(0.08) : Color.clear))
        .onHover { self.hovering = $0 }
    }
}
