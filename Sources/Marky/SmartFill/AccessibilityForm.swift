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

        let webRoot = Self.firstRole("AXWebArea", in: window)
        let root = webRoot ?? window
        var collected: [FormField] = []
        var nextID = 1
        var seen = Set<AXUIElement>()
        Self.walk(
            root,
            depth: 0,
            includesSemanticGroups: webRoot != nil,
            collected: &collected,
            nextID: &nextID,
            seen: &seen)
        return collected
    }

    private static func walk(
        _ node: AXUIElement,
        depth: Int,
        includesSemanticGroups: Bool,
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
                snapshot: Self.snapshot(
                    node,
                    id: id,
                    includesSemanticGroups: includesSemanticGroups)))
            nextID += 1
        }

        for child in AX.elements(from: node, AX.children) {
            Self.walk(
                child,
                depth: depth + 1,
                includesSemanticGroups: includesSemanticGroups,
                collected: &collected,
                nextID: &nextID,
                seen: &seen)
            if collected.count >= Self.maxFields { return }
        }
    }

    private static func isEditableField(_ element: AXUIElement) -> Bool {
        guard let role = AX.string(from: element, AX.role), Self.editableRoles.contains(role) else {
            return false
        }
        let subrole = AX.string(from: element, AX.subrole)
        if subrole == "AXSearchField" || subrole == "AXURLField" { return false }
        if AX.bool(from: element, AX.enabled) == false { return false }
        return AX.string(from: element, AX.value) == nil
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

    private static func snapshot(
        _ element: AXUIElement,
        id: String,
        includesSemanticGroups: Bool) -> FormFieldSnapshot
    {
        let parent = AX.element(from: element, AX.parent)
        let siblings = parent.map { AX.elements(from: $0, AX.children) } ?? []
        var nearby: [String] = []
        var seen = Set<String>()
        func add(_ value: String?) {
            guard let value, !value.isEmpty, value.count <= 80, seen.insert(value).inserted else { return }
            nearby.append(value)
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
            accessibleLabel: Self.accessibleName(of: element),
            semanticGroup: includesSemanticGroups ? Self.semanticGroup(for: element) : nil,
            title: AX.string(from: element, AX.title),
            description: AX.string(from: element, AX.description),
            help: AX.string(from: element, AX.help),
            placeholder: AX.string(from: element, AX.placeholder),
            nearbyText: Array(nearby.prefix(6)),
            identifier: AX.string(from: element, AX.identifier))
    }

    private static func semanticGroup(for element: AXUIElement) -> String? {
        var ancestor = AX.element(from: element, AX.parent)
        var depth = 0
        while let current = ancestor, depth < 8 {
            let role = AX.string(from: current, AX.role)
            if role == "AXWebArea" { return nil }
            if role == "AXGroup",
               let name = Self.accessibleName(of: current)
            {
                return name
            }
            if role == "AXGroup",
               let name = Self.implicitGroupName(of: current)
            {
                return name
            }
            ancestor = AX.element(from: current, AX.parent)
            depth += 1
        }
        return nil
    }

    /// An unnamed multi-field AXGroup may expose its legend as leading text.
    private static func implicitGroupName(of group: AXUIElement) -> String? {
        let children = AX.elements(from: group, AX.children)
        var fieldLabels = Set<String>()
        var editableCount = 0
        var seen = Set<AXUIElement>()
        var stack = children.map { ($0, 0) }

        while let (node, depth) = stack.popLast() {
            guard depth <= 6, seen.insert(node).inserted else { continue }
            if let role = AX.string(from: node, AX.role), Self.editableRoles.contains(role) {
                editableCount += 1
                if let label = Self.accessibleName(of: node) {
                    fieldLabels.insert(Self.comparisonKey(label))
                }
                continue
            }
            for child in AX.elements(from: node, AX.children) {
                stack.append((child, depth + 1))
            }
        }
        guard editableCount >= 2 else { return nil }

        for child in children {
            if Self.containsEditableField(child) { break }
            guard AX.string(from: child, AX.role) == "AXStaticText",
                  let text = AX.string(from: child, AX.value)
                    ?? AX.string(from: child, AX.title),
                  !fieldLabels.contains(Self.comparisonKey(text))
            else { continue }
            return text
        }
        return nil
    }

    private static func containsEditableField(_ root: AXUIElement) -> Bool {
        var seen = Set<AXUIElement>()
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard depth <= 6, seen.insert(node).inserted else { continue }
            if let role = AX.string(from: node, AX.role), Self.editableRoles.contains(role) {
                return true
            }
            for child in AX.elements(from: node, AX.children) {
                stack.append((child, depth + 1))
            }
        }
        return false
    }

    private static func comparisonKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func accessibleName(of element: AXUIElement) -> String? {
        if let titleElement = AX.element(from: element, AX.titleUIElement) {
            return AX.string(from: titleElement, AX.value)
                ?? AX.string(from: titleElement, AX.title)
        }
        return AX.string(from: element, AX.description)
            ?? AX.string(from: element, AX.title)
    }
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
