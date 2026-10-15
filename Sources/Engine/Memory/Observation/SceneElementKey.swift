//
//  SceneElementKey.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import PerceptionCore

/// SceneElementKey is the structural key of a captured element inside a structural scene, and what that
/// key identifies in one capture.
///
/// A key is a template: `control|<path>|<role>|<name>` for an element outside a collection whose role
/// is structure, `item_template|<collection path>|<role>|<caption>` for an element inside a collection,
/// nil for content (static text, images, cells and rows outside a collection, unknown roles), which a
/// structural scene does not keep. A name is a label read from a title, a description or the
/// developer's accessibility identifier, on any structural role; a value, a row's content, a column
/// header and a position are never part of it, so a field keeps its key whatever it holds and wherever
/// the window is.
///
/// A template is an instance's identity only where nothing else in the capture shares it. Two fields of
/// one container with no name share a template: neither is identified, and nothing learned on one is
/// attributed to the other or to both. Inside a collection every row repeats the template on purpose: a
/// click on any file's row is a click on the list's rows, so an item template is its own identity, and
/// a target there is told apart by its label among the rows.
public enum SceneElementKey {

    /// Identity is what one element of a capture is to the relations.
    public enum Identity: Sendable, Equatable, Hashable {
        /// A control whose key no other element of the capture has: the key identifies it.
        case control(String)
        /// An element of a collection's rows: the template identifies what any row offers.
        case itemTemplate(String)
        /// A control whose key another element of the capture shares: the structure does not tell
        /// them apart, so the key identifies neither.
        case indistinct(String)

        /// The key a relation may be keyed by, or nil when the element is not identified.
        public var key: String? {
            switch self {
                case .control(let key), .itemTemplate(let key): key
                case .indistinct: nil
            }
        }
    }

    /// Resolution is what a call's target names in a capture.
    public enum Resolution: Sendable, Equatable {
        /// No structural element has the target's role and label.
        case none
        /// Several physical elements have them: the target is ambiguous, whatever their keys.
        case ambiguous(count: Int)
        /// One physical element has them, with its identity.
        case resolved(Identity)
    }

    /// Whether a key is an item template: what every row of a collection offers, not one row. Two elements
    /// with that key are the same kind of row, and only their labels tell which row each is.
    public static func isItemTemplate(_ key: String) -> Bool {
        key.hasPrefix("item_template|")
    }

    /// The template key of an element, or nil when the element is content.
    public static func key(of element: CaptureElement) -> String? {
        if element.isUnderCollection { return "item_template|\(element.containerPath)|\(element.role)|\(caption(of: element))" }
        guard !SceneSkeleton.excludedRoles.contains(element.role) else { return nil }
        return "control|\(element.containerPath)|\(element.role)|\(name(of: element))"
    }

    /// The normalized caption a skeleton keeps for an element: its label when its role carries a caption,
    /// its origin is a title or a description and it names no file, the empty text otherwise. An item
    /// template uses it, so a row's content never multiplies templates.
    public static func caption(of element: CaptureElement) -> String {
        SceneSkeleton.isCaption(element) ? LabelText.normalize(element.label) : ""
    }

    /// The origins a control's name may come from: what the toolkit calls it, its help text, or the
    /// developer's identifier. Never its value or a row's content.
    public static let nameOrigins: Set<LabelOrigin> = [.title, .description, .identifier]

    /// The normalized name a control contributes to its key, the empty text when its label is content.
    public static func name(of element: CaptureElement) -> String {
        element.labelOrigin.map(nameOrigins.contains) == true ? LabelText.normalize(element.label) : ""
    }

    /// The identity of every element of a capture, in order: nil for content.
    public static func identities(in elements: [CaptureElement]) -> [Identity?] {
        let keys = elements.map(key(of:))
        var controls: [String: Int] = [:]
        for (element, key) in zip(elements, keys) where !element.isUnderCollection {
            if let key { controls[key, default: 0] += 1 }
        }
        return zip(elements, keys).map { element, key in
            guard let key else { return nil }
            if element.isUnderCollection { return .itemTemplate(key) }
            return controls[key, default: 0] == 1 ? .control(key) : .indistinct(key)
        }
    }

    /// What a target named by its role (nil for any) and its label is in a capture: the physical
    /// elements are counted before any key is compared, so two controls that share a key are two
    /// candidates, never one.
    public static func target(role: String?, label: String, in elements: [CaptureElement]) -> Resolution {
        let wanted = LabelText.normalize(label)
        let identities = identities(in: elements)
        var found: [Identity] = []
        for (element, identity) in zip(elements, identities) where LabelText.normalize(element.label) == wanted {
            if let role, !element.role.utf8.elementsEqual(role.utf8) { continue }
            if let identity { found.append(identity) }
        }
        switch found.count {
            case 0: return .none
            case 1: return .resolved(found[0])
            default: return .ambiguous(count: found.count)
        }
    }

    /// The template keys of the structural elements a target's role and label name, one per physical
    /// element: two controls with one key are two entries.
    public static func keys(matching role: String?, label: String, in elements: [CaptureElement]) -> [String] {
        let wanted = LabelText.normalize(label)
        return elements.compactMap { element in
            guard LabelText.normalize(element.label) == wanted else { return nil }
            if let role, !element.role.utf8.elementsEqual(role.utf8) { return nil }
            return key(of: element)
        }
    }
}
