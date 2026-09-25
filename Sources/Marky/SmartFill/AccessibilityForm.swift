import AppKit
import ApplicationServices
import Foundation

/// Thin AX wrappers. String literals avoid the non-Sendable kAX* globals.
enum AX {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let help = "AXHelp"
    static let placeholder = "AXPlaceholderValue"
    static let value = "AXValue"
    static let identifier = "AXIdentifier"
    static let enabled = "AXEnabled"
    static let focused = "AXFocused"
    static let children = "AXChildren"
    static let parent = "AXParent"
    static let windows = "AXWindows"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let titleUIElement = "AXTitleUIElement"

    static func string(from element: AXUIElement, _ attribute: String) -> String? {
        guard let value = Self.copy(element, attribute) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (value as? NSNumber)?.stringValue
    }

    static func bool(from element: AXUIElement, _ attribute: String) -> Bool? {
        Self.copy(element, attribute) as? Bool
    }

    static func element(from element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = Self.copy(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(from element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = Self.copy(element, attribute) as? [AnyObject] else { return [] }
        return value.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return (child as! AXUIElement)
        }
    }

    static func size(from element: AXUIElement) -> CGSize? {
        guard let value = Self.copy(element, "AXSize"),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        let cf: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute as CFString, cf) == .success
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}

@MainActor
struct AccessibilityFormScanner {
    struct Result {
        var app: NSRunningApplication
        var fields: [FormField]
    }

    static func scanFrontmostApp() throws -> Result {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SmartFillError.noFrontmostApp
        }
        let fields = Self.scan(pid: app.processIdentifier)
        guard !fields.isEmpty else { throw SmartFillError.noFormFields }
        return Result(app: app, fields: fields)
    }

    static func scan(pid: pid_t) -> [FormField] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        // Chrome/Brave hide the page tree until these are set.
        AX.setBool(axApp, "AXEnhancedUserInterface", true)
        AX.setBool(axApp, "AXManualAccessibility", true)
        usleep(200_000)

        let window = AX.element(from: axApp, AX.focusedWindow)
            ?? AX.element(from: axApp, AX.mainWindow)
            ?? AX.elements(from: axApp, AX.windows).first
        guard let window else { return [] }
        return FormTreeScanner.scan(window: AXNode(element: window)).map {
            FormField(element: $0.node.element, snapshot: $0.snapshot)
        }
    }
}

struct AXNode: FormTreeNode {
    let element: AXUIElement

    func string(_ attribute: String) -> String? { AX.string(from: self.element, attribute) }
    func bool(_ attribute: String) -> Bool? { AX.bool(from: self.element, attribute) }
    func node(_ attribute: String) -> AXNode? { AX.element(from: self.element, attribute).map(AXNode.init) }
    var children: [AXNode] { AX.elements(from: self.element, AX.children).map(AXNode.init) }
    var width: Double? { AX.size(from: self.element).map { Double($0.width) } }
}

@MainActor
struct AccessibilityFormWriter {
    let pasteboard: PasteboardService

    func fill(_ assignments: [(element: AXUIElement, value: String)]) async {
        var failed: [(element: AXUIElement, value: String)] = []
        for assignment in assignments {
            if await Self.setValue(assignment.element, assignment.value) {
                continue
            }
            failed.append(assignment)
        }
        if !failed.isEmpty {
            await self.paste(failed)
        }
    }

    private static func setValue(_ element: AXUIElement, _ value: String) async -> Bool {
        guard AX.string(from: element, AX.value) == nil,
              AX.isSettable(element, AX.value)
        else { return false }

        // Some web controls route AXValue through the DOM-focused element.
        // Focus is best-effort because direct AX writes do not require the
        // system-wide focus identity exposed by keyboard fallback.
        AX.setBool(element, AX.focused, true)
        try? await Task.sleep(for: .milliseconds(40))
        return AX.setString(element, AX.value, value)
    }

    private func paste(_ assignments: [(element: AXUIElement, value: String)]) async {
        let saved = self.pasteboard.copyItems()
        defer { self.pasteboard.restoreItems(saved) }
        let systemWide = AXUIElementCreateSystemWide()

        for assignment in assignments {
            guard AX.setBool(assignment.element, AX.focused, true) else { continue }
            try? await Task.sleep(for: .milliseconds(80))
            // Never type unless the browser confirms that this exact control
            // received focus; otherwise fallback input could corrupt a field
            // that remained focused from the user's original click.
            guard AX.bool(from: assignment.element, AX.focused) == true,
                  let focused = AX.element(from: systemWide, "AXFocusedUIElement"),
                  CFEqual(focused, assignment.element)
            else { continue }
            PasteService.sendSelectAllCommand()
            try? await Task.sleep(for: .milliseconds(40))
            self.pasteboard.writePlainText(assignment.value)
            try? await Task.sleep(for: .milliseconds(40))
            PasteService.sendPasteCommand()
            try? await Task.sleep(for: .milliseconds(90))
        }
    }
}
