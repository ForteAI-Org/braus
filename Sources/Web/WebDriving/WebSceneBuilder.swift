//
//  WebSceneBuilder.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore

/// WebSceneBuilder turns a page's accessibility tree and layout into the scene a window gives the
/// engine: Chrome's roles become the accessibility roles the engine already acts on (`button` is
/// `AXButton`, `textbox` is `AXTextField`...), landmarks and dialogs become the scene's sections,
/// and every box is normalized to the viewport, which is the scene's window.
///
/// Only what is painted inside the viewport is in the scene, as on the desktop. Text is kept where
/// no control or heading already says it, and long text is cut to a label's length.
public enum WebSceneBuilder {

    /// The longest label a text or a row keeps; the rest is cut and marked with an ellipsis.
    static let maxTextLength = 80
    static let maxElements   = 600

    /// The key a page's knowledge is filed under, as an application's bundle id: `web:<host>`,
    /// `web:file` for a local file and `web:blank` for a page with no host.
    public static func appKey(for url: String) -> String {
        guard let components = URLComponents(string: url) else { return "web:blank" }
        if components.scheme == "file" { return "web:file" }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return "web:blank" }
        return "web:" + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    /// `popup` is an open select's list, drawn over the page: its options follow the page's
    /// elements, in a section of their own, and cover what they are drawn over.
    public static func scene(nodes: [WebAXNode], layout: WebLayout, popup: WebSelectPopup? = nil) -> SceneSnapshot {
        build(nodes: nodes, layout: layout, popup: popup).scene
    }

