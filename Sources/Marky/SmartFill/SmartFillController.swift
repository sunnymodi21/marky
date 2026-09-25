import AppKit
import ApplicationServices
import SwiftUI

/// Clipboard → AX scan → GLiNER schema from those fields → fill.
/// The shortcut is the confirmation.
@MainActor
final class SmartFillController: NSObject, ObservableObject, NSWindowDelegate {
    enum Phase {
        case working(String)
        case accessibilityRequired(String)
        case error(String)
    }

    private let pasteboard: PasteboardService
    private let policy: ClipboardPolicy
    private let permissions: AccessibilityPermissionManager
    private let gliner: GLiNERService

    @Published private(set) var phase: Phase = .working("Looking for form fields…") {
        didSet {
            guard self.panel?.isVisible == true else { return }
            DispatchQueue.main.async { [weak self] in self?.layoutPanel() }
        }
    }

    private var panel: NSPanel?
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var isActivating = false

    init(
        pasteboard: PasteboardService,
        policy: ClipboardPolicy,
        permissions: AccessibilityPermissionManager,
        gliner: GLiNERService = GLiNERService())
    {
        self.pasteboard = pasteboard
        self.policy = policy
        self.permissions = permissions
        self.gliner = gliner
        super.init()
    }

    func start() {
        self.cancelWork()
        self.phase = .working("Looking for form fields…")

        self.permissions.refresh()
        guard self.permissions.isTrusted else {
            self.phase = .accessibilityRequired(SmartFillError.accessibilityDenied.localizedDescription)
            self.showPanel()
            self.permissions.requestIfNeeded()
            return
        }

        let clipboard: String
        let scan: AccessibilityFormScanner.Result
        do {
            clipboard = try ClipboardReader.readText(from: self.pasteboard, policy: self.policy)
            scan = try AccessibilityFormScanner.scanFrontmostApp()
        } catch {
            self.fail(error)
            return
        }

        // Sensitive controls never enter the extraction schema. Besides being
        // safer, this prevents unrelated secure fields from changing decoding.
        let fillableFields = scan.fields.filter { !SensitiveFieldDetector.isSensitive($0.snapshot) }
        let snapshots = fillableFields.map(\.snapshot)
        let elements = Dictionary(uniqueKeysWithValues: fillableFields.map { ($0.snapshot.id, $0.element) })
        self.showPanel()
        self.phase = .working("Filling form…")

        let gliner = self.gliner
        let workID = UUID()
        self.workID = workID
        self.work = Task { [weak self] in
            guard let self else { return }
            do {
                let extracted = try await gliner.extract(
                    text: clipboard,
                    fields: FieldContextBuilder.extractionFields(snapshots))
                { message in
                    Task { @MainActor [weak self] in
                        guard self?.workID == workID else { return }
                        self?.phase = .working(message)
                    }
                }
                try Task.checkCancellation()
                guard self.workID == workID else { return }
                self.phase = .working("Filling form…")
                let pairs = FieldContextBuilder.assignments(fields: snapshots, extracted: extracted)
                let assignments = pairs.compactMap { pair -> (element: AXUIElement, value: String)? in
                    guard let element = elements[pair.fieldID] else { return nil }
                    return (element, pair.value)
                }
                guard !assignments.isEmpty else {
                    self.work = nil
                    self.workID = nil
                    self.phase = .error("No confident matches to fill.")
                    return
                }
                self.work = nil
                self.workID = nil
                self.hide()
                scan.app.activate()
                try await Task.sleep(for: .milliseconds(80))
                await AccessibilityFormWriter(pasteboard: self.pasteboard).fill(assignments)
            } catch is CancellationError {
                if self.workID == workID {
                    self.work = nil
                    self.workID = nil
                }
            } catch {
                guard self.workID == workID else { return }
                self.work = nil
                self.workID = nil
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        self.cancelWork()
        self.hide()
    }

    private func cancelWork() {
        self.workID = nil
        self.work?.cancel()
        self.work = nil
    }

    func requestAccessibility() {
        self.permissions.requestIfNeeded()
    }

    func openAccessibilitySettings() {
        self.permissions.openSystemSettings()
    }

    private func fail(_ error: Error) {
        self.phase = .error(error.localizedDescription)
        self.showPanel()
    }

    private func hide() {
        self.panel?.orderOut(nil)
    }

    private func showPanel() {
        let panel = self.panel ?? self.makePanel()
        self.layoutPanel()
        self.isActivating = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isActivating = false
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        OverlayPanelLayout.configure(panel, delegate: self)
        let hosting = NSHostingView(rootView: SmartFillStatusView(controller: self))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func layoutPanel() {
        guard let panel = self.panel else { return }
        OverlayPanelLayout.fit(panel, width: 380, fallbackHeight: 160, maxHeight: 360)
        OverlayPanelLayout.position(panel)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !self.isActivating else { return }
        self.cancel()
    }
}

private struct SmartFillStatusView: View {
    @ObservedObject var controller: SmartFillController

    var body: some View {
        OverlayPanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(.tint)
                    Text("Smart Fill").font(.headline)
                }

                switch self.controller.phase {
                case let .working(message):
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(message).foregroundStyle(.secondary)
                    }
                case let .accessibilityRequired(message):
                    Text(message).foregroundStyle(.secondary)
                    HStack {
                        Button("Grant Accessibility…") { self.controller.requestAccessibility() }
                        Button("Open Settings") { self.controller.openAccessibilitySettings() }
                    }
                    .controlSize(.small)
                case let .error(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { self.controller.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
        .background {
            OverlayKeyEventMonitor { event in
                guard event.keyCode == 53 else { return false }
                self.controller.cancel()
                return true
            }
        }
    }
}
