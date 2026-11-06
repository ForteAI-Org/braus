import Memory
import SwiftUI

/// BrainStoredListView explains saved readings and action outcomes without promoting them to tasks.
/// Structure and technical identifiers remain inspectable without competing with the results.
struct BrainStoredListView: View {
    let inspection: BrainInspection
    private var brain: StoredBrain { inspection.brain }

    init(brain: StoredBrain) { inspection = BrainInspection(brain) }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Observed screens"), value: brain.scenes.count.formatted())
                LabeledContent(String(localized: "Element records across screens"), value: brain.elements.count.formatted())
                LabeledContent(String(localized: "Saved action relationships"), value: brain.relations.count.formatted())
                LabeledContent(String(localized: "Awaiting confirmation"),
                               value: brain.relations.count { $0.standing == .candidate }.formatted())
                LabeledContent(String(localized: "Available for reuse"),
                               value: brain.relations.count { $0.standing == .exposed }.formatted())
                LabeledContent(String(localized: "Limited reuse"),
                               value: brain.relations.count { $0.standing == .limited }.formatted())
                DisclosureGroup(String(localized: "How to read these numbers")) {
                    explanation(String(localized: "Each numbered screen is a saved interface state. Its number identifies it in this view, not a step of a procedure."))
                    explanation(String(localized: "Element records include controls, containers and lists. The same control may have a record in several screens."))
                    explanation(String(localized: "A relationship links an action to an observed result. Matching and conflicting results count distinct tool calls, not completed tasks."))
                    explanation(String(localized: "Available for reuse means the action-result relationship has enough matching evidence. It does not certify a complete procedure or guarantee the next result."))
                }
            } footer: {
                Text(String(localized: "These numbers describe saved observations, not successful tasks or complete procedures."))
            }
            ForEach(brain.scenes, id: \.id) { scene in
                Section(inspection.scene(scene.id)) {
                    LabeledContent(String(localized: "Saved readings of this screen"), value: scene.observationCount.formatted())
                        .help(String(localized: "How many saved observations were matched to this screen. This is not a count of successful actions."))
                    if !inspection.stateDetails(scene.id).isEmpty {
                        explanation(inspection.stateDetails(scene.id))
                    }
                    ForEach(brain.relations.filter { $0.key.fromSceneID == scene.id }, id: \.relationID) { relation in
                        relationship(relation)
                    }
                    controls(in: scene.id)
                }
            }
            let unplaced = brain.relations.filter { inspection.names[$0.key.fromSceneID] == nil }
            if !unplaced.isEmpty {
                Section(String(localized: "Actions with an unidentified starting screen")) {
                    ForEach(unplaced, id: \.relationID) { relation in relationship(relation) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { Color.houseGround.ignoresSafeArea() }
        .clipped()
    }

    private func relationship(_ relation: BrainRelation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(inspection.actionTitle(relation)).font(.headline)
            fact(String(localized: "Before the action"), inspection.scene(relation.key.fromSceneID))
            fact(String(localized: "Observed result"), BrainInspection.outcome(relation))
            fact(String(localized: "After the action"), inspection.scene(relation.key.toSceneID))
            Text(inspection.evidence(relation)).font(.callout).foregroundStyle(.secondary)
            DisclosureGroup(String(localized: "Technical details")) {
                VStack(alignment: .leading, spacing: 10) {
                    fact(String(localized: "Recorded target"), inspection.target(relation))
                    fact(String(localized: "Relationship identifier"), relation.relationID)
                    if !relation.key.argumentsKey.isEmpty {
                        fact(String(localized: "Recorded arguments"), relation.key.argumentsKey)
                    }
                }
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controls(in sceneID: String) -> some View {
        let elements = inspection.elementsByScene[sceneID, default: []]
        let named = Dictionary(grouping: elements.filter {
            $0.scope == .control && !BrainInspection.isUnnamedControl($0)
        }, by: BrainInspection.element)
        return DisclosureGroup(String(localized: "Controls and structure in this screen")) {
            ForEach(named.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { name in
                let count = named[name, default: []].count
                if count > 1 {
                    LabeledContent(name, value: String(localized: "\(count.formatted()) records"))
                } else {
                    Text(name)
                }
            }
            LabeledContent(String(localized: "Unnamed controls"),
                           value: elements.count { BrainInspection.isUnnamedControl($0) }.formatted())
            LabeledContent(String(localized: "Containers"), value: elements.count { $0.scope == .container }.formatted())
            LabeledContent(String(localized: "Lists and collections"), value: elements.count { $0.scope == .collection }.formatted())
            LabeledContent(String(localized: "Repeated-item structures"), value: elements.count { $0.scope == .itemTemplate }.formatted())
            explanation(String(localized: "Repeated names are grouped for readability. Their records remain separate in memory. Structural elements organize the interface; they are not additional learned actions."))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
