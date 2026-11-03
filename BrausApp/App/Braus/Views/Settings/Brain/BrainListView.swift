//
//  BrainListView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Memory
import PerceptionCore
import SwiftUI

/// BrainListView is one application's Brain as a grouped form: a section for
/// each window, with its groups, which open to show their controls, and then
/// the controls in no group; last, what the Brain saw a control do. Each
/// control carries the colour of its kind in the graph, and says how often it
/// was seen only when it was seen more than once. An open group's controls
/// stand apart from the group's own row, one under the other between dividers.
struct BrainListView: View {

    /// Content indexes one loaded Brain once and is retained by the detail page.
    struct Content {
        let brain: UIBrain
        let windows: [String]
        let groupsByWindow: [String: [SiblingGroup]]
        let membersByGroup: [UUID: [ObjectAnchor]]
        let looseByWindow: [String: [ObjectAnchor]]
        let anchorsByKey: [String: ObjectAnchor]

        init(brain: UIBrain) {
            self.brain = brain
            let anchors = Dictionary(brain.objects.map { ($0.anchorKey, $0) }, uniquingKeysWith: { first, _ in first })
            anchorsByKey = anchors
            windows = Array(Set(brain.objects.map { $0.window ?? "window" })).sorted()
            var groups: [String: [SiblingGroup]] = [:]
            var members: [UUID: [ObjectAnchor]] = [:]
            for group in brain.groups {
                members[group.id] = group.memberAnchors.compactMap { anchors[$0] }
                if let first = group.memberAnchors.first, let anchor = anchors[first] {
                    groups[anchor.window ?? "window", default: []].append(group)
                }
            }
            groupsByWindow = groups
            membersByGroup = members
            let grouped = Set(brain.groups.flatMap(\.memberAnchors))
            looseByWindow = Dictionary(grouping: brain.objects.filter { !grouped.contains($0.anchorKey) }) {
                $0.window ?? "window"
            }
        }
    }

    let content: Content
    private var brain: UIBrain { content.brain }

    /// The groups open.
    @State private var open: Set<UUID>

    init(content: Content, opens: Set<UUID> = []) {
        self.content = content
        _open = State(initialValue: opens)
    }

    /// Builds independent content for previews and snapshots.
    init(brain: UIBrain, opens: Set<UUID> = []) {
        self.init(content: Content(brain: brain), opens: opens)
    }

    var body: some View {
        Form {
            ForEach(content.windows, id: \.self) { window in
                Section(window == "window" ? String(localized: "Window") : window.capitalized) {
                    ForEach(groups(in: window), id: \.id) { group in
                        DisclosureGroup(isExpanded: isOpen(group)) {
                            members(members(of: group))
                        } label: {
                            LabeledContent {
                                Text(count(group.memberAnchors.count, of: group.sharedKind))
                            } label: {
                                Label {
                                    Text(group.name ?? String(localized: "Unnamed \(axisTitle(group.axis))"))
                                } icon: {
                                    dot(BrainPalette.colour(of: group.sharedKind))
                                }
                            }
                        }
                    }

                    ForEach(loose(in: window), id: \.anchorKey) { row($0) }
                }
            }

            if !brain.transitions.isEmpty {
                Section(String(localized: "Learned Actions")) {
                    ForEach(brain.transitions.indices, id: \.self) { index in
                        let transition = brain.transitions[index]
                        LabeledContent(String(localized: "\(label(of: transition.anchorKey)), \(triggerTitle(transition.trigger))")) {
                            Text(String(localized: "\(transition.summary). \(evidence(transition.evidence))"))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    /// A group's controls as one block under its row, set in under the group's name, the first
    /// apart from the row and each from the next by a divider.
    private func members(_ anchors: [ObjectAnchor]) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 0
        ) {
            ForEach(Array(anchors.enumerated()), id: \.element.anchorKey) { index, anchor in
                if index > 0 { Divider() }

                row(anchor)
                    .padding(
                        .vertical,
                        6
                    )
            }
        }
        .padding(
            .top,
            10
        )
        .padding(
            .leading,
            24
        )
    }

    private func isOpen(_ group: SiblingGroup) -> Binding<Bool> {
        Binding(
            get: { open.contains(group.id) },
            set: { isOpen in
                if isOpen { open.insert(group.id) } else { open.remove(group.id) }
            }
        )
    }

    private func row(_ anchor: ObjectAnchor) -> some View {
        LabeledContent {
            if anchor.seenCount > 1 { Text(evidence(anchor.seenCount)) }
        } label: {
            Label {
                Text(anchor.label.isEmpty ? String(localized: "Unlabelled \(kindTitle(anchor.kind))") : anchor.label)
                    .foregroundStyle(anchor.label.isEmpty ? .secondary : .primary)
            } icon: {
                dot(BrainPalette.colour(of: anchor.kind))
            }
        }
    }

    private func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour.gradient)
            .frame(
                width : 8,
                height: 8
            )
            .accessibilityHidden(true)
    }

    // MARK: Reading

    private func groups(in window: String) -> [SiblingGroup] { content.groupsByWindow[window] ?? [] }

    private func members(of group: SiblingGroup) -> [ObjectAnchor] { content.membersByGroup[group.id] ?? [] }

    private func loose(in window: String) -> [ObjectAnchor] { content.looseByWindow[window] ?? [] }

    private func label(of anchorKey: String) -> String {
        guard let anchor = content.anchorsByKey[anchorKey], !anchor.label.isEmpty else {
            return String(localized: "A control")
        }
        return anchor.label
    }

    private func count(_ value: Int, of noun: ElementKind) -> String {
        String(localized: "\(value) \(kindTitle(noun, plural: value != 1))")
    }

    private func evidence(_ value: Int) -> String {
        value == 1 ? String(localized: "Seen once") : String(localized: "Seen \(value) times")
    }

    private func axisTitle(_ axis: GroupAxis) -> String {
        switch axis {
        case .row: String(localized: "row")
        case .column: String(localized: "column")
        }
    }

    private func kindTitle(_ kind: ElementKind, plural: Bool = false) -> String {
        switch kind {
        case .text: plural ? String(localized: "texts") : String(localized: "text")
        case .icon: plural ? String(localized: "icons") : String(localized: "icon")
        case .control: plural ? String(localized: "controls") : String(localized: "control")
        case .image: plural ? String(localized: "images") : String(localized: "image")
        case .overlayCandidate:
            plural ? String(localized: "overlay-candidates") : String(localized: "overlay-candidate")
        }
    }

    private func triggerTitle(_ trigger: TransitionTrigger) -> String {
        switch trigger {
        case .hover:      String(localized: "Hover")
        case .click:      String(localized: "Click")
        case .rightClick: String(localized: "Right-click")
        }
    }
}
