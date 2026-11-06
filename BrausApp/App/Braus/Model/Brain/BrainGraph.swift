//
//  BrainGraph.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Foundation
import Memory
import PerceptionCore

/// BrainGraph is one application's Brain as a graph to draw: its windows,
/// the groups of controls in them and the controls, joined by membership,
/// by the window a control lives in, and by what a control was seen to do.
///
/// Every node has the moment it came in, so the graph can be shown as it grew:
/// a control when it was first seen, a group and a window with their first
/// control, a learned effect when it was last observed, which is the only time
/// the Brain keeps for one. The Brain forgets what it stops seeing, so the
/// growth is that of what it still holds.
///
/// Its positions are only where each node starts: windows on a ring, their
/// groups around them and the controls around their group. `BrainSimulation`
/// relaxes them and keeps them moving. It is built and read off the main
/// thread too, where a large graph settles.
nonisolated struct BrainGraph {

    /// A group carries the kind its members share, which it is drawn in.
    enum Kind: Hashable {
        case window
        case scene
        case container
        case collection
        case itemTemplate
        case relation(BrainRelation.Standing)
        case unknownState
        case group(ElementKind)
        case control(ElementKind)
    }

    struct Node: Identifiable {
        let id      : String
        let kind    : Kind
        let label   : String
        let cameIn  : Date
        var position: CGPoint
        var detail: String? = nil

        var radius: CGFloat {
            switch kind {
            case .window, .scene: 16
            case .group, .container, .collection: 9
            case .relation: 12
            case .control, .itemTemplate, .unknownState: 5
            }
        }
    }

    enum EdgeKind { case membership, placement, effect }

    struct Edge {
        let from  : String
        let to    : String
        let kind  : EdgeKind
        let cameIn: Date
    }

    private(set) var isInspection = false
    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []

    /// From the first node's arrival to the last's; one instant for a Brain learned in one look.
    var span: ClosedRange<Date> {
        let dates = nodes.map(\.cameIn) + edges.map(\.cameIn)
        guard let first = dates.min(), let last = dates.max() else { return Date.distantPast...Date.distantPast }
        return first...last
    }

    /// Renders observed states and explicit relation nodes, including same-state and unknown outcomes.
    init(stored: StoredBrain) {
        guard stored.hasObservations else {
            self.init(brain: stored.projection)
            return
        }
        self.init(brain: UIBrain())
        isInspection = true
        let inspection = BrainInspection(stored)
        let sceneIDs = Set(stored.scenes.map(\.id))
        let elementIDs = Set(stored.elements.map(\.sceneElementID))
        for scene in stored.scenes {
            nodes.append(Node(
                id: "scene:\(scene.id)", kind: .scene, label: inspection.scene(scene.id),
                cameIn: Date(timeIntervalSince1970: Double(scene.firstSeenMS) / 1000),
                position: .zero,
                detail: String(localized: "A saved interface state. Its number identifies it in this view; it is not a procedure step.")
                    + "\n" + BrainInspection.observations(scene)
                    + "\n" + inspection.stateDetails(scene.id)
            ))
        }
        for element in stored.elements where sceneIDs.contains(element.sceneID) {
            let kind: Kind = switch element.scope {
            case .container: .container
            case .collection: .collection
            case .itemTemplate: .itemTemplate
            case .control: .control(ElementKind(rawValue: element.kind ?? "") ?? .control)
            }
            let parent = element.parentElementID.flatMap { elementIDs.contains($0) ? "element:\($0)" : nil }
            let date = Date(timeIntervalSince1970: Double(element.firstSeenMS) / 1000)
            nodes.append(Node(
                id: "element:\(element.sceneElementID)", kind: kind,
                label: BrainInspection.element(element), cameIn: date, position: .zero,
                detail: inspection.scene(element.sceneID)
            ))
            edges.append(Edge(from: parent ?? "scene:\(element.sceneID)",
                              to: "element:\(element.sceneElementID)",
                              kind: parent == nil ? .placement : .membership, cameIn: date))
        }
        for relation in stored.relations {
            let date = Date(timeIntervalSince1970: Double(relation.firstSeenMS) / 1000)
            let targets = stored.elements.filter {
                $0.sceneID == relation.key.fromSceneID && $0.elementKey == relation.key.elementKey
            }
            let from = targets.count == 1 ? "element:\(targets[0].sceneElementID)"
                : "scene:\(relation.key.fromSceneID)"
            let relationID = "relation:\(relation.relationID)"
            guard sceneIDs.contains(relation.key.fromSceneID) else { continue }
            var destination = relation.key.toSceneID.map { "scene:\($0)" }
            if relation.key.toSceneID.map({ sceneIDs.contains($0) }) != true {
                destination = "unknown:\(relation.relationID)"
                nodes.append(Node(id: "unknown:\(relation.relationID)", kind: .unknownState,
                                  label: inspection.scene(nil), cameIn: date, position: .zero))
            }
            nodes.append(Node(
                id: relationID, kind: .relation(relation.standing), label: inspection.graphAction(relation),
                cameIn: date, position: .zero,
                detail: inspection.description(relation) + "\n" + inspection.evidence(relation)
            ))
            edges.append(Edge(from: from, to: relationID, kind: .effect, cameIn: date))
            if let destination {
                edges.append(Edge(from: relationID, to: destination, kind: .effect, cameIn: date))
            }
        }
        layOut()
    }

    init(brain: UIBrain) {
        let anchors = brain.objects
        let byKey   = Dictionary(uniqueKeysWithValues: anchors.map { ($0.anchorKey, $0) })

        // The windows, each with its first control; a control seen in no window joins one called "Window".
        let family  = { (anchor: ObjectAnchor) in anchor.window ?? "window" }
        let windows = Dictionary(grouping: anchors, by: family)
        for (name, members) in windows {
            nodes.append(Node(
                id      : "window:\(name)",
                kind    : .window,
                label   : name.capitalized,
                cameIn  : members.map(\.firstSeen).min() ?? .distantPast,
                position: .zero
            ))
        }

        for group in brain.groups {
            let members = group.memberAnchors.compactMap { byKey[$0] }
            guard let first = members.first else { continue }

            let arrival = members.map(\.firstSeen).min() ?? group.lastSeen
            nodes.append(Node(
                id      : "group:\(group.id)",
                kind    : .group(group.sharedKind),
                label   : group.name ?? "\(group.memberAnchors.count) \(group.sharedKind.rawValue)s",
                cameIn  : arrival,
                position: .zero
            ))
            edges.append(Edge(
                from  : "window:\(family(first))",
                to    : "group:\(group.id)",
                kind  : .placement,
                cameIn: arrival
            ))
        }

        let grouped = Set(brain.groups.map(\.id))
        for anchor in anchors {
            nodes.append(Node(
                id      : "control:\(anchor.anchorKey)",
                kind    : .control(anchor.kind),
                label   : anchor.label.isEmpty ? "Unlabelled \(anchor.kind.rawValue)" : anchor.label,
                cameIn  : anchor.firstSeen,
                position: .zero
            ))
            let parent = anchor.groupID.flatMap { grouped.contains($0) ? "group:\($0)" : nil }
            edges.append(Edge(
                from  : parent ?? "window:\(family(anchor))",
                to    : "control:\(anchor.anchorKey)",
                kind  : parent == nil ? .placement : .membership,
                cameIn: anchor.firstSeen
            ))
        }

        // A control that was seen to change the window's title points at the window it led to.
        let windowIDs = Set(nodes.filter { $0.kind == .window || $0.kind == .scene }.map(\.id))
        for transition in brain.transitions where transition.effect.hasPrefix("windowTitleChanged:") {
            let title  = String(transition.effect.dropFirst("windowTitleChanged:".count))
            let target = "window:\(LabelText.letters(title))"
            guard byKey[transition.anchorKey] != nil, windowIDs.contains(target) else { continue }

            edges.append(Edge(
                from  : "control:\(transition.anchorKey)",
                to    : target,
                kind  : .effect,
                cameIn: transition.lastObserved
            ))
        }

        layOut()
    }

    // MARK: Layout

    /// Rings, windows around the centre, their groups around them and the controls around their group.
    private mutating func layOut() {
        var place: [String: CGPoint] = [:]
        let windowNodes = nodes.filter { $0.kind == .window || $0.kind == .scene }.sorted { $0.cameIn < $1.cameIn }
        for (index, window) in windowNodes.enumerated() {
            place[window.id] = windowNodes.count == 1
                ? .zero
                : ring(index, of: windowNodes.count, radius: 420)
        }
        ringChildren(of: windowNodes.map(\.id), radius: 190, into: &place)
        let groupIDs = nodes.filter { if case .group = $0.kind { true } else { false } }.map(\.id)
        ringChildren(of: groupIDs, radius: 46, into: &place)
        // Current scene records can have more than two containment levels.
        for _ in 0..<nodes.count {
            let unplaced = edges.filter { $0.kind != .effect && place[$0.from] != nil && place[$0.to] == nil }
            guard !unplaced.isEmpty else { break }
            ringChildren(of: Array(Set(unplaced.map(\.from))), radius: 46, into: &place)
        }

        for (index, node) in nodes.enumerated() where place[node.id] == nil {
            let incoming = edges.first { $0.to == node.id && $0.kind == .effect }
            let outgoing = edges.first { $0.from == node.id && $0.kind == .effect }
            let start = incoming.flatMap { place[$0.from] } ?? .zero
            let end = outgoing.flatMap { place[$0.to] } ?? start
            let angle = CGFloat(index) * 2.399963
            place[node.id] = CGPoint(x: (start.x + end.x) / 2 + 170 * cos(angle),
                                     y: (start.y + end.y) / 2 + 170 * sin(angle))
        }
        for index in nodes.indices { nodes[index].position = place[nodes[index].id] ?? .zero }
    }

    private func ring(
        _ index      : Int,
        of count     : Int,
        radius       : CGFloat,
        around centre: CGPoint = .zero
    ) -> CGPoint {
        let angle = 2 * .pi * CGFloat(index) / CGFloat(max(count, 1)) - .pi / 2
        return CGPoint(
            x: centre.x + radius * cos(angle),
            y: centre.y + radius * sin(angle)
        )
    }

    /// Puts each parent's children on a ring around it, in the order they came in.
    private func ringChildren(
        of parents: [String],
        radius    : CGFloat,
        into place: inout [String: CGPoint]
    ) {
        let arrival = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.cameIn) })
        for parent in parents {
            guard let centre = place[parent] else { continue }

            let children = edges.filter { $0.from == parent && $0.kind != .effect }.map(\.to)
                .sorted { (arrival[$0] ?? .distantPast) < (arrival[$1] ?? .distantPast) }
            let spread = radius + CGFloat(children.count) * 3
            for (index, child) in children.enumerated() {
                place[child] = ring(index, of: children.count, radius: spread, around: centre)
            }
        }
    }
}
