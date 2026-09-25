import Foundation
@testable import Marky

/// In-memory accessibility node for scanner tests.
final class FixtureNode: FormTreeNode {
    var attributes: [String: String] = [:]
    var flags: [String: Bool] = [:]
    var children: [FixtureNode] = []
    weak var parent: FixtureNode?
    var titleElement: FixtureNode?
    var width: Double?

    init(role: String) {
        self.attributes[AX.role] = role
    }

    func string(_ attribute: String) -> String? { self.attributes[attribute] }
    func bool(_ attribute: String) -> Bool? { self.flags[attribute] }
    func node(_ attribute: String) -> FixtureNode? {
        switch attribute {
        case AX.parent: self.parent
        case AX.titleUIElement: self.titleElement
        default: nil
        }
    }

    func append(_ child: FixtureNode) {
        child.parent = self
        self.children.append(child)
    }

    static func == (lhs: FixtureNode, rhs: FixtureNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Builds an approximation of Chrome's macOS accessibility tree from HTML:
/// block elements become AXGroup, inline wrappers are flattened, text runs
/// become AXStaticText, and `<label for>` becomes the control's title element.
enum ChromeLikeTree {
    static func window(html: Data) throws -> FixtureNode {
        let document = try XMLDocument(data: html, options: [.documentTidyHTML])
        let window = FixtureNode(role: "AXWindow")
        let webArea = FixtureNode(role: "AXWebArea")
        window.append(webArea)
        var builder = Builder()
        if let root = document.rootElement() {
            builder.add(root, to: webArea)
        }
        for (id, label) in builder.labels {
            builder.controls[id]?.titleElement = label
        }
        return window
    }

    private struct Builder {
        var controls: [String: FixtureNode] = [:]
        var labels: [(String, FixtureNode)] = []
        private var openLabel: (id: String, text: FixtureNode?)?

        private static let groups: Set<String> = [
            "div", "p", "form", "table", "tbody", "thead", "tr", "td", "th",
            "fieldset", "ul", "ol", "li", "section",
        ]
        private static let skipped: Set<String> = ["head", "script", "style", "br", "option", "noscript"]
        private static let textInputs: Set<String> = ["text", "email", "tel", "url", "number", "search", ""]

        mutating func add(_ xml: XMLNode, to parent: FixtureNode) {
            if xml.kind == .text {
                let text = (xml.stringValue ?? "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard !text.isEmpty else { return }
                let node = FixtureNode(role: "AXStaticText")
                node.attributes[AX.value] = text
                parent.append(node)
                if let label = self.openLabel, label.text == nil {
                    self.openLabel = (label.id, node)
                }
                return
            }
            guard let element = xml as? XMLElement, let name = element.name?.lowercased() else { return }
            guard !Self.skipped.contains(name) else { return }
            func attribute(_ key: String) -> String? {
                element.attributes?.first { $0.name?.lowercased() == key }?.stringValue
            }

            let control: FixtureNode?
            switch name {
            case "input":
                let type = attribute("type")?.lowercased() ?? "text"
                if type == "hidden" { return }
                if Self.textInputs.contains(type) {
                    control = FixtureNode(role: "AXTextField")
                } else if type == "password" {
                    control = FixtureNode(role: "AXSecureTextField")
                } else if type == "checkbox" {
                    control = FixtureNode(role: "AXCheckBox")
                } else if type == "radio" {
                    control = FixtureNode(role: "AXRadioButton")
                } else {
                    control = FixtureNode(role: "AXButton")
                    control?.attributes[AX.title] = attribute("value")
                }
                if let value = attribute("value"), !value.isEmpty, Self.textInputs.contains(type) {
                    control?.attributes[AX.value] = value
                }
                if let size = attribute("size").flatMap(Double.init) {
                    control?.width = size * 7 + 10
                }
            case "textarea":
                control = FixtureNode(role: "AXTextArea")
                control?.width = 160
            case "select":
                control = FixtureNode(role: "AXPopUpButton")
            case "button":
                control = FixtureNode(role: "AXButton")
            case "a":
                control = FixtureNode(role: "AXLink")
            case "img":
                guard let alt = attribute("alt"), !alt.isEmpty else { return }
                control = FixtureNode(role: "AXImage")
                control?.attributes[AX.description] = alt
            default:
                control = nil
            }
            if let control {
                control.attributes[AX.description] = control.attributes[AX.description] ?? attribute("aria-label")
                control.attributes[AX.placeholder] = attribute("placeholder")
                if let id = attribute("id") { self.controls[id] = control }
                parent.append(control)
                return
            }

            if name == "label", let target = attribute("for") {
                self.openLabel = (target, nil)
                for child in element.children ?? [] { self.add(child, to: parent) }
                if let label = self.openLabel, let text = label.text { self.labels.append((label.id, text)) }
                self.openLabel = nil
                return
            }
            let container: FixtureNode
            if Self.groups.contains(name) {
                container = FixtureNode(role: "AXGroup")
                container.attributes[AX.description] = attribute("aria-label")
                parent.append(container)
            } else {
                container = parent
            }
            for child in element.children ?? [] { self.add(child, to: container) }
        }
    }
}
