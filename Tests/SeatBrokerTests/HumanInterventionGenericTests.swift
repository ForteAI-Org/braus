import Foundation
import InteractionListener
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionGenericTests {

    @Test func chromiumInspectorEditUsesObservedCaption() throws {
        let before = scene([element("Grid", role: "AXTextField", value: "8", container: "Inspector")],
                           title: "Canvas", app: "Chromium Workspace")
        var after = before
        after.elements[0].value = "12"
        let digest = try digest(initial: [7: before], steps: [
            (action(.typing, label: "Grid", role: "AXTextField"), [7: after])
        ], final: [7: after])
        #expect(digest.text.contains("Grid: 8 → 12"))
        // The field names the change; a generic operation word adds nothing.
        #expect(!digest.text.contains("Edit:"))
        #expect(!digest.text.contains("Rename"))
    }

    @Test(arguments: ["AXButton", "AXCell", "AXRadioButton", "AXMenuItem", "AXRow"])
    func qtAuxiliaryChoiceWithoutVisibleEffect(role: String) throws {
        let document = scene([], title: "Sketch", app: "Qt Workspace")
        let surface = scene([element("Ambre", role: role)], title: "Nuancier", app: "Qt Workspace", small: true)
        let digest = try digest(initial: [7: document], steps: [
            (action(label: "Styles", role: "AXButton"), [8: surface]),
            (action(label: "Ambre", role: role, window: 8, title: "Nuancier"), [8: surface])
        ], final: [7: document], finalText: "window #8: read failed: surface unavailable")
        #expect(digest.text.contains("Unobserved: Nuancier → Ambre (window unreadable at end)."))
    }

    @Test func delayedCustomChoiceUsesNativeLabelFromCoveringRead() throws {
        let document = scene([], title: "Workspace", app: "Custom UI")
        let surface = scene([element("Dotted", role: "AXCell")], title: "Patterns", app: "Custom UI", small: true)
        var opener = try finding(1, action(label: "Patterns", role: "AXButton"), [7: document])
        opener.coveredBySequence = 1
        var choice = try finding(2, action(label: "Dotted", window: 8, title: "Patterns"), [:])
        choice.coveredBySequence = 3
        let read = try finding(3, action(.drag, window: 8, title: "Patterns"), [8: surface])
        let final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "", readMilliseconds: 1,
                                          scenes: [7: document], initialScenes: [7: document])
        let digest = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, choice, read], finalState: final))
        #expect(digest.text.contains("Unobserved: Patterns → Dotted"))
    }

    @Test func documentAndUnopenedSurfaceClicksAreNotOpaqueCommits() throws {
        let document = scene([element("Dotted", role: "AXButton")], title: "Workspace")
        let surface = scene([element("Dotted", role: "AXButton")], title: "Patterns", small: true)
        for window in [7, 8] {
            let digest = try digest(initial: [7: document, 8: surface], steps: [
                (action(label: "Dotted", role: "AXButton", window: window), [window: window == 7 ? document : surface])
            ], final: [7: document, 8: surface])
            #expect(!digest.text.contains("performed, not verified"))
        }
    }


    @Test func displayRolesAndNumericUnitsDoNotNeedLabelVocabulary() {
        #expect(!HumanInterventionChanges.hasRelevantValue(element("Status", role: "AXValueIndicator", value: "busy")))
        #expect(!HumanInterventionChanges.hasRelevantValue(element("Flux", role: "AXStaticText", value: "12 widgets/s")))
        #expect(HumanInterventionChanges.isRelevant(element("Grid", role: "AXTextField", value: "12")))
    }

    @Test func autonomousChangesInvalidateIncidentalInputAttribution() throws {
        let before = scene([element("Flux", role: "AXTextField", value: "idle")], title: "Workspace")
        var during = before
        during.elements[0].value = "busy"
        var after = before
        after.elements[0].value = "waiting"
        let digest = try digest(initial: [7: before], steps: [
            (action(label: "Inspect", role: "AXButton"), [7: during])
        ], final: [7: after])
        #expect(digest.evidence.ledger.effects.isEmpty)
        #expect(digest.text.hasPrefix("No changes made."))
    }


    @Test func modalChoiceWaitsForDialogConclusion() throws {
        let document = scene([], title: "Workspace")
        let dialog = scene([element("Dotted", role: "AXRadioButton"), element("OK", role: "AXButton"),
                            element("Cancel", role: "AXButton")], title: "Patterns", small: true)
        let digest = try digest(initial: [7: document], steps: [
            (action(label: "Patterns", role: "AXButton"), [8: dialog]),
            (action(label: "Dotted", role: "AXRadioButton", window: 8, title: "Patterns"), [8: dialog])
        ], final: [7: document, 8: dialog])
        #expect(!digest.text.contains("performed, not verified"))
    }

    @Test func auxiliaryChoiceRequiresTheOpenersProcess() throws {
        let document = scene([], title: "Workspace")
        let surface = scene([element("Dotted", role: "AXCell")], title: "Patterns", small: true)
        let digest = try digest(initial: [7: document], steps: [
            (action(label: "Patterns", role: "AXButton"), [8: surface]),
            (action(label: "Dotted", role: "AXCell", window: 8, title: "Patterns", process: 99), [8: surface])
        ], final: [7: document])
        #expect(!digest.text.contains("performed, not verified"))
    }

    @Test func distinctImmediateChoicesKeepBothOperands() throws {
        let document = scene([], title: "Workspace")
        let surface = scene([element("Dotted", role: "AXCell"), element("Solid", role: "AXCell")],
                            title: "Patterns", small: true)
        let digest = try digest(initial: [7: document], steps: [
            (action(label: "Patterns", role: "AXButton"), [8: surface]),
            (action(label: "Dotted", role: "AXCell", window: 8, title: "Patterns"), [8: surface]),
            (action(label: "Solid", role: "AXCell", window: 8, title: "Patterns"), [8: surface])
        ], final: [7: document])
        // One surface, same (unknown) affected set: one line that keeps both distinct choices.
        #expect(digest.text.contains("Unobserved: Patterns → Dotted, Solid"))
        #expect(digest.evidence.threads.roots.filter { $0.operation == .choice }.count == 2)
    }

    @Test(arguments: ["Cancel", "Close"])
    func auxiliaryDismissalIsNotAnImmediateApply(label: String) throws {
        let document = scene([], title: "Workspace")
        let surface = scene([element(label, role: "AXButton")], title: "Patterns", small: true)
        let digest = try digest(initial: [7: document], steps: [
            (action(label: "Patterns", role: "AXButton"), [8: surface]),
            (action(label: label, role: "AXButton", window: 8, title: "Patterns"), [8: surface])
        ], final: [7: document])
        #expect(!digest.text.contains("performed, not verified"))
    }

    @Test func reusedSurfaceDoesNotBorrowAnOpenerFromItsClosedLifetime() throws {
        let document = scene([], title: "Workspace")
        let surface = scene([element("Dotted", role: "AXCell")], title: "Patterns", small: true)
        let opener = try finding(1, action(label: "Patterns", role: "AXButton"), [8: surface])
        var closed = try HumanSceneFinding(sequence: 2, kind: .changes, text: "", readMilliseconds: 1,
                                          scenes: [7: document], closedWindowNumbers: [8])
        closed.recordedAction = action(.scroll, window: 7)
        let reused = try finding(3, action(label: "Dotted", role: "AXCell", window: 8, title: "Patterns"), [8: surface])
        let final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "", readMilliseconds: 1,
                                          scenes: [7: document], initialScenes: [7: document])
        let digest = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [opener, closed, reused], finalState: final))
        #expect(!digest.text.contains("performed, not verified"))
    }


    @Test func digestSourcesContainNoApplicationRules() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/SeatBroker/Seat")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("HumanIntervention") && $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let code = Self.withoutComments(try String(contentsOf: file, encoding: .utf8))
            for forbidden in ["com.avid", "Pro Tools", "Color Palette", "Track Name"] {
                #expect(!code.localizedCaseInsensitiveContains(forbidden), "\(file.lastPathComponent): \(forbidden)")
            }
            #expect(code.range(of: #"\b(?:com|org|net|io)\.[A-Za-z][A-Za-z0-9_.-]+"#,
                               options: .regularExpression) == nil, "\(file.lastPathComponent): bundle ID")
        }
    }

    @Test func sourceGuardSkipsCommentsButKeepsStringLiterals() {
        #expect(Self.withoutComments("// Pro Tools\nlet title = \"Color Palette\" /* Track Name */")
                .contains("Color Palette"))
        #expect(!Self.withoutComments("/* outer /* Pro Tools */ Track Name */\n// com.avid").contains("Track Name"))
    }

    private static func withoutComments(_ source: String) -> String {
        let characters = Array(source)
        var result = "", index = 0, depth = 0
        var quoted = false, escaped = false, line = false
        while index < characters.count {
            let char = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"
            if line {
                if char == "\n" { line = false; result.append(char) }
            } else if depth > 0 {
                if char == "/" && next == "*" { depth += 1; index += 1 }
                else if char == "*" && next == "/" { depth -= 1; index += 1 }
            } else if quoted {
                result.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "/" && next == "/" { line = true; index += 1 }
            else if char == "/" && next == "*" { depth = 1; index += 1 }
            else { result.append(char); quoted = char == "\"" }
            index += 1
        }
        return result
    }

    private func digest(initial: [Int: SceneSnapshot],
                        steps: [(HumanRecordedInteraction.SummaryAction, [Int: SceneSnapshot])],
                        final: [Int: SceneSnapshot], finalText: String = "") throws -> HumanInterventionSummary.Digest {
        let findings = try steps.enumerated().map { try finding(UInt64($0.offset + 1), $0.element.0, $0.element.1) }
        let final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: finalText, readMilliseconds: 1,
                                          scenes: final, initialScenes: initial)
        return HumanInterventionSummary.digest(HumanInterventionEvidence(findings: findings, finalState: final))
    }

    private func finding(_ sequence: UInt64, _ action: HumanRecordedInteraction.SummaryAction,
                         _ scenes: [Int: SceneSnapshot]) throws -> HumanSceneFinding {
        var result = try HumanSceneFinding(sequence: sequence, kind: .changes, text: "", readMilliseconds: 1, scenes: scenes)
        result.recordedAction = action
        return result
    }

    private func action(_ kind: InteractionEvent.Kind = .click, label: String? = nil, role: String? = nil,
                        window: Int = 7, title: String = "Workspace", command: String? = nil,
                        process: Int32 = 42) -> HumanRecordedInteraction.SummaryAction {
        .init(kind: kind, processID: process, windowNumber: window, windowTitle: title, role: role,
              label: label, isProtected: false, destination: nil, commandName: command, lostCritical: 0)
    }

    private func element(_ label: String, role: String, value: String? = nil, container: String? = nil) -> PerceptionCore.SceneElement {
        .init(id: "control|" + label, kind: .control, label: label,
              bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1), role: role, value: value, container: container)
    }

    private func scene(_ elements: [PerceptionCore.SceneElement], title: String, app: String = "Test", small: Bool = false) -> SceneSnapshot {
        .init(bundleID: "test", appName: app, windowTitle: title,
              viewportPixelSize: .init(width: small ? 300 : 1000, height: small ? 200 : 800), elements: elements)
    }
}
