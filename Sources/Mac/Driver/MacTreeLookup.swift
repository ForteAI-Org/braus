import Foundation

/// MacSettingsPane is one row of System Settings' sidebar: the pane's extension id (the sidebar
/// text's `AXIdentifier`), its name in the person's language, and whether it is the pane on show.
public struct MacSettingsPane: Sendable, Equatable {

    public var id: String
    public var name: String
    public var isSelected: Bool
    /// The row's path from the window.
    public var path: [Int]

    public init(id: String, name: String, isSelected: Bool, path: [Int]) {
        self.id         = id
        self.name       = name
        self.isSelected = isSelected
        self.path       = path
    }

    /// The id a `x-apple.systempreferences:` link takes: the part before a `*` sub-pane marker
    /// (`com.apple.Touch-ID-Settings.extension*TouchIDPasswordPrefs`).
    public var linkID: String { id.split(separator: "*", maxSplits: 1).first.map(String.init) ?? id }

    /// The sidebar's panes, in order. A row counts when one of its texts carries an identifier.
    public static func panes(in window: MacTreeNode) -> [MacSettingsPane] {
        window.flattened.filter { $0.role == "AXRow" }.compactMap { row in
            guard let text = row.flattened.first(where: { $0.role == "AXStaticText" && $0.identifier != nil }),
                  let id = text.identifier
            else { return nil }
            return MacSettingsPane(id: id, name: text.value ?? text.title ?? id, isSelected: row.isSelected == true,
                                   path: row.path)
        }
    }
}

/// MacTreeLookup finds elements in a read tree by what a person calls them.
public enum MacTreeLookup {

    /// The nodes from the root down to the first node, depth first, that `matches`.
    public static func ancestry(in root: MacTreeNode, where matches: (MacTreeNode) -> Bool) -> [MacTreeNode]? {
        if matches(root) { return [root] }
        for child in root.children {
            if let chain = ancestry(in: child, where: matches) { return [root] + chain }
        }
        return nil
    }

    /// Every chain from the root down to a node that `matches`, depth first.
    public static func ancestries(in root: MacTreeNode, where matches: (MacTreeNode) -> Bool) -> [[MacTreeNode]] {
        var chains: [[MacTreeNode]] = matches(root) ? [[root]] : []
        for child in root.children {
            chains += ancestries(in: child, where: matches).map { [root] + $0 }
        }
        return chains
    }

    /// The element a Finder window selects for an item named `name`: the row holding its name in list
    /// view, the list's child holding it in column view (a group with the icon and the name, measured
    /// 15 Oct), the named icon in icon view. Column view lists the item in the last column with it.
    public static func finderItem(named name: String, in window: MacTreeNode) -> MacTreeNode? {
        var found: MacTreeNode?
        for chain in ancestries(in: window, where: { node in
            (node.role == "AXStaticText" || node.role == "AXTextField") && (node.value == name || node.title == name)
        }) {
            if let row = chain.last(where: { $0.role == "AXRow" }) {
                found = row
            } else if let list = chain.lastIndex(where: { $0.role == "AXList" }), list + 1 < chain.count {
                found = chain[list + 1]
            }
        }
        if let found { return found }
        return window.flattened.first { node in
            node.role == "AXImage" && (node.title == name || node.descriptionText == name)
        }
    }
}
