import CoreGraphics
import Foundation
import MacDriver

/// MacCoverage decides whether a window's tree is rich enough for the MacDriver: the share of the
/// window covered by elements that are not containers, and the count of elements with a real action.
///
/// A window over both thresholds is the MacDriver's; under either it is `sparse` and stays with the
/// current Driver (a canvas, a web view without a tree, a window on another Space). The thresholds
/// start from the spec's guess (section 3) and are tuned on recorded outcomes. An almost empty window
/// of a rich app (an empty Finder folder) reads sparse; the channel table names the driver for it.
public struct MacCoverage: Sendable, Equatable {

    /// Lowered from the spec's 60%: Settings' Keyboard pane, a rich window, covers 57% (15 Oct).
    public static let minimumShare = 0.5
    public static let minimumActionable = 10
    /// Cells per side of the grid the window is sampled on.
    static let gridSide = 48

    /// Roles that only hold other elements, so covering the window says nothing about its content.
    static let containerRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea", "AXLayoutArea",
        "AXTabGroup", "AXToolbar", "AXPopover", "AXRow", "AXColumn", "AXCell", "AXList", "AXOutline",
        "AXTable", "AXBrowser", "AXGrid", "AXWebArea",
    ]

    /// Actions every element lists, which say nothing about what it does.
    static let incidentalActions: Set<String> = [
        "AXScrollToVisible", "AXShowMenu", "AXRaise", "AXShowDefaultUI", "AXShowAlternateUI",
    ]

    /// Share of the window, 0 to 1, under at least one non-container element.
    public let coveredShare: Double
    /// Elements listing at least one action other than the incidental ones.
    public let actionableCount: Int

    public init(coveredShare: Double, actionableCount: Int) {
        self.coveredShare    = coveredShare
        self.actionableCount = actionableCount
    }

    public init(window: MacTreeNode) {
        let nodes = window.flattened.dropFirst()
        actionableCount = nodes.filter { node in
            node.actions.contains { !Self.incidentalActions.contains($0) }
        }.count
        guard let frame = window.frame, frame.width > 0, frame.height > 0 else {
            coveredShare = 0
            return
        }
        let side = Self.gridSide
        var covered = Set<Int>()
        for node in nodes where !Self.containerRoles.contains(node.role) {
            guard let box = node.frame?.intersection(frame), !box.isNull, box.width > 0, box.height > 0 else { continue }
            let firstColumn = Int(((box.minX - frame.minX) / frame.width * Double(side)).rounded(.down))
            let lastColumn  = Int(((box.maxX - frame.minX) / frame.width * Double(side)).rounded(.up))
            let firstRow    = Int(((box.minY - frame.minY) / frame.height * Double(side)).rounded(.down))
            let lastRow     = Int(((box.maxY - frame.minY) / frame.height * Double(side)).rounded(.up))
            for row in max(0, firstRow)..<min(side, max(firstRow + 1, lastRow)) {
                for column in max(0, firstColumn)..<min(side, max(firstColumn + 1, lastColumn)) {
                    covered.insert(row * side + column)
                }
            }
        }
        coveredShare = Double(covered.count) / Double(side * side)
    }

    /// Whether the MacDriver takes this window.
    public var isRich: Bool {
        coveredShare >= Self.minimumShare && actionableCount >= Self.minimumActionable
    }
}
