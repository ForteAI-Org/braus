import CoreGraphics
import Foundation

/// MacTreeNode is one accessibility element of a window as `MacTreeReading` read it, with the
/// attributes the scene needs and its children in the app's own order.
///
/// It is a value: it holds no `AXUIElement` and stays valid after the app changes. `path` is the
/// element's child indices from the window, the address `MacSceneBuilder` turns into a scene id and
/// the live driver resolves again (a path that no longer leads to the same role is `stale_target`).
/// A secure text field never carries a value.
public struct MacTreeNode: Sendable, Equatable, Codable {

    public var path: [Int]
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var descriptionText: String?
    public var help: String?
    public var placeholder: String?
    public var value: String?
    public var isEnabled: Bool?
    public var isSelected: Bool?
    public var isExpanded: Bool?
    public var isFocused: Bool?
    /// The element's frame in global points, top-left origin; nil when the app reports none.
    public var frame: CGRect?
    public var actions: [String]
    public var children: [MacTreeNode]
    /// What of this element did not answer, when something did not; nil when every attribute was read or
    /// is genuinely absent. A node marked here makes the read partial.
    public var unread: MacUnread?

    public init(
        path           : [Int] = [],
        role           : String,
        subrole        : String? = nil,
        identifier     : String? = nil,
        title          : String? = nil,
        descriptionText: String? = nil,
        help           : String? = nil,
        placeholder    : String? = nil,
        value          : String? = nil,
        isEnabled      : Bool? = nil,
        isSelected     : Bool? = nil,
        isExpanded     : Bool? = nil,
        isFocused      : Bool? = nil,
        frame          : CGRect? = nil,
        actions        : [String] = [],
        children       : [MacTreeNode] = [],
        unread         : MacUnread? = nil
    ) {
        self.path            = path
        self.role            = role
        self.subrole         = subrole
        self.identifier      = identifier
        self.title           = title
        self.descriptionText = descriptionText
        self.help            = help
        self.placeholder     = placeholder
        self.value           = subrole == Self.secureSubrole ? nil : value
        self.isEnabled       = isEnabled
        self.isSelected      = isSelected
        self.isExpanded      = isExpanded
        self.isFocused       = isFocused
        self.frame           = frame
        self.actions         = actions
        self.children        = children
        self.unread          = unread
    }

    public static let secureSubrole = "AXSecureTextField"

    public var isSecure: Bool { subrole == Self.secureSubrole }

    /// Whether this node or one below it did not answer: then the tree is not the whole window, and no
    /// match in it is the only one.
    public var hasUnreadParts: Bool { flattened.contains { $0.unread != nil } }

    /// The node and its descendants, depth first, in reading order.
    public var flattened: [MacTreeNode] {
        var nodes = [self]
        for child in children { nodes.append(contentsOf: child.flattened) }
        return nodes
    }

    /// Gives every node its path from this one, which becomes the root. Recorded trees are stored
    /// without paths; the reader also builds its tree this way.
    public func addressed(at path: [Int] = []) -> MacTreeNode {
        var node = self
        node.path = path
        node.children = children.enumerated().map { index, child in child.addressed(at: path + [index]) }
        return node
    }
}

/// MacUnread is what of one element did not answer a read: the whole element, its children, its action
/// names, or some of its attributes. A genuine absence (no value, an attribute the element does not
/// support) is no part of it: such an element is read.
public struct MacUnread: Sendable, Equatable, Codable {

    /// Why: the first failure met on this element.
    public var cause: MacReadFailure
    /// Nothing of the element answered: its role, frame and children are unknown.
    public var element: Bool
    /// Its children could not be listed: elements may be missing below it, how many is unknown.
    public var children: Bool
    /// Its action names could not be read.
    public var actions: Bool
    /// The attributes of an answered request that did not answer, by name.
    public var attributes: [String]

    public init(cause: MacReadFailure, element: Bool = false, children: Bool = false, actions: Bool = false,
                attributes: [String] = []) {
        self.cause      = cause
        self.element    = element
        self.children   = children
        self.actions    = actions
        self.attributes = attributes
    }
}

/// MacReadFailure is why an accessibility read did not succeed: the app did not answer in time, the API
/// answered an error (its `AXError` code), or it answered something of another shape than asked.
public enum MacReadFailure: Error, Sendable, Equatable, Codable {
    case timedOut
    case failed(code: Int32)
    case malformed
}
