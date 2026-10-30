import Foundation
import InteractionListener
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionReviewTests {
    @Test func withholdingCoversConclusionBeforeEmbeddingAndRendering() throws {
        let label = "Yellowy Brown Bright"
        let action = action(.click, label, "AXButton", window: 8, title: "Color Palette")
        var evidence = try evidence(initial: scene([]), actions: [action], states: [scene([])])
        let safe = evidence.withholding { $0.replacingOccurrences(of: label, with: "[withheld]") }
        #expect(!safe.threadTexts.joined().contains(label))
        #expect(!HumanInterventionSummary.digest(safe).text.contains(label))
    }



    @Test(arguments: ["Grid", "Nudge", "Pre-roll", "Position", "Parameter"])
    func directlyEditedNumericSettingsAreNotReadouts(label: String) throws {
        let before = scene([element(label, role: "AXTextField", value: "1"), element("Meter", role: "AXTextField", value: "2")])
        let after = scene([element(label, role: "AXTextField", value: "3"), element("Meter", role: "AXTextField", value: "4")])
        let result = try evidence(initial: before, actions: [action(.typing, label, "AXTextField")], states: [after])
        #expect(result.ledger.effects.map(\.label) == [label])
    }

    @Test func sameTitleIsNotDialogOwnership() {
        let actions = [action(.click, "Settings", "AXMenuBarItem", title: "Settings"),
            action(.click, "Apply", "AXButton", title: "Settings"),
            action(.typing, "Value", "AXTextField", window: 8, title: "Settings"),
            action(.click, "Cancel", "AXButton", window: 8, title: "Settings")]
        let threads = HumanInterventionThreads(actions: actions, sequences: [1, 2, 3, 4], scenes: [:])
        #expect(threads.roots.map(\.actions) == [[0, 1], [2, 3]])
        #expect(threads.roots.first?.terminal?.kind == .apply)
    }

    @Test func closedDialogDoesNotResumeWhenWindowNumberIsReused() throws {
        let actions = [action(.click, "Settings", "AXMenuBarItem"), action(.click, "Apply", "AXButton"),
                       action(.typing, "Value", "AXTextField"), action(.click, "Cancel", "AXButton")]
        let result = try evidence(initial: scene([]), actions: actions, states: Array(repeating: scene([]), count: 4), closedAfter: 1)
        #expect(result.threads.roots.map(\.actions) == [[0, 1], [2, 3]])
    }

    @Test func saveCarriesOnlyItsTouchedUnreadableSurface() throws {
        let result = try evidence(initial: scene([]), actions: [action(.shortcut, nil, "AXWindow", command: "⌘S")],
                                  states: [scene([])], failure: "window #7: read failed: unavailable\nwindow #99: read failed: unavailable")
        let text = HumanInterventionSummary.digest(result).text
        #expect(text.contains("Unobserved: ⌘S (window unreadable at end)."))
        #expect(!text.contains("#99"))
    }

    @Test func knownDomainToggleSurvivesButSelectionAndUnknownStateDoNot() throws {
        var toggle = element("Snap to grid", role: "AXCheckBox")
        var selection = element("Row selection", role: "AXButton")
        var unread = element("Enabled", role: "AXSwitch")
        toggle.state = .off
        selection.state = .off
        unread.state = .on
        let before = scene([toggle, selection, unread])
        toggle.state = .on
        selection.state = .on
        unread.state = .unknown
        let result = try evidence(initial: before, actions: [action(.click, "Snap to grid", "AXCheckBox")],
                                  states: [scene([toggle, selection, unread])])
        #expect(result.ledger.effects.map(\.label) == ["Snap to grid"])
    }


    private func evidence(initial: SceneSnapshot, actions: [HumanRecordedInteraction.SummaryAction], states: [SceneSnapshot],
                          closedAfter: Int? = nil, failure: String = "") throws -> HumanInterventionEvidence {
        let findings = try actions.enumerated().map { index, action in
            var finding = try HumanSceneFinding(sequence: UInt64(index + 1), kind: .changes, text: "", readMilliseconds: 1,
                scenes: [7: states[index]], closedWindowNumbers: index == closedAfter ? [7] : [])
            finding.recordedAction = action
            return finding
        }
        let final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: failure, readMilliseconds: 1,
            scenes: failure.isEmpty ? [7: states.last ?? initial] : [:], initialScenes: [7: initial])
        return HumanInterventionEvidence(findings: findings, finalState: final)
    }

    private func action(_ kind: InteractionEvent.Kind, _ label: String?, _ role: String?, window: Int = 7,
                        title: String = "Document", command: String? = nil) -> HumanRecordedInteraction.SummaryAction {
        .init(kind: kind, processID: 42, windowNumber: window, windowTitle: title, role: role, label: label,
              isProtected: false, destination: nil, commandName: command, lostCritical: 0)
    }

    private func named(_ name: String) -> SceneSnapshot {
        scene([element("Name \"\(name)\"", role: "AXTextField", value: name, container: name),
               element("Mute", role: "AXButton", container: name), element("Solo", role: "AXButton", container: name)])
    }

    private func element(_ label: String, role: String, value: String? = nil, container: String? = nil) -> PerceptionCore.SceneElement {
        .init(id: "control|" + label, kind: .control, label: label,
              bounds: .init(x: label == "Solo" ? 0.4 : 0.1, y: 0.2, width: 0.2, height: 0.1), role: role, value: value, container: container)
    }

    private func scene(_ elements: [PerceptionCore.SceneElement]) -> SceneSnapshot {
        .init(bundleID: "com.avid.ProTools", appName: "Pro Tools", windowTitle: "Document", viewportPixelSize: .init(width: 800, height: 600), elements: elements)
    }
}
