import Foundation
import CoreGraphics
import InteractionListener
import InteractionObservation
import Engine
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionPhaseTwoTests {
    @Test func idleGapSplitsOtherwiseIdenticalThreads() throws {
        let first = try timedAction(start: 10, end: 11)
        let second = try timedAction(start: 42, end: 43)
        let threads = HumanInterventionThreads(actions: [first, second], sequences: [1, 2], scenes: [:])
        #expect(threads.roots.count == 2)
        #expect(threads.owners == [0, 1])
    }

    @Test func returnTextIncludesFocusedFieldAndWindow() throws {
        var action = try timedAction(start: 10, end: 11, kind: .shortcut, label: "Name",
                                     role: "AXTextField", command: "Return", title: "New Items")
        action.provenance = provenance(state())
        #expect(HumanInterventionEvidence.action(action) == "Return in text field 'Name' (New Items)")
    }

    @Test func selectionAtActionAttributesPaletteChoiceButLaterReadDoesNot() throws {
        let document = scene([], title: "Workspace")
        let palette = scene([element("Dotted", role: "AXCell")], title: "Patterns", small: true)
        let opener = try finding(1, action(label: "Patterns", role: "AXButton"), [8: palette])
        var choice = action(label: "Dotted", role: "AXCell", window: 8, title: "Patterns")
        var state = state()
        state.elements[1].selected = .value(true)
        var second = InteractionSemanticSnapshot.Element(id: 3, window: 7, role: "AXRow", label: "Beta", parent: 2)
        second.selected = .value(true)
        state.elements.append(second)
        state.elements[2].selectedRows = .value([1, 3])
        choice.provenance = provenance(state)
        let final = try finding(0, nil, [7: document], initial: [7: document])
        var read = try finding(2, choice, [8: palette])
        let supported = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, read], finalState: final))
        #expect(supported.text.contains("Unobserved: Patterns → Dotted on Alpha, Beta."))
        #expect(supported.evidence.threads.roots.first { $0.operation == .choice }?.affected == ["Alpha", "Beta"])

        // Later input fenced out the post-action probe; the pre-action state still attests the selection
        // for a choice on another surface, which cannot change the document's selection itself.
        choice.provenance?.stateAtAction = false
        read.recordedAction = choice
        let fenced = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, read], finalState: final))
        #expect(fenced.text.contains(" on Alpha, Beta"))
        // Without a pre-action observation, a later read's selection never names the affected objects.
        choice.provenance?.beforeSemantics = nil
        read.recordedAction = choice
        read.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "textOnly", semantics: state)])
        let unverified = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, read], finalState: final))
        #expect(!unverified.text.contains(" on Alpha"))
        choice.provenance = provenance(state)
        choice.provenance?.semantics?.interval = .init(start: 20, end: 20.02)
        choice.provenance?.beforeSemantics = nil
        read.recordedAction = choice
        #expect(!HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, read], finalState: final)).text.contains(" on Alpha"))
        // A post-action observation that disagrees always wins over the pre-action one.
        choice.provenance = provenance(state)
        choice.provenance?.semantics?.elements[2].selectedRows = .value([1])
        read.recordedAction = choice
        #expect(!HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, read], finalState: final)).text.contains(" on Alpha"))
    }

    @Test func focusedFieldAndRowSeparateRenameFromCreationDialog() throws {
        var typing = action(.typing, label: "Name", role: "AXTextField")
        typing.provenance = provenance(state())
        let menu = action(label: "Items", role: "AXMenuBarItem")
        let new = action(label: "New...", role: "AXMenuItem")
        var rename = HumanInterventionThreads(actions: [menu, new, typing], sequences: [1, 2, 3], scenes: [:], documentByAction: [0: 7, 1: 7, 2: 7])
        #expect(rename.roots.count == 2)
        #expect(rename.roots.last?.operation == .edit)
        #expect(rename.roots.last?.focusedRow == "Alpha")
        #expect(rename.roots.last?.path.isEmpty == true)
        typing.provenance?.semantics?.elements.removeSubrange(1...)
        typing.provenance?.beforeSemantics?.elements.removeSubrange(1...)
        typing.provenance?.beforeSemantics?.elements[0].parent = nil
        typing.provenance?.semantics?.elements[0].parent = nil
        typing.provenance?.semantics?.elements[0].window = 8
        typing.provenance?.beforeSemantics?.elements[0].window = 8
        typing = .init(kind: typing.kind, processID: 42, windowNumber: 8, windowTitle: "New Items",
            role: typing.role, label: typing.label, isProtected: false, destination: nil,
            commandName: nil, lostCritical: 0, provenance: typing.provenance)
        rename = HumanInterventionThreads(actions: [menu, new, typing], sequences: [1, 2, 3], scenes: [:], documentByAction: [0: 7, 1: 7, 2: 7])
        #expect(rename.roots.count == 1)
        #expect(rename.roots.first?.operation == .create)
        #expect(rename.roots.first?.focusedRow == nil)
    }


    @Test func archivesRoundTripTheirStructuralReads() async throws {
        // Archives are version 3 only: an older manifest is refused, never half read.
        let old = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: old) }
        try Data(#"{"version":1,"actions":[],"findingCount":0}"#.utf8).write(to: old.appendingPathComponent("review.json"))
        await #expect(throws: (any Error).self) { try await HumanInterventionReplay.read(old) }
        var value = try finding(1, action(.shortcut, label: "Name", role: "AXTextField", command: "Return"), [:])
        value.recordedAction?.provenance = provenance(state())
        // Version 3 keeps the structural read of the surface.
        var window = InteractionStructuralRead.Window(number: 7, title: "Files")
        window.collections = [.init(role: "AXList", name: "icon view", identifier: nil, count: 1,
                                    members: [.init(index: 0, name: "Alpha")], coverage: .complete, visible: [0])]
        let structure = InteractionStructuralRead(processID: 42, interval: .init(start: 11.2, end: 11.3), windows: [window])
        value.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "textOnly",
            capture: .init(start: 11, end: 11.1), accessibility: .init(start: 11.1, end: 11.2), semantics: state(),
            structure: structure)])
        let intervention = try HumanInterventionConsumer.Intervention(maximumEvents: 4, maximumRetainedBytes: 1_000_000)
        let payload = HumanRecordedInteraction(event: .init(kind: .shortcut, timestamp: Date(), startedAt: 10,
            endedAt: 11, precedingRevision: 0, revision: 1, point: .zero, window: nil, processID: 42),
            element: nil, endElement: nil, commandName: "Return", picture: nil)
        _ = try await intervention.record(payload, retainedBytes: payload.retainedBytes)
        let work = try #require(await intervention.next())
        try await intervention.complete(work, with: value)
        let revision = try await intervention.endInput()
        let final = try finding(0, nil, [:])
        let review = try await intervention.beginReview(revision, finalState: final)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await HumanInterventionReplay.write(review, to: directory)
        let decoded = try await HumanInterventionReplay.read(directory)
        #expect(decoded.version == 3)
        #expect(decoded.findings.first?.provenance?.surfaces.first?.structure == structure)
        #expect(decoded.findings.first?.recordedAction?.provenance?.interval == .init(start: 10, end: 11))
        #expect(decoded.findings.first?.recordedAction?.provenance?.semantics == state())
        #expect(decoded.findings.first?.provenance?.surfaces.first?.accessibility == .init(start: 11.1, end: 11.2))
        await intervention.close()
    }

    @Test func postActionFocusAloneCannotNameTheRecipientOrAffectedObjects() {
        var after = state()
        after.elements[1].label = "Next row"
        after.elements[1].selected = .value(true)
        let payload = HumanRecordedInteraction(event: .init(kind: .shortcut, timestamp: Date(), startedAt: 10,
            endedAt: 11, precedingRevision: 0, revision: 1, point: .zero,
            window: .init(processID: 42, number: 7, title: nil, layer: 0, frame: .zero), processID: 42),
            element: nil, endElement: nil, semantics: after, stateAtAction: true, commandName: "Return", picture: nil)
        #expect(payload.summaryAction.label == nil)
        #expect(HumanInterventionEvidence.action(payload.summaryAction) == "Return")
        var differentWindow = action(.shortcut, window: 8, command: "Return")
        differentWindow.provenance = provenance(state())
        #expect(HumanInterventionEvidence.action(differentWindow) == "Return")
    }

    @Test func menuCommandRetainsSelectedTargetsInItsDocument() {
        let menu = action(label: "Objects", role: "AXMenuBarItem")
        var command = action(label: "Normalize", role: "AXMenuItem")
        command.provenance = provenance(state())
        let threads = HumanInterventionThreads(actions: [menu, command], sequences: [1, 2],
                                               scenes: [:], documentByAction: [0: 7, 1: 7])
        #expect(threads.roots.first?.affected == ["Alpha"])
        #expect(threads.roots.first?.conclusions.isEmpty == true)
    }

    @Test func changedFocusAndMultipleCollectionsCannotBorrowTargetAttribution() {
        let first = state()
        var evidence = provenance(first)
        evidence.semantics?.elements[1].label = "Next row"
        #expect(evidence.attestedState == nil)
        #expect(evidence.affectedObjects(in: 7, processID: 42).isEmpty)
        evidence = provenance(first)
        evidence.semantics?.elements[0].window = 8
        #expect(evidence.attestedState == nil)
        var ambiguous = first
        ambiguous.focused = .unsupported
        var collection = InteractionSemanticSnapshot.Element(id: 3, window: 7, role: "AXTable", label: "Other objects")
        collection.selectedRows = .value([4])
        ambiguous.elements += [collection, .init(id: 4, window: 7, role: "AXRow", label: "Elsewhere", parent: 3)]
        evidence = provenance(ambiguous)
        #expect(evidence.affectedObjects(in: 7, processID: 42).isEmpty)
        evidence = provenance(first)
        evidence.semantics?.elements[2].selectionIncomplete = true
        #expect(evidence.affectedObjects(in: 7, processID: 42).isEmpty)
    }

    private func provenance(_ state: InteractionSemanticSnapshot) -> HumanActionProvenance {
        var before = state
        before.interval = .init(start: 9, end: 9.02)
        return .init(interval: .init(start: 10, end: 11), sourceSequence: 1, targetInferred: false,
              stateAtAction: true, semantics: state, beforeSemantics: before)
    }

    private func state() -> InteractionSemanticSnapshot {
        var state = InteractionSemanticSnapshot(processID: 42, interval: .init(start: 11.01, end: 11.03))
        state.focused = .value(0)
        state.elements = [.init(id: 0, window: 7, role: "AXTextField", label: "Name", parent: 1),
                          .init(id: 1, window: 7, role: "AXRow", label: "Alpha", parent: 2),
                          .init(id: 2, window: 7, role: "AXTable", label: "Objects")]
        state.elements[2].selectedRows = .value([1])
        state.windowTitles = [7: "Workspace"]
        return state
    }

    private func action(_ kind: InteractionEvent.Kind = .click, label: String? = nil, role: String? = nil,
                        window: Int = 7, title: String = "Workspace", command: String? = nil) -> HumanRecordedInteraction.SummaryAction {
        .init(kind: kind, processID: 42, windowNumber: window, windowTitle: title, role: role, label: label,
              isProtected: false, destination: nil, commandName: command, lostCritical: 0)
    }

    private func finding(_ sequence: UInt64, _ action: HumanRecordedInteraction.SummaryAction?,
                         _ scenes: [Int: SceneSnapshot], initial: [Int: SceneSnapshot] = [:]) throws -> HumanSceneFinding {
        var value = try HumanSceneFinding(sequence: sequence, kind: .keyframe, text: "", readMilliseconds: 1,
                                          scenes: scenes, initialScenes: initial)
        value.recordedAction = action
        return value
    }

    private func element(_ label: String, role: String, value: String? = nil) -> PerceptionCore.SceneElement {
        .init(id: role + "|" + label, kind: .control, label: label,
              bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1), role: role, value: value)
    }

    private func scene(_ elements: [PerceptionCore.SceneElement], title: String, small: Bool = false) -> SceneSnapshot {
        .init(bundleID: "fixture", appName: "Workspace", windowTitle: title,
              viewportPixelSize: .init(width: small ? 400 : 1200, height: small ? 220 : 900), elements: elements)
    }

    private func timedAction(start: Double, end: Double, kind: InteractionEvent.Kind = .scroll,
                             label: String? = nil, role: String? = nil, command: String? = nil,
                             title: String = "Workspace") throws -> HumanRecordedInteraction.SummaryAction {
        let action = HumanRecordedInteraction.SummaryAction(kind: kind, processID: 42, windowNumber: 7,
            windowTitle: title, role: role, label: label, isProtected: false, destination: nil,
            commandName: command, lostCritical: 0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        json["provenance"] = ["version": 1, "interval": ["start": start, "end": end],
                              "sourceSequence": 1, "targetInferred": false, "stateAtAction": false]
        return try JSONDecoder().decode(HumanRecordedInteraction.SummaryAction.self,
                                         from: JSONSerialization.data(withJSONObject: json))
    }
}
