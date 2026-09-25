#if !APPSTORE
import Foundation

/// Read-only view of an accessibility node. The live scanner adapts
/// `AXUIElement`; tests adapt fixture trees built from HTML.
protocol FormTreeNode: Hashable {
    func string(_ attribute: String) -> String?
    func bool(_ attribute: String) -> Bool?
    func node(_ attribute: String) -> Self?
    var children: [Self] { get }
    var width: Double? { get }
}

/// Finds empty text fields and describes each from its accessibility
/// metadata, falling back to the page's visible captions.
enum FormTreeScanner<Node: FormTreeNode> {
    struct Field {
        var node: Node
        var snapshot: FormFieldSnapshot
    }

    private static var maxNodes: Int { 2_500 }
    private static var maxFields: Int { 40 }
    private static var maxCaptionLength: Int { 80 }
    private static var editableRoles: Set<String> { ["AXTextField", "AXTextArea", "AXSecureTextField"] }
    /// Controls own the text before them, and their options/titles are not
    /// captions for whatever field follows.
    private static var captionBreakingRoles: Set<String> {
        ["AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXLink"]
    }

    static func scan(window: Node) -> [Field] {
        let webRoot = Self.firstRole("AXWebArea", in: window)
        var state = WalkState()
        Self.walk(webRoot ?? window, depth: 0, includesSemanticGroups: webRoot != nil, state: &state)
        return Self.assignParts(state.collected, captionSerials: state.captionSerials)
    }

    private struct WalkState {
        var collected: [Field] = []
        var nextID = 1
        var seen = Set<Node>()
        /// Most recent caption-like text in document order.
        var caption: (text: String, serial: Int)?
        var nextCaptionSerial = 0
        /// Field ID → serial of the caption it adopted.
        var captionSerials: [String: Int] = [:]
    }

    /// Pages often caption a box with plain text that has no programmatic
    /// link to it (text above it, or in the cell to its left). In document
    /// order that text is the last one before the box.
    private static func walk(
        _ node: Node,
        depth: Int,
        includesSemanticGroups: Bool,
        state: inout WalkState)
    {
        guard depth <= 32,
              state.collected.count < Self.maxFields,
              state.seen.count < Self.maxNodes,
              state.seen.insert(node).inserted
        else { return }

        let role = node.string(AX.role)
        if role == "AXStaticText" {
            if let text = Self.text(of: node) {
                if text.count > Self.maxCaptionLength {
                    state.caption = nil
                } else if Self.isCaptionText(text) {
                    state.caption = (text, state.nextCaptionSerial)
                    state.nextCaptionSerial += 1
                }
            }
            return
        }
        if let role, Self.captionBreakingRoles.contains(role) {
            state.caption = nil
            return
        }
        if let role, Self.editableRoles.contains(role) {
            // Filled or disabled boxes still consume the caption before them.
            guard Self.isEditableField(node) else {
                state.caption = nil
                return
            }
            let id = "ax_\(state.nextID)"
            var snapshot = Self.snapshot(node, id: id, includesSemanticGroups: includesSemanticGroups)
            if snapshot.accessibleLabel == nil, let caption = state.caption {
                // Kept for following unlabeled boxes: they are parts of the
                // same captioned value.
                snapshot.caption = caption.text
                state.captionSerials[id] = caption.serial
            } else {
                state.caption = nil
            }
            state.collected.append(Field(node: node, snapshot: snapshot))
            state.nextID += 1
            return
        }

        for child in node.children {
            Self.walk(child, depth: depth + 1, includesSemanticGroups: includesSemanticGroups, state: &state)
            if state.collected.count >= Self.maxFields { return }
        }
    }

    /// Boxes that adopted the same caption instance are one split value.
    private static func assignParts(_ fields: [Field], captionSerials: [String: Int]) -> [Field] {
        let groups = Dictionary(grouping: fields.map(\.snapshot.id)) { captionSerials[$0] }
        return fields.map { field in
            var field = field
            guard let serial = captionSerials[field.snapshot.id],
                  let ids = groups[serial], ids.count > 1,
                  let index = ids.firstIndex(of: field.snapshot.id)
            else { return field }
            field.snapshot.part = FieldPart(leadID: ids[0], index: index, count: ids.count)
            return field
        }
    }

    /// Punctuation between split boxes ("(", ")", "-") is not a caption.
    private static func isCaptionText(_ text: String) -> Bool {
        text.count <= Self.maxCaptionLength && text.contains { $0.isLetter }
    }

    private static func text(of node: Node) -> String? {
        node.string(AX.value) ?? node.string(AX.title)
    }