    /// The scene and the quality of the read behind it: Chrome's tree is read whole, so the walk is
    /// complete unless the element limit stopped it, and the window is the page's root.
    public static func build(
        nodes : [WebAXNode],
        layout: WebLayout,
        popup : WebSelectPopup? = nil
    ) -> (scene: SceneSnapshot, capture: CaptureQuality) {
        var visited = 0
        let byID     = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let viewport = CGRect(origin: .zero, size: layout.viewport)
        var elements: [SceneElement]                       = []
        var sections: [(name: String, rect: NormalizedRect)] = []

        func visibleBounds(of node: WebAXNode) -> NormalizedRect? {
            guard let id = node.backendNodeID, let box = layout.boxes[id] else { return nil }
            let visible = box.intersection(viewport)
            guard !visible.isNull, visible.width >= 2, visible.height >= 2,
                  viewport.contains(CGPoint(x: visible.midX, y: visible.midY))
            else { return nil }
            return NormalizedRect(pixelBox: visible, in: layout.viewport)
        }

        func walk(_ node: WebAXNode, container: String?, collection: String?, textCovered: Bool) {
            guard elements.count < maxElements else { return }
            visited += 1
            var container   = container
            var collection  = collection
            var textCovered = textCovered
            if !node.isIgnored {
                let name = clean(node.name)
                if let place = placeName(of: node, name: name) {
                    if let bounds = visibleBounds(of: node) { sections.append((place, bounds)) }
                    container = container.map { $0 + " / " + place } ?? place
                } else if groupRoles.contains(node.role), !name.isEmpty, name.count <= 48 {
                    container = container.map { $0 + " / " + name } ?? name
                }
                if collectionRoles.contains(node.role) {
                    collection = collection ?? (container.map { $0 + " / " } ?? "") + (name.isEmpty ? node.role : name)
                }
                let isSecure = node.backendNodeID.map(layout.secureFieldIDs.contains) ?? false
                if let element = element(for: node, name: name, container: container, collection: collection,
                                         textCovered: textCovered, isSecure: isSecure) {
                    if let bounds = visibleBounds(of: node) {
                        var element = element
                        element.bounds = bounds
                        element.id = SceneIdentity.key(kind: element.kind, label: element.label, bounds: bounds,
                                                       isUnlabeled: element.isUnlabeled)
                        elements.append(element)
                    }
                    if element.kind != .text || node.role == "heading" { textCovered = true }
                }
                // A label's text is the name of the field it labels, which the field already carries.
                if node.role == "LabelText" { textCovered = true }
            }
            for child in node.childIDs {
                if let child = byID[child] {
                    walk(child, container: container, collection: collection, textCovered: textCovered)
                }
            }
        }
        let root = nodes.first(where: { $0.parentID == nil })
        if let root { walk(root, container: nil, collection: nil, textCovered: false) }
        let stopped = elements.count >= maxElements

        if let popup {
            let cover = NormalizedRect(pixelBox: popup.frame(in: layout.viewport), in: layout.viewport).cgRect
            elements.removeAll { cover.contains($0.bounds.center) }
            elements += popup.elements(in: layout.viewport)
        }

        // Duplicates read apart by ordinal, as the desktop harvest does: same kind, place and name.
        var seen: [String: Int] = [:]
        for index in elements.indices {
            let key = elements[index].kind.rawValue + "\n" + (elements[index].container ?? "") + "\n" + elements[index].label
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > 1 { elements[index].label += " #\(count)" }
        }

        var names: [String: Int] = [:]
        var named = sections.map { section -> SceneSection in
            let count = (names[section.name] ?? 0) + 1
            names[section.name] = count
            return SceneSection(name: count > 1 ? "\(section.name) #\(count)" : section.name, bounds: section.rect)
        }
        if let popup {
            named.append(SceneSection(name: popup.sectionName,
                                      bounds: NormalizedRect(pixelBox: popup.frame(in: layout.viewport), in: layout.viewport)))
        }
        for index in elements.indices where elements[index].section == nil {
            let center = elements[index].bounds.center
            elements[index].section = named
                .filter { $0.bounds.contains(center) }
                .min { $0.bounds.area < $1.bounds.area }?
                .name
        }

        let appKey = appKey(for: layout.url)
        let capture = CaptureQuality(
            walkCompleted  : root != nil && !stopped,
            stoppedBy      : stopped ? .elementLimit : nil,
            windowFound    : root != nil,
            windowRole     : root?.role,
            nodesVisited   : visited,
            elementsEmitted: elements.count
        )
        let scene = SceneSnapshot(
            bundleID         : appKey,
            appName          : String(appKey.dropFirst(4)),
            windowTitle      : layout.title.isEmpty ? layout.url : layout.title,
            viewportPixelSize: ViewportPixelSize(width: Int(layout.viewport.width.rounded()),
                                                 height: Int(layout.viewport.height.rounded())),
            elements         : elements,
            sections         : named
        )
        return (scene, capture)
    }

    // MARK: Roles

    /// Landmarks and dialogs: each is a section of the scene and a step of its elements' container.
    static let placeRoles: [String: String] = [
        "banner"     : "header",
        "contentinfo": "footer",
        "complementary": "sidebar",
        "navigation" : "navigation",
        "main"       : "main",
        "search"     : "search",
        "dialog"     : "dialog",
        "alertdialog": "dialog",
    ]

    /// A form or a region is a place only when it is named, as the ARIA landmark rules say.
    static let namedPlaceRoles: [String: String] = ["form": "form", "region": "region"]

    static let groupRoles: Set<String> = ["group", "toolbar", "radiogroup", "tablist", "menu", "menubar"]

    static let collectionRoles: Set<String> = ["table", "grid", "treegrid", "tree", "listbox"]

    static func placeName(of node: WebAXNode, name: String) -> String? {
        if let place = placeRoles[node.role] { return name.isEmpty ? place : "\(place) (\(name))" }
        if let place = namedPlaceRoles[node.role], !name.isEmpty { return "\(place) (\(name))" }
        return nil
    }

