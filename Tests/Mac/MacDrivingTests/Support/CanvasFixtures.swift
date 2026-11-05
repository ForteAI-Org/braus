//
//  CanvasFixtures.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import ImageIO
import MacDriver
import PerceptionCore
import Testing

/// CanvasFixtures loads the recorder's original MacTreeNode snapshots and window PNGs.
/// Files live beside the Perception fixtures; source-relative lookup avoids a package resource change.
enum CanvasFixtures {

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Perception/Fixtures/Canvas")

    static let variants = ["still", "clip-moved"] + (0..<6).map { "meter-phases/\($0)" }

    struct Recording {
        let tree: MacTreeNode
        let image: CGImage
    }

    static func load(_ variant: String) throws -> Recording {
        let url = directory.appendingPathComponent(variant)
        let tree = try JSONDecoder().decode(
            MacTreeNode.self,
            from: Data(contentsOf: url.appendingPathExtension("json"))
        )
        let source = try #require(
            CGImageSourceCreateWithURL(
                url.appendingPathExtension("png") as CFURL,
                nil
            )
        )
        return try Recording(
            tree : tree.addressed(),
            image: #require(
                CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    nil
                )
            )
        )
    }

    /// Reader replays a recorded tree through the same role the Perception AX harvester consumes.
    struct Reader: AccessibilityTreeReading {
        func role(_ node: MacTreeNode) -> String? { node.role }
        func subrole(_ node: MacTreeNode) -> String? { node.subrole }
        func title(_ node: MacTreeNode) -> String? { node.title }
        func descriptionText(_ node: MacTreeNode) -> String? { node.descriptionText }
        func identifier(_ node: MacTreeNode) -> String? { node.identifier }
        func value(_ node: MacTreeNode) -> String? { node.value }
        func numericValue(_ node: MacTreeNode) -> Int? { node.value.flatMap(Int.init) }
        func isEnabled(_ node: MacTreeNode) -> Bool? { node.isEnabled }
        func actions(_ node: MacTreeNode) -> [String] { node.actions }
        func frame(_ node: MacTreeNode) -> CGRect? { node.frame }
        func children(_ node: MacTreeNode) -> [MacTreeNode] { node.children }
        func readChildren(_ node: MacTreeNode) -> [MacTreeNode]? {
            node.unread?.children == true ? nil : node.children
        }
    }
}