    private static func isEditableField(_ node: Node) -> Bool {
        guard let role = node.string(AX.role), Self.editableRoles.contains(role) else {
            return false
        }
        let subrole = node.string(AX.subrole)
        if subrole == "AXSearchField" || subrole == "AXURLField" { return false }
        if node.bool(AX.enabled) == false { return false }
        return node.string(AX.value) == nil
    }

    private static func firstRole(_ role: String, in root: Node) -> Node? {
        var seen = Set<Node>()
        var stack: [(Node, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard seen.insert(node).inserted, depth <= 16 else { continue }
            if node.string(AX.role) == role { return node }
            for child in node.children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func snapshot(
        _ node: Node,
        id: String,
        includesSemanticGroups: Bool) -> FormFieldSnapshot
    {
        let parent = node.node(AX.parent)
        let siblings = parent?.children ?? []
        var nearby: [String] = []
        var seen = Set<String>()
        func add(_ value: String?) {
            guard let value, !value.isEmpty, value.count <= 80, seen.insert(value).inserted else { return }
            nearby.append(value)
        }
        if let parent {
            add(parent.string(AX.title))
        }
        for sibling in siblings where sibling.string(AX.role) == "AXStaticText" {
            add(Self.text(of: sibling))
        }
        return FormFieldSnapshot(
            id: id,
            role: node.string(AX.role),
            accessibleLabel: Self.accessibleName(of: node),
            semanticGroup: includesSemanticGroups ? Self.semanticGroup(for: node) : nil,
            title: node.string(AX.title),
            description: node.string(AX.description),
            help: node.string(AX.help),
            placeholder: node.string(AX.placeholder),
            nearbyText: Array(nearby.prefix(6)),
            identifier: node.string(AX.identifier),
            width: node.width)
    }

    private static func semanticGroup(for node: Node) -> String? {
        var ancestor = node.node(AX.parent)
        var depth = 0
        while let current = ancestor, depth < 8 {
            let role = current.string(AX.role)
            if role == "AXWebArea" { return nil }
            if role == "AXGroup",
               let name = Self.accessibleName(of: current) ?? Self.implicitGroupName(of: current)
            {
                return name
            }
            ancestor = current.node(AX.parent)
            depth += 1
        }
        return nil
    }

    /// An unnamed multi-field AXGroup may expose its legend as leading text.
    private static func implicitGroupName(of group: Node) -> String? {
        let children = group.children
        var fieldLabels = Set<String>()
        var editableCount = 0
        var seen = Set<Node>()
        var stack = children.map { ($0, 0) }

        while let (node, depth) = stack.popLast() {
            guard depth <= 6, seen.insert(node).inserted else { continue }
            if let role = node.string(AX.role), Self.editableRoles.contains(role) {
                editableCount += 1
                if let label = Self.accessibleName(of: node) {
                    fieldLabels.insert(Self.comparisonKey(label))
                }
                continue
            }
            for child in node.children {
                stack.append((child, depth + 1))
            }
        }
        guard editableCount >= 2 else { return nil }

        for (index, child) in children.enumerated() {
            if Self.containsEditableField(child) { break }
            guard child.string(AX.role) == "AXStaticText",
                  let text = Self.text(of: child),
                  !fieldLabels.contains(Self.comparisonKey(text)),
                  !Self.isFieldCaption(at: index, in: children)
            else { continue }
            return text
        }
        return nil
    }

    /// Text directly followed by a field (ignoring punctuation) captions that
    /// field; it is not a legend for the whole group.
    private static func isFieldCaption(at index: Int, in siblings: [Node]) -> Bool {
        for sibling in siblings.dropFirst(index + 1) {
            let role = sibling.string(AX.role)
            if let role, Self.editableRoles.contains(role) { return true }
            guard role == "AXStaticText" else { return false }
            if let text = Self.text(of: sibling), Self.isCaptionText(text) { return false }
        }
        return false
    }

    private static func containsEditableField(_ root: Node) -> Bool {
        var seen = Set<Node>()
        var stack: [(Node, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard depth <= 6, seen.insert(node).inserted else { continue }
            if let role = node.string(AX.role), Self.editableRoles.contains(role) {
                return true
            }
            for child in node.children {
                stack.append((child, depth + 1))
            }
        }
        return false
    }

    private static func comparisonKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func accessibleName(of node: Node) -> String? {
        if let titleElement = node.node(AX.titleUIElement) {
            return Self.text(of: titleElement)
        }
        return node.string(AX.description) ?? node.string(AX.title)
    }
}
#endif
