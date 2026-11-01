//
//  ActionTargeting.swift
//  Braus
//
//  Created by Codex on 01/11/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// Resolves action targets and reads their current window context.
extension ActionEngine {

    /// The field of the scene after typing that is the one typed into, when its id moved with its value: the
    /// one element of the same role and kind whose centre lies within the field's place before typing, widened by
    /// half a percent of the window. A field named by what it holds ("foto_3 copy.psd" in a save panel whose
    /// accessibility answers no focus, as in PhotoCraft's, 14 October 2026) takes a new id once it holds the typed
    /// name, and while it is edited it may report a smaller frame inside its own (0.153 wide before, 0.090 after,
    /// live); nil for none or several.
    static func sameField(as element: SceneElement, in after: SceneSnapshot) -> SceneElement? {
        let margin = 0.005, place = element.bounds
        let matches = after.elements.filter {
            let x = $0.bounds.x + $0.bounds.width / 2, y = $0.bounds.y + $0.bounds.height / 2
            return $0.role == element.role && $0.kind == element.kind
                && place.x - margin <= x && x <= place.x + place.width + margin
                && place.y - margin <= y && y <= place.y + place.height + margin
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// The refusal for an input that would close the only window of the application, or nil when
    /// the window is not that, a pop-up is open (the key then closes it) or the person allowed it.
    /// The alternatives are real buttons of the scene, never a Cancel the window does not have.
    func windowClosureRefusal(
        _ what      : String,
        appName     : String,
        scene       : SceneSnapshot,
        hasOpenPopup: Bool
    ) -> ActOutcome? {
        guard permissions.windowClosure.mayEndTheApplication, !permissions.allowsDestructive,
              !hasOpenPopup
        else { return nil }
        let alternatives = scene.elements.filter {
            $0.kind == .control && $0.role == "AXButton" && !$0.isUnlabeled && $0.isEnabled != false
                && !ActionPolicy.isWindowClosingLabel($0.label) && !ActionPolicy.isDestructive(label: $0.label)
        }.prefix(3).map(\.label)
        return ActOutcome(
            .refused,
            ActionPolicy.windowClosureRefusal(
                what, window: scene.windowTitle, application: appName, alternatives: alternatives
            ),
            scene: scene
        )
    }

    // MARK: Helpers

    /// The roles whose contextual menu opens where the click landed, in every toolkit measured.
    static let textFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The role of a field whose value no reader may return: a password field. The MacDriver's scenes and the
    /// web's name it so; it carries no value, and typing into it is never read back.
    static let secureFieldRole = "AXSecureTextField"

    /// The refusal of a right click whose menu would open outside the seat, nil when it may go ahead.
    func menuOutsideTheSeat(on element: SceneElement, appName: String, scene: SceneSnapshot) -> ActOutcome? {
        guard permissions.contextMenusOnTextFieldsOnly, !Self.textFieldRoles.contains(element.role ?? "") else {
            return nil
        }
        return ActOutcome(.refused, "\(appName) opens the contextual menu of '\(element.label)' on the person's own "
            + "screen, outside the seat, so it was not right-clicked: use a visible button or control instead. "
            + "A text field's contextual menu still works here.", scene: scene)
    }

    /// The element a target names in this scene, or the outcome that says why there is none: several
    /// share the name, or none has it.
    func resolved(
        _ target            : String,
        section             : String?,
        in scene            : SceneSnapshot,
        appName             : String,
        preferStateful      : Bool = false,
        preferNativeControls: Bool = false,
        preferTextEntry      : Bool = false
    ) throws(Unresolved) -> SceneElement {
        let resolution = scene.resolve(
            target: target, preferStateful: preferStateful, section: section,
            preferNativeControls: preferNativeControls, preferTextEntry: preferTextEntry
        )
        switch resolution {
            case .found(let found):
                return found
            case .ambiguous(let count):
                throw Unresolved(outcome: ActOutcome(
                    .ambiguous,
                    "\(count) elements labeled '\(target)': choose an exact element ID or section: "
                    + scene.disambiguation(target: target), scene: scene))
            case .none:
                let near = scene.grep(goal: target).prefix(3)
                    .map { "'\($0.element.label)'" + ($0.element.section.map { " (\($0))" } ?? "") }
                throw Unresolved(outcome: ActOutcome(.honestMiss, "no element '\(target)' in \(appName)"
                    + (near.isEmpty ? "" : ": closest on screen: \(near.joined(separator: ", "))"), scene: scene))
        }
    }

    /// Why a target named no element, as the outcome that says so.
    struct Unresolved: Error {
        let outcome: ActOutcome
    }

    func perceive(_ processID: pid_t) async -> PerceivedWindow? {
        let window = try? await dependencies.scenes.currentScene(of: processID)
        if let window { Self.inputTrail?.append(window) }
        return window
    }

    func surfaces(_ processID: pid_t) async -> WindowSurfaces {
        let rows = (try? await dependencies.windows.windows(ownedBy: processID)) ?? []
        return WindowSurfaceClassifier.classify(rows)
    }

    func noSceneReason(appName: String, processID: pid_t) async -> String {
        let rows = (try? await dependencies.windows.windows(ownedBy: processID)) ?? []
        let ordinary = rows.filter { $0.layer == 0 && $0.frame.width >= 60 }
        if ordinary.isEmpty {
            return "no scene: \(appName) has NO window open right now "
                + "(it is running, but there is nothing to show or "
                + "capture). "
                + "Open a document or window in it first, then describe_scene."
        }
        return "no scene: \(appName) has a window but it could not be perceived right now; "
            + "retry, and if this repeats "
            + "check Screen Recording for the process that runs the engine."
    }
}
