import Foundation
import InteractionListener
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionThreadsTests {
    @Test func interleavedPendingDialogsReturnToTheirOwnRoot() {
        let actions = [action(label: "Settings", role: "AXMenuBarItem", window: 7),
            action(label: "Apply", role: "AXButton", window: 7),
            action(label: "Settings", role: "AXMenuBarItem", window: 8),
            action(label: "Apply", role: "AXButton", window: 8),
            action(label: "Cancel", role: "AXButton", window: 7),
            action(label: "Cancel", role: "AXButton", window: 8)]
        let threads = partition(actions)
        #expect(threads.roots.count == 2)
        #expect(threads.roots.map(\.actions) == [[0, 1, 4], [2, 3, 5]])
        #expect(threads.roots.map { $0.terminal?.kind } == [.cancel, .cancel])
    }

    @Test func childPopupCancellationDoesNotCancelTheParent() {
        let actions = [action(label: "Settings", role: "AXMenuBarItem", window: 7),
            action(label: "Apply", role: "AXButton", window: 7),
            action(label: "Choice", role: "AXMenuItem", window: 99, title: "Choice"),
            action(label: "Cancel", role: "AXButton", window: 99, title: "Choice"),
            action(label: "Apply", role: "AXButton", window: 7),
            action(label: "Cancel", role: "AXButton", window: 7)]
        let threads = partition(actions)
        #expect(threads.roots[0].actions == [0, 1, 2, 3, 4, 5])
        #expect(threads.roots[0].conclusions.map(\.kind) == [.apply, .apply, .cancel])
    }

    private func partition(_ actions: [HumanRecordedInteraction.SummaryAction]) -> HumanInterventionThreads {
        HumanInterventionThreads(actions: actions, sequences: actions.indices.map { UInt64($0 + 1) },
            scenes: [7: scene([], title: "Document")], documentByAction: [0: 7])
    }

    private func action(kind: InteractionEvent.Kind = .click, label: String? = nil, role: String? = nil,
                        window: Int = 7, title: String = "Document", command: String? = nil) -> HumanRecordedInteraction.SummaryAction {
        .init(kind: kind, processID: 42, windowNumber: window, windowTitle: title, role: role,
              label: label, isProtected: false, destination: nil, commandName: command, lostCritical: 0)
    }

    private func finding(_ sequence: Int, _ action: HumanRecordedInteraction.SummaryAction,
                         _ scenes: [Int: SceneSnapshot]) throws -> HumanSceneFinding {
        var result = try HumanSceneFinding(sequence: UInt64(sequence), kind: .changes, text: "", readMilliseconds: 1, scenes: scenes)
        result.recordedAction = action
        return result
    }

    private func element(_ name: String, role: String, value: String? = nil, container: String? = nil) -> PerceptionCore.SceneElement {
        .init(id: "control|" + name, kind: .control, label: name,
              bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.1), role: role, value: value, container: container)
    }

    private func scene(_ elements: [PerceptionCore.SceneElement], title: String) -> SceneSnapshot {
        .init(bundleID: "test", appName: "Test", windowTitle: title, viewportPixelSize: .init(width: 800, height: 600), elements: elements)
    }
}
