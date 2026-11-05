import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore

/// ToolResultSession preserves call order and ID invalidation without touching a real application.
@MainActor
final class ToolResultSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var memoryDirectory: URL?
    var memoryApplication: String?
    var closeWarning: String?
    var seatNotice: String?
    var browserNotice: String?
    var observedWindowNumber: Int?
    var calls: [String] = []
    var openedWindowTitles: [String?] = []
    var results: [ActOutcomeKind] = []
    var actionError: (any Error)?
    var openingFailure: (any Error)?
    var actionResult: ActOutcome?
    var throwOnTarget: String?
    var observationFailure: AutomationFailure?
    var endsWhenObserved = false
    var endsWhenActFails = false
    var inputs: [InputRequest.Input] = []
    var sections: [String?] = []
    var discoveryRows: [WindowRow] = []
    var discoveryReads: [pid_t] = []
    var scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer",
                              windowTitle: "Synthetic New Paths",
                              viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        if let openingFailure { throw openingFailure }
        openedWindowTitles.append(window)
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot {
        calls.append("observe")
        if let observationFailure {
            if endsWhenObserved { id = nil }
            throw observationFailure
        }
        return scene
    }

    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        discoveryReads.append(processID)
        return discoveryRows
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        calls.append(target)
        if let actionError { throw actionError }
        if let actionResult { return actionResult }
        if target == throwOnTarget {
            if endsWhenActFails { id = nil }
            throw AutomationFailure("Synthetic transport failure after an earlier effect.")
        }
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic result", scene: scene)
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        return ActOutcome(.foundActed, "synthetic selection", scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        inputs.append(input)
        sections.append(section)
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic input", scene: scene)
    }

    func classify(_ input: InputRequest.Input, section: String?) async -> TextTargetClass {
        .secure
    }

    func menu(path: String) async throws -> ActOutcome {
        calls.append("menu: \(path)")
        return ActOutcome(.foundActed, "synthetic menu", scene: scene)
    }

    func close() async { calls.append("close"); id = nil }
}
