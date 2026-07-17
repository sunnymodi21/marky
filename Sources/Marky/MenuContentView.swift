import AppKit
import KeyboardShortcuts
import MarkyCore
import SwiftUI

/// Which host the shared content view is rendering in. The two surfaces differ
/// in what a pick does (copy-and-close vs paste into the prior app) and whether
/// the convert/"Paste as" controls are shown (overlay only).
enum MenuSurface {
    /// The menu-bar dropdown: picking an entry copies it and closes the panel.
    case menuDropdown
    /// The standalone floating history window: picking an entry pastes it.
    case overlay
}

/// Window-style menu bar panel: search bar pinned on top, history list below,
/// then convert actions and settings. (.menu style can't host a TextField.)
struct MenuContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var history: ClipboardHistoryStore
    let actions: ClipboardActions
    @Binding var isPresented: Bool

    var surface: MenuSurface = .menuDropdown

    /// Overlay only: invoked after a clip is restored to the clipboard so the
    /// host can paste it (⌘V) into the previously focused app.
    var onPick: ((ClipboardEntry) -> Void)?

    /// Overlay only: pastes whatever is currently on the clipboard into the
    /// previously focused app. Used by the "Paste as" format buttons after
    /// they rewrite the clipboard.
    var onPasteCurrent: (() -> Void)?

    /// History entry currently being OCRed (shows a spinner on that row).
    @State private var recognizingEntryID: UUID?

    /// Entry that was just copied (shows a brief checkmark before closing).
    @State private var copiedEntryID: UUID?

    /// Text clipping currently being edited in the non-destructive editor.
    @State private var editingClip: EditableClip?

    @State private var showClearConfirmation = false

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Index of the keyboard-selected history entry, or nil when navigating
    /// away (e.g. editing the search field).
    @State private var selectedIndex: Int?

    /// ScrollViewProxy captured from the history ScrollView for scroll-to-selection.
    @State private var scrollProxy: ScrollViewProxy?

    /// Recreating the history scroll view on presentation prevents SwiftUI from
    /// preserving an older visible row when newer entries were inserted above it.
    @State private var scrollResetID = UUID()

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
    /// Accounts for section headers and any expanded rows.
    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 38
        let headerHeight: CGFloat = 24
        var total: CGFloat = CGFloat(self.results.count) * rowHeight + 8
        total += CGFloat(self.sectionHeaderCount) * headerHeight
        return min(280, total)
    }

    private var sectionHeaderCount: Int {
        guard !self.results.isEmpty else { return 0 }
        var count = 0
        for index in self.results.indices {
            if self.sectionHeader(for: index, in: self.results) != nil {
                count += 1
            }
        }
        return count
    }

    var body: some View {
        Group {
            if let clip = self.editingClip {
                ClipEditorView(
                    originalText: clip.text,
                    canPaste: self.surface == .overlay,
                    onBack: { self.dismissEditor() },
                    onCopy: { self.commitEdit($0, paste: false) },
                    onPaste: { self.commitEdit($0, paste: true) })
            } else {
                VStack(spacing: 0) {
                    self.searchBar

                    if self.settings.historyEnabled {
                        Divider()
                        self.historyList
                    }

                    // Convert/paste actions live only in the standalone paste overlay,
                    // not the menu-bar dropdown.
                    if self.surface == .overlay {
                        Divider()
                        self.controls
                    }
                    Divider()
                    self.footer
                }
            }
        }
        .frame(width: 340)
        .alert("Clear all history?", isPresented: self.$showClearConfirmation) {
            Button("Clear", role: .destructive) {
                self.history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all clippings. This cannot be undone.")
        }
        .onChange(of: self.isPresented) { _, presented in
            if presented {
                self.query = ""
                self.selectedIndex = nil
                self.scrollProxy = nil
                self.scrollResetID = UUID()
                self.searchFocused = true
            }
        }
        .onAppear { self.searchFocused = true }
        .background {
            if self.surface == .overlay {
                OverlayKeyEventMonitor { event in
                    self.handleOverlayKeyDown(event)
                }
            }
        }
        .onKeyPress(.downArrow) {
            guard self.editingClip == nil else { return .ignored }
            self.moveSelection(.down)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard self.editingClip == nil else { return .ignored }
            self.moveSelection(.up)
            return .handled
        }
        .onKeyPress(.return) {
            guard self.editingClip == nil else { return .ignored }
            if let index = self.selectedIndex, self.results.indices.contains(index) {
                self.copy(self.results[index])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if self.editingClip != nil {
                self.dismissEditor()
            } else {
                self.isPresented = false
            }
            return .handled
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: self.$query)
                .textFieldStyle(.plain)
                .focused(self.$searchFocused)
                .onChange(of: self.query) { _, _ in
                    self.selectedIndex = nil
                }
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
            VStack(spacing: 8) {
                Image(systemName: self.isSearching ? "magnifyingglass" : "doc.on.clipboard")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(self.isSearching ? "No clippings match \"\(self.query)\"" : "No clippings yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !self.isSearching {
                    Text("Copy anything and it will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(self.results.enumerated()), id: \.element.id) { index, entry in
                            if let header = self.sectionHeader(for: index, in: self.results) {
                                Text(header)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                            HistoryRow(
                                title: self.history.title(for: entry),
                                date: entry.date,
                                thumbnail: self.history.thumbnail(for: entry),
                                fullText: self.fullText(for: entry),
                                isRecognizing: self.recognizingEntryID == entry.id,
                                isCopied: self.copiedEntryID == entry.id,
                                isSelected: self.selectedIndex == index,
                                isPinned: entry.pinned,
                                isMarkdown: entry.isMarkdown,
                                action: { self.copy(entry) },
                                onCopyText: self.isImage(entry) ? { self.copyTextFromImage(entry) } : nil,
                                onCopyRich: self.fullText(for: entry) != nil ? { self.copyAsRichText(entry) } : nil,
                                onEdit: self.fullText(for: entry) != nil ? { self.edit(entry) } : nil,
                                onPin: { self.history.togglePin(entry) },
                                onDelete: { self.history.delete(entry) })
                            .id(entry.id)
                        }
                    }
                    .padding(4)
                }
                .frame(height: self.listHeight)
                .onAppear { self.scrollProxy = proxy }
            }
            .id(self.scrollResetID)

            HStack {
                Text(
                    self.isSearching
                        ? "\(self.results.count) of \(self.history.entries.count) clippings"
                        : "Click a clipping to copy it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") {
                    self.showClearConfirmation = true
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
        // Overlay: place the clip on the clipboard, then hand off to the host to
        // paste into the prior app. When auto-convert is on and the clip is
        // Markdown, paste it as rich text; otherwise paste it verbatim.
        if self.surface == .overlay {
            if self.settings.autoConvertEnabled,
               case let .text(text) = entry.content,
               entry.isMarkdown,
               self.actions.convertTextToRichText(text)
            {
                // convertTextToRichText wrote rich text to the clipboard (and marked it).
            } else {
                self.history.restore(entry, to: .general)
            }
            self.onPick?(entry)
            return
        }
        self.history.restore(entry, to: .general)
        self.copiedEntryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.copiedEntryID = nil
            self.isPresented = false
        }
    }

    // MARK: - Keyboard navigation

    /// The focused search field can consume navigation keys before SwiftUI's
    /// ancestor `onKeyPress` handlers see them. The standalone panel therefore
    /// monitors its own AppKit key events and routes the picker commands here.
    private func handleOverlayKeyDown(_ event: NSEvent) -> Bool {
        let commandModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard commandModifiers.isEmpty else { return false }

        switch event.keyCode {
        case 125: // Down Arrow
            guard self.editingClip == nil else { return false }
            self.moveSelection(.down)
        case 126: // Up Arrow
            guard self.editingClip == nil else { return false }
            self.moveSelection(.up)
        case 36, 76: // Return and numeric-keypad Enter
            guard self.editingClip == nil else { return false }
            if let index = self.selectedIndex, self.results.indices.contains(index) {
                self.copy(self.results[index])
            }
        case 53: // Escape
            if self.editingClip != nil {
                self.dismissEditor()
            } else {
                self.isPresented = false
            }
        default:
            return false
        }

        return true
    }

    private func moveSelection(_ direction: Direction) {
        guard !self.results.isEmpty else { return }

        let current = self.selectedIndex ?? -1
        let next: Int

        switch direction {
        case .down:
            next = min(current + 1, self.results.count - 1)
        case .up:
            if current <= 0 {
                // At the top: return focus to the search field.
                self.selectedIndex = nil
                self.searchFocused = true
                return
            }
            next = current - 1
        }

        self.selectedIndex = next
        self.searchFocused = false

        // Scroll the selected row into view via ScrollViewReader.
        DispatchQueue.main.async {
            self.scrollToSelection()
        }
    }

    private func scrollToSelection() {
        guard let index = self.selectedIndex, self.results.indices.contains(index) else { return }
        self.scrollProxy?.scrollTo(self.results[index].id, anchor: .center)
    }

    private enum Direction {
        case up, down
    }

    private func isImage(_ entry: ClipboardEntry) -> Bool {
        if case .image = entry.content { return true }
        return false
    }

    /// Full text of a text entry for the expand/preview, or nil for images.
    private func fullText(for entry: ClipboardEntry) -> String? {
        if case let .text(text) = entry.content { return text }
        return nil
    }

    /// Returns a section header label when this index starts a new date/pin group, nil otherwise.
    private func sectionHeader(for index: Int, in entries: [ClipboardEntry]) -> String? {
        let entry = entries[index]
        let prev = index > 0 ? entries[index - 1] : nil

        if entry.pinned {
            if prev?.pinned != true { return "Pinned" }
            return nil
        }

        let category = Self.dateCategory(entry.date)
        if prev?.pinned == true {
            return category
        }
        if let prev = prev, Self.dateCategory(prev.date) == category {
            return nil
        }
        return category
    }

    private static func dateCategory(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) { return "This Week" }
        return "Older"
    }

    /// OCRs an image clipping (Vision, on-device) and copies the recognized text.
    private func copyTextFromImage(_ entry: ClipboardEntry) {
        guard self.recognizingEntryID == nil,
              let pngData = self.history.pngData(for: entry)
        else { return }
        self.recognizingEntryID = entry.id

        Task {
            defer { self.recognizingEntryID = nil }
            let text = (try? await ImageTextRecognizer.recognizeText(pngData: pngData)) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self.actions.writePlainText(text)
            self.history.recordText(text)
            self.isPresented = false
        }
    }

    /// Converts a text history entry to rich text and writes it to the clipboard.
    private func copyAsRichText(_ entry: ClipboardEntry) {
        guard case let .text(text) = entry.content else { return }
        if self.actions.convertTextToRichText(text) {
            self.isPresented = false
        }
    }

    /// Opens a non-destructive editor for a text clipping. Saving writes a new
    /// clipping; the original history entry is never mutated.
    private func edit(_ entry: ClipboardEntry) {
        guard case let .text(text) = entry.content else { return }
        self.editingClip = EditableClip(id: entry.id, text: text)
    }

    private func dismissEditor() {
        self.editingClip = nil
    }

    private func commitEdit(_ text: String, paste: Bool) {
        self.actions.copyEditedText(text, recordingIn: self.history)
        self.dismissEditor()

        if paste {
            self.pasteCurrent()
        } else {
            self.isPresented = false
        }
    }

    /// After a "Paste as" button rewrites the clipboard, paste it into the prior app
    /// (overlay) or just close (defensive fallback).
    private func pasteCurrent() {
        if let onPasteCurrent = self.onPasteCurrent {
            onPasteCurrent()
        } else {
            self.isPresented = false
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto-convert Markdown", isOn: self.$settings.autoConvertEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Text("Paste as")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Button {
                    self.actions.convertToRichText()
                    self.pasteCurrent()
                } label: {
                    Label("Rich Text", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity)
                }
                .help("Paste the clipboard Markdown as formatted rich text")

                Button {
                    self.actions.restoreOriginal()
                    self.pasteCurrent()
                } label: {
                    Label("Markdown", systemImage: "doc.plaintext")
                        .frame(maxWidth: .infinity)
                }
                .help("Paste the original Markdown text")

                Button {
                    self.actions.copyPlainText()
                    self.pasteCurrent()
                } label: {
                    Label("Plain Text", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .help("Paste with all formatting stripped")
            }
            .controlSize(.small)
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

            if self.monitor.conversionCount > 0 {
                Text("\(self.monitor.conversionCount) converted")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("v\(Bundle.main.shortVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

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
    var fullText: String?
    var isRecognizing = false
    var isCopied = false
    var isSelected = false
    var isPinned = false
    var isMarkdown = false
    let action: () -> Void
    var onCopyText: (() -> Void)?
    var onCopyRich: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: self.action) {
                HStack(spacing: 8) {
                    if let thumbnail = self.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if self.isMarkdown {
                        Image(systemName: "doc.richtext")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else if self.isRecognizing {
                        ProgressView()
                            .controlSize(.small)
                    } else if self.hovering {
                        if let onCopyText = self.onCopyText {
                            Button {
                                onCopyText()
                            } label: {
                                Image(systemName: "text.viewfinder")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy text from image (OCR)")
                        }
                        if let onEdit = self.onEdit {
                            Button {
                                onEdit()
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Edit this clipping")
                        }
                        if let onPin = self.onPin {
                            Button {
                                onPin()
                            } label: {
                                Image(systemName: self.isPinned ? "pin.fill" : "pin")
                                    .foregroundStyle(self.isPinned ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(self.isPinned ? "Unpin" : "Pin to top")
                        }
                        Button {
                            self.onDelete()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this clipping")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.expanded, let text = self.fullText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(self.isSelected ? Color.accentColor.opacity(0.2)
                    : (self.hovering ? Color.primary.opacity(0.08) : Color.clear)))
        .onHover { self.hovering = $0 }
        .contextMenu {
            if let onEdit = self.onEdit {
                Button("Edit…") { onEdit() }
            }
            if let onCopyText = self.onCopyText {
                Button("Copy Text from Image") { onCopyText() }
            }
            if let onCopyRich = self.onCopyRich {
                Button("Copy as Rich Text") { onCopyRich() }
            }
            if self.fullText != nil {
                Button(self.expanded ? "Collapse" : "Expand Preview") { self.expanded.toggle() }
            }
            if let onPin = self.onPin {
                Button(self.isPinned ? "Unpin" : "Pin to Top") { onPin() }
            }
            Button("Delete", role: .destructive) { self.onDelete() }
        }
    }
}

// MARK: - Clipping editor

private struct EditableClip: Identifiable {
    let id: UUID
    let text: String
}

private struct ClipEditorView: View {
    let originalText: String
    let canPaste: Bool
    let onBack: () -> Void
    let onCopy: (String) -> Void
    let onPaste: (String) -> Void

    @State private var text: String
    @FocusState private var editorFocused: Bool

    init(
        originalText: String,
        canPaste: Bool,
        onBack: @escaping () -> Void,
        onCopy: @escaping (String) -> Void,
        onPaste: @escaping (String) -> Void)
    {
        self.originalText = originalText
        self.canPaste = canPaste
        self.onBack = onBack
        self.onCopy = onCopy
        self.onPaste = onPaste
        self._text = State(initialValue: originalText)
    }

    private var canCommit: Bool {
        self.text != self.originalText
            && !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: self.onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Text("Edit Clipping")
                .font(.headline)

            TextEditor(text: self.$text)
                .font(.body)
                .focused(self.$editorFocused)
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(4)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }

            HStack {
                Text("\(self.text.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Copy Edited") {
                    self.onCopy(self.text)
                }
                .disabled(!self.canCommit)
                .keyboardShortcut(
                    self.canPaste ? nil : KeyboardShortcut(.return, modifiers: .command))

                if self.canPaste {
                    Button("Paste Edited") {
                        self.onPaste(self.text)
                    }
                    .disabled(!self.canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(16)
        .onAppear { self.editorFocused = true }
    }
}