    /// The element a node stands for, without its bounds; nil for a node the scene does not show. A node
    /// `isSecure` names (`WebSecureFields`, by the DOM) is an `AXSecureTextField` with no value whatever
    /// role the tree gives it: the DOM wins over the tree's role, and what the tree says it holds never
    /// reaches the scene.
    static func element(
        for node   : WebAXNode,
        name       : String,
        container  : String?,
        collection : String?,
        textCovered: Bool,
        isSecure   : Bool = false
    ) -> SceneElement? {
        let enabled = node.flag("disabled").map { !$0 } ?? true
        func control(_ role: String, label: String? = nil, state: ControlState? = nil, value: String? = nil,
                     unnamed: String) -> SceneElement {
            let label = label ?? name
            return SceneElement(
                id: "", kind: label.isEmpty ? .icon : .control, label: label.isEmpty ? unnamed : cut(label),
                bounds: .zero, role: role, state: state, value: value, isEnabled: enabled, container: container,
                isUnlabeled: label.isEmpty, labelOrigin: label.isEmpty ? nil : .title, collectionPath: collection
            )
        }
        if isSecure {
            var field = control("AXSecureTextField", value: nil, unnamed: "Secure text field")
            field.kind        = .control
            field.isUnlabeled = false
            return field
        }
        switch node.role {
            case "button":
                if let pressed = node.token("pressed") {
                    return control("AXCheckBox", state: state(pressed), unnamed: "unlabeled toggle")
                }
                return control("AXButton", unnamed: "unlabeled button")
            case "PopUpButton":
                return control("AXPopUpButton", value: node.value.map(clean), unnamed: "unlabeled pop-up")
            case "link":
                return control("AXLink", unnamed: "unlabeled link")
            case "menuitem":
                return control("AXMenuItem", unnamed: "unlabeled menu item")
            case "checkbox", "switch", "menuitemcheckbox":
                return control("AXCheckBox", state: state(node.token("checked")), unnamed: "unlabeled checkbox")
            case "radio", "menuitemradio":
                return control("AXRadioButton", state: state(node.token("checked")), unnamed: "unlabeled radio button")
            case "tab":
                return control("AXRadioButton", state: node.flag("selected") == true ? .on : .off, unnamed: "unlabeled tab")
            case "textbox", "searchbox", "spinbutton":
                let multiline = node.flag("multiline") == true
                var field = control(multiline ? "AXTextArea" : "AXTextField", value: node.value ?? "",
                                    unnamed: multiline ? "Text area" : "Text field")
                field.kind        = .control
                field.isUnlabeled = false
                return field
            case "combobox":
                let editable = node.properties["editable"] != nil
                var box = control(editable ? "AXComboBox" : "AXPopUpButton", value: node.value.map(clean) ?? "",
                                  unnamed: editable ? "Combo box" : "Pop-up button")
                box.kind        = .control
                box.isUnlabeled = false
                return box
            case "slider":
                return control("AXSlider", value: node.value, unnamed: "unlabeled slider")
            case "row", "treeitem", "option":
                guard !name.isEmpty else { return nil }
                let state: ControlState? = node.flag("selected").map { $0 ? .on : .off }
                var row = control("AXRow", state: node.role == "row" ? nil : state, unnamed: "")
                row.labelOrigin = .rowContent
                return row
            case "DisclosureTriangle":
                return control("AXDisclosureTriangle", unnamed: "unlabeled disclosure")
            case "img", "image":
                guard !name.isEmpty else { return nil }
                return SceneElement(id: "", kind: .image, label: cut(name), bounds: .zero, role: "AXImage",
                                    container: container, labelOrigin: .description, collectionPath: collection)
            case "heading", "StaticText":
                guard !textCovered, !name.isEmpty else { return nil }
                return SceneElement(id: "", kind: .text, label: cut(name), bounds: .zero, role: "AXStaticText",
                                    container: container, labelOrigin: .value, collectionPath: collection)
            default:
                return nil
        }
    }

    // MARK: Text

    static func state(_ token: String?) -> ControlState? {
        switch token {
            case "true"? : .on
            case "false"?: .off
            case "mixed"?: .mixed
            default      : nil
        }
    }

    /// Whitespace runs read as one space, with none at either end.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func cut(_ text: String) -> String {
        text.count <= maxTextLength ? text : String(text.prefix(maxTextLength - 1)) + "…"
    }
}
