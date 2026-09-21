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

    private static let maxNodes = 2_500
    private static let maxFields = 40
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]

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

        let root = Self.firstRole("AXWebArea", in: window) ?? window
        var collected: [FormField] = []
        var nextID = 1
        var seen = Set<AXUIElement>()
        Self.walk(root, depth: 0, collected: &collected, nextID: &nextID, seen: &seen)
        return collected
    }

    private static func walk(
        _ node: AXUIElement,
        depth: Int,
        collected: inout [FormField],
        nextID: inout Int,
        seen: inout Set<AXUIElement>)
    {
        guard depth <= 32,
              collected.count < Self.maxFields,
              seen.count < Self.maxNodes,
              seen.insert(node).inserted
        else { return }

        if Self.isEditableField(node) {
            let id = "ax_\(nextID)"
            collected.append(FormField(
                element: node,
                snapshot: Self.snapshot(node, id: id)))
            nextID += 1
        }

        for child in AX.elements(from: node, AX.children) {
            Self.walk(child, depth: depth + 1, collected: &collected, nextID: &nextID, seen: &seen)
            if collected.count >= Self.maxFields { return }
        }
    }

    private static func isEditableField(_ element: AXUIElement) -> Bool {
        guard let role = AX.string(from: element, AX.role), Self.editableRoles.contains(role) else {
            return false
        }
        let subrole = AX.string(from: element, AX.subrole)
        if subrole == "AXSearchField" || subrole == "AXURLField" { return false }
        if Self.isBrowserChrome(element) { return false }
        if AX.bool(from: element, AX.enabled) == false { return false }
        return AX.string(from: element, AX.value) == nil
    }

    private static func isBrowserChrome(_ element: AXUIElement) -> Bool {
        let haystack = [
            AX.string(from: element, AX.title),
            AX.string(from: element, AX.description),
            AX.string(from: element, AX.placeholder),
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return haystack.contains("address and search bar")
            || haystack.contains("search or enter")
            || haystack.contains("omnibox")
    }

    private static func firstRole(_ role: String, in root: AXUIElement) -> AXUIElement? {
        var seen = Set<AXUIElement>()
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard seen.insert(node).inserted, depth <= 16 else { continue }
            if AX.string(from: node, AX.role) == role { return node }
            for child in AX.elements(from: node, AX.children).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func snapshot(_ element: AXUIElement, id: String) -> FormFieldSnapshot {
        let parent = AX.element(from: element, AX.parent)
        let siblings = parent.map { AX.elements(from: $0, AX.children) } ?? []
        var nearby: [String] = []
        var seen = Set<String>()
        func add(_ value: String?) {
            guard let value, !value.isEmpty, value.count <= 80, seen.insert(value).inserted else { return }
            nearby.append(value)
        }
        if let titleElement = AX.element(from: element, AX.titleUIElement) {
            add(AX.string(from: titleElement, AX.value) ?? AX.string(from: titleElement, AX.title))
        }
        if let parent {
            add(AX.string(from: parent, AX.title))
        }
        for sibling in siblings where AX.string(from: sibling, AX.role) == "AXStaticText" {
            add(AX.string(from: sibling, AX.value) ?? AX.string(from: sibling, AX.title))
        }
        return FormFieldSnapshot(
            id: id,
            role: AX.string(from: element, AX.role),
            title: AX.string(from: element, AX.title),
            description: AX.string(from: element, AX.description),
            help: AX.string(from: element, AX.help),
            placeholder: AX.string(from: element, AX.placeholder),
            nearbyText: Array(nearby.prefix(6)),
            identifier: AX.string(from: element, AX.identifier))
    }
}

@MainActor
struct AccessibilityFormWriter {
    let pasteboard: PasteboardService

    func fill(_ assignments: [(element: AXUIElement, value: String)]) async {
        var failed: [(element: AXUIElement, value: String)] = []
        for assignment in assignments {
            if Self.setValue(assignment.element, assignment.value) {
                continue
            }
            failed.append(assignment)
        }
        if !failed.isEmpty {
            await self.paste(failed)
        }
    }

    private static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        guard AX.string(from: element, AX.value) == nil,
              AX.isSettable(element, AX.value),
              AX.setString(element, AX.value, value)
        else {
            return false
        }
        let actual = AX.string(from: element, AX.value) ?? ""
        return actual == value || actual.contains(value)
    }

    private func paste(_ assignments: [(element: AXUIElement, value: String)]) async {
        let saved = self.pasteboard.copyItems()
        defer { self.pasteboard.restoreItems(saved) }

        for assignment in assignments {
            AX.setBool(assignment.element, AX.focused, true)
            try? await Task.sleep(for: .milliseconds(80))
            PasteService.sendSelectAllCommand()
            try? await Task.sleep(for: .milliseconds(40))
            self.pasteboard.writePlainText(assignment.value)
            try? await Task.sleep(for: .milliseconds(40))
            PasteService.sendPasteCommand()
            try? await Task.sleep(for: .milliseconds(90))
        }
    }
}
