//
//  HumanInterventionSummaryTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import Perception
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import InteractionObservation
import Memory
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionSummaryTests {

    @Test func secureRolesWithOrdinaryLabelsAreMinimizedBeforeLinking() async throws {
        var initial = scene(["Entry"])
        initial.elements[0].role = "AXSecureTextField"
        initial.elements[0].value = "earlier credential"
        var final = initial
        final.elements[0].value = "later credential"
        final.elements.append(.init(id: "echo", kind: .text, label: "later credential",
                                   bounds: .init(x: 0, y: 0.5, width: 0.1, height: 0.1)))
        final.outOfViewFields = [.init(label: "Entry", value: "offscreen credential", role: "AXSecureTextField")]
        let review = try await review([
            finding(1, payload(.typing, label: "Entry", role: "AXSecureTextField"), scene: initial)
        ], final: [7: final])
        let digest = HumanInterventionSummary.digest(review)
        let embedded = (digest.evidence.embeddingEffects + digest.evidence.embeddingActions).joined(separator: " ")
        for secret in ["earlier credential", "later credential", "offscreen credential"] {
            #expect(!digest.text.contains(secret) && !embedded.contains(secret))
        }
        let retained = try review.finalState.sceneEvidence().scenes[7]
        #expect(retained?.elements[0].value == "[withheld]")
        #expect(retained?.outOfViewFields[0].value == "[withheld]")
    }

    @Test func numericEditableValuesSurviveButDisplayReadoutsDoNot() async throws {
        var initial = scene(["Gain", "Elapsed", "Cursor", "Main Counter", "Edit Selection Start", "Grid/Nudge value"])
        for index in initial.elements.indices {
            initial.elements[index].value = "0"
            initial.elements[index].role = index == 1 ? "AXStaticText" : "AXTextField"
        }
        var final = initial
        for index in final.elements.indices { final.elements[index].value = "42" }
        let digest = HumanInterventionSummary.digest(try await review([
            finding(1, payload(.typing, label: "Gain"), scene: final)
        ], final: [7: final], initial: [7: initial]))
        #expect(digest.evidence.ledger.effects.map(\.label) == ["Gain"])
        #expect(digest.text.contains("Gain: 0 → 42"))
    }

    @Test(arguments: [false, true])
    func consumerCarriesPreControlScenesAndConfirmedClosures(closed: Bool) async throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let surface = InteractionWindow(processID: 42, number: 7, title: "Mix", layer: 0, frame: frame)
        let reader = TrialReader(window: surface, scenes: [scene(["During"]), scene(["Final"])],
                                 finalSurfaces: closed ? [] : [surface])
        let episode = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let consumer = HumanInterventionConsumer(
            intervention: episode,
            window: LentWindow(windowNumber: 7, processID: 42, frame: frame),
            reader: reader,
            buttons: InteractionButtonState(),
            initialScenes: [7: scene(["Before control"])]
        )
        let action = payload()
        let sequence = try await episode.record(action, retainedBytes: action.retainedBytes)
        await consumer.enqueue(sequence, payload: action)
        let review = try await consumer.finish()
        let digest = HumanInterventionSummary.digest(review)
        let text = expanded(digest.text, using: digest.strings)
        if closed {
            #expect(digest.evidence.ledger.effects.isEmpty)
            #expect(text.contains("No changes made."))
            #expect(!text.contains("Final"))
        } else {
            #expect(!text.contains("Before control → Final"))
            #expect(!text.contains("During"))
        }
        #expect(await episode.status().retainedBytes >= review.finalState.compressedBytes)
    }

    @Test func embeddingsCannotPromoteUnattributedObservations() async throws {
        let initial = scene([])
        let findings = try [
            finding(1, payload(label: "Pigment", role: "AXButton"), scene: initial),
            finding(2, payload(label: "Prism", role: "AXButton"), scene: initial),
            finding(3, payload(label: "Pigment", role: "AXButton", window: 19), scene: initial)
        ]
        let review = try await review(findings, final: [7: scene(["Saturated violet"]), 19: initial])
        let fallback = HumanInterventionSummary.digest(review)
        #expect(fallback.text.contains("No changes made."))
        #expect(fallback.text.contains("(3 actions, 3 without an observed change)."))
        let embedded = HumanInterventionSummary.digest(
            review,
            actionVectors: [[1, 0], [1, 0], [1, 0]],
            effectVectors: [[1, 0]]
        )
        let text = expanded(embedded.text, using: embedded.strings)
        #expect(text == fallback.text)
        #expect(!text.contains("Saturated violet"))
        #expect(embedded.evidence.steps[2].action.windowNumber == 19)
    }

    private func noisyReview() async throws -> HumanInterventionConsumer.Intervention.Review {
        var initial = scene([], title: "Edit: Session")
        initial.elements = (0..<700).map { index in
            SceneElement(id: "readout-\(index)", kind: .control,
                label: ["Cursor value", "Main Counter", "Bars|Beats", "vol", "Output"][index % 5],
                bounds: .init(x: 0.1, y: Double(index % 100) / 100, width: 0.1, height: 0.01),
                role: index % 5 < 3 ? "AXStaticText" : "AXSlider", value: "0.0",
                container: "Edit: Session / Tracks / Audio channel / Inserts A-E / Sends A-E / Input output routing")
        }
        initial.elements += nativeScene(["Audio 1"]).elements
        initial.elements.append(.init(id: "colour", kind: .control, label: "Colour",
            bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXTextField", value: "Blue"))
        var findings: [HumanSceneFinding] = []
        var final = initial
        for index in 1...35 {
            let action = index == 1 ? payload(label: "Track", role: "AXMenuBarItem")
                : index == 2 ? payload(label: "New…", role: "AXMenuItem", window: 8, title: "New Tracks")
                : index == 3 ? payload(label: "Track Name", role: "AXTextField", window: 8, title: "New Tracks")
                : index == 4 ? payload(label: "Create", role: "AXButton", window: 8, title: "New Tracks")
                : index == 16 ? payload(.typing, label: "Name", role: "AXTextField")
                : index == 31 ? payload(label: "Vivid Violet", role: "AXButton")
                : index == 35 ? payload(.shortcut, command: "⌘S") : payload(.scroll)
            if index == 2 {
                var dialog = scene(["Create", "Cancel", "Number of new tracks", "Track Name"], title: "New Tracks")
                for item in dialog.elements.indices { dialog.elements[item].role = item < 2 ? "AXButton" : "AXTextField" }
                dialog.elements[2].value = "1"
                dialog.elements[3].value = "Audio 25"
                findings.append(try finding(2, action, scene: dialog))
            } else if [1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31, 35].contains(index) {
                for number in 0..<700 {
                    if number % 5 < 3 { final.elements[number].value = "\(index)| 4| 069" }
                    final.elements[number].bounds.x = Double(index) / 50
                }
                if index == 4 {
                    final.elements += nativeScene(["Audio 25"]).elements
                    final.elements.append(.init(id: "new", kind: .control, label: "Audio 25",
                        bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXRow", container: "tracks"))
                }
                if index >= 16 { final.elements.replaceSubrange(700..<703, with: nativeScene(["Draft 15"]).elements) }
                if index >= 31 { final.elements[703].value = "Vivid Violet" }
                for label in ["L¿", "SENAOEE", "0°0"] {
                    final.elements.append(.init(id: "ocr-\(index)-\(label)", kind: .text, label: label,
                        bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1)))
                }
                findings.append(try finding(UInt64(index), action, scene: final, kind: .changes, readWindow: 7))
            } else {
                findings.append(try finding(UInt64(index), action, kind: .covered))
            }
        }
        return try await review(findings, final: [7: final], initial: [7: initial])
    }

    #if DEBUG
    @Test func replayRoundTripsWithoutPicturesOrTypedValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let review = try await noisyReview()
        try await HumanInterventionReplay.write(review, to: directory)
        let replay = try await HumanInterventionReplay.replay(directory)
        #expect(replay.text == HumanInterventionSummary.digest(review).text)
        #expect(replay.evidence.steps.map(\.sequences) == HumanInterventionEvidence(review).steps.map(\.sequences))
        let manifest = try String(contentsOf: directory.appendingPathComponent("review.json"), encoding: .utf8)
        #expect(manifest.contains("actions") && !manifest.contains("picture") && !manifest.contains("never read this"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 37)
    }

    @Test func replayExcludesRetainedPixelsAndSecureValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = HumanPreviewControl.RetainedPicture(heic: Data("private picture bytes".utf8),
            pixelSize: .init(width: 800, height: 600), encodedSize: .init(width: 800, height: 600))
        let action = payload(.typing, label: "Private entry", role: "AXSecureTextField", picture: picture)
        var protected = scene(["Entry"])
        protected.elements[0].role = "AXSecureTextField"
        protected.elements[0].value = "private credential"
        let minimized = HumanInterventionConsumer.minimized(protected)
        let review = try await review([finding(1, action, scene: minimized)], final: [7: minimized], payloads: [action])
        #expect(review.payloads[0].picture != nil)
        try await HumanInterventionReplay.write(review, to: directory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("finding-0.lzfse"))
        let decoded = try (bytes as NSData).decompressed(using: .lzfse) as Data
        let stored = try JSONDecoder().decode(HumanSceneFinding.self, from: decoded)
        #expect(!String(decoding: decoded, as: UTF8.self).contains("picture"))
        #expect(stored.recordedAction?.label == nil)
        #expect(!(try stored.text()).contains("private credential"))
        #expect(try stored.sceneEvidence().scenes[7]?.elements[0].value == "[withheld]")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAUS_HANDOFF_REPLAY"] != nil,
                   "Set BRAUS_HANDOFF_REPLAY to a captured handoff folder"))
    func replaySavedHandoff() async throws {
        guard let path = ProcessInfo.processInfo.environment["BRAUS_HANDOFF_REPLAY"] else { return }
        let digest = try await HumanInterventionReplay.replay(URL(fileURLWithPath: path))
        print("REPLAY_BEGIN\n\(digest.text)\nREPLAY_END")
        #expect(digest.text.utf8.count <= 1000)
    }
    #endif







    @Test func unnamedTextAreaHasAUsefulActionDescription() {
        let description = HumanInterventionSummary.action(payload(.typing, label: nil, role: "AXTextArea"))
        #expect(description == "typed in text area")
    }















    private func namedContainerScene(_ name: String) -> SceneSnapshot {
        var result = scene(["Name \"\(name)\"", "Mute", "Solo"])
        for index in result.elements.indices {
            result.elements[index].container = name
            result.elements[index].role = index == 0 ? "AXPopUpButton" : "AXButton"
        }
        result.elements[0].id = name
        result.elements[0].value = name
        return result
    }

    private func listScene(_ labels: [String]) -> SceneSnapshot {
        var result = scene(labels)
        for index in result.elements.indices {
            result.elements[index].id = labels[index]
            result.elements[index].role = "AXRow"
            result.elements[index].container = "Items"
        }
        return result
    }




    private struct FixtureEmbedding: TextEmbedding {
        let space = EmbeddingSpace(
            modelID: "fixture", modelRevision: "1", weightsDigest: "fixture", tokenizerDigest: "fixture",
            dimensions: 3, pooling: "mean", queryPrefix: "", documentPrefix: "", maximumTokens: 128
        )

        func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
            texts.map { text in
                let words = text.lowercased()
                let vector: [Float] = words.contains("colour") || words.contains("violet") ? [1, 0, 0]
                    : words.contains("name") || words.contains("typed") ? [0, 1, 0] : [0, 0, 1]
                return EmbeddedText(vector: vector, tokenCount: 1, isTruncated: false)
            }
        }
    }

    private actor TrialReader: HumanSceneReading {
        let window: InteractionWindow
        let scenes: [SceneSnapshot]
        let finalSurfaces: [InteractionWindow]?
        var index = 0

        init(window: InteractionWindow, scenes: [SceneSnapshot], finalSurfaces: [InteractionWindow]? = nil) {
            self.window = window
            self.scenes = scenes
            self.finalSurfaces = finalSurfaces
        }

        func windows(processID: Int32) async throws -> [InteractionWindow] { [window] }

        func finalWindows(processID: Int32) async throws -> [InteractionWindow] { finalSurfaces ?? [window] }

        func scene(window: InteractionWindow, mode: ProductionPerception.Mode,
                   timing: NativeHumanSceneReader.Timing) async throws -> SceneSnapshot {
            let scene = scenes[min(index, scenes.count - 1)]
            index += 1
            return scene
        }
    }

    private func payload(
        _ kind: InteractionEvent.Kind = .click,
        label: String? = "Name",
        role: String = "AXTextField",
        window: Int = 7,
        title: String = "New Tracks",
        command: String? = nil,
        clicks: UInt32 = 1,
        picture: HumanPreviewControl.RetainedPicture? = nil
    ) -> HumanRecordedInteraction {
        let element = InteractionElementMetadata.read(isReservedLabel: ValueMinimization.namesSecret) {
            ["AXRole": role, "AXTitle": label, "AXValue": "never read this"][$0] ?? nil
        }
        let event = InteractionEvent(
            kind: kind,
            timestamp: Date(),
            startedAt: 1,
            endedAt: 2,
            precedingRevision: 0,
            revision: 1,
            point: .zero,
            window: .init(processID: 42, number: window, title: title, layer: 0,
                          frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            processID: 42,
            sequence: 1,
            clickCount: clicks
        )
        return HumanRecordedInteraction(event: event, element: element, endElement: nil,
                                        commandName: command, picture: picture)
    }

    private func scene(_ labels: [String], title: String = "Mix") -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "test",
            appName: "Mixer",
            windowTitle: title,
            viewportPixelSize: .init(width: 800, height: 600),
            elements: labels.enumerated().map { index, label in
                .init(id: "track-\(index)", kind: .control, label: label,
                      bounds: .init(x: 0.1, y: Double(index) / 100, width: 0.7, height: 0.01))
            }
        )
    }

    private func nativeScene(_ labels: [String], title: String = "Mix") -> SceneSnapshot {
        var result = scene([], title: title)
        result.elements = labels.enumerated().flatMap { index, label in
            namedContainerScene(label).elements.map { item in
                var item = item
                if item.value == nil { item.id = "anchor-\(index)-" + item.label }
                item.bounds.y += Double(index) / 10
                return item
            }
        }
        return result
    }

    private func finding(
        _ sequence: UInt64,
        _ payload: HumanRecordedInteraction,
        scene: SceneSnapshot? = nil,
        kind: HumanSceneFinding.Kind = .keyframe,
        readWindow: Int? = nil
    ) throws -> HumanSceneFinding {
        var result = try HumanSceneFinding(
            sequence: sequence,
            kind: kind,
            text: scene?.text() ?? "",
            readMilliseconds: 1,
            windowNumber: payload.window?.number,
            scenes: scene.map { [readWindow ?? payload.window?.number ?? 7: $0] } ?? [:]
        )
        result.recordedAction = payload.summaryAction
        return result
    }

    private func review(
        _ findings: [HumanSceneFinding],
        final: [Int: SceneSnapshot] = [:],
        initial: [Int: SceneSnapshot] = [:],
        closed: [Int] = [],
        reason: HumanSceneFinding.Reason? = nil,
        payloads: [HumanRecordedInteraction] = []
    ) async throws -> HumanInterventionConsumer.Intervention.Review {
        let episode = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 4096, maximumRetainedBytes: 10_000_000)
        for (index, finding) in findings.enumerated() {
            let recorded = payloads.indices.contains(index) ? payloads[index] : payload()
            _ = try await episode.record(recorded, retainedBytes: recorded.retainedBytes)
            let item = try #require(await episode.next())
            try await episode.complete(item, with: finding, retainedBytes: finding.compressedBytes)
        }
        return try await episode.beginReview(episode.endInput(), finalState: HumanSceneFinding(
            sequence: 0, kind: reason == nil ? .keyframe : .failed, text: "", readMilliseconds: 1,
            reason: reason, scenes: final, initialScenes: initial, closedWindowNumbers: closed))
    }



    @Test func mergesClickRunsAndFieldTypingWithReturn() async throws {
        let unchanged = scene(["Existing"])
        let actions = [payload(), payload(clicks: 2), payload(.typing), payload(.typing),
                       payload(.shortcut, command: "Return"), payload(.shortcut, command: "⌘S")]
        let findings = try actions.enumerated().map {
            try finding(UInt64($0.offset + 1), $0.element, scene: unchanged)
        }
        let digest = HumanInterventionSummary.digest(try await review(findings, final: [7: unchanged]))
        #expect(digest.evidence.steps.map(\.text) == ["typed in Name (New Tracks)", "⌘S"])
        #expect(digest.evidence.steps.first?.sequences == [1, 2, 3, 4, 5])
        #expect(!digest.text.contains("start:") && !digest.text.contains("end:"))
    }

    @Test func sameLabelsInDifferentWindowsDoNotMerge() async throws {
        let unchanged = scene([])
        let digest = HumanInterventionSummary.digest(try await review([
            finding(1, payload(), scene: unchanged),
            finding(2, payload(window: 19), scene: unchanged),
            finding(3, payload(clicks: 2), scene: unchanged),
            finding(4, payload(clicks: 2), scene: unchanged)
        ], final: [7: unchanged, 19: unchanged]))
        #expect(digest.evidence.steps.map(\.sequences) == [[1], [2], [3, 4]])
        #expect(digest.evidence.steps.map { $0.action.windowNumber } == [7, 19, 7])
    }

    @Test func dropsNoiseAndUnknownClicksWithoutChanges() async throws {
        let unchanged = scene([])
        let actions = [payload(.scroll), payload(.hover), payload(.focus), payload(label: nil)]
        let findings = try actions.enumerated().map {
            try finding(UInt64($0.offset + 1), $0.element, scene: unchanged)
        }
        let text = HumanInterventionSummary.build(try await review(findings, final: [7: unchanged]))
        #expect(text == "No changes made.\nDetails: human_step step 1 (4 actions, 4 without an observed change).")
    }

    @Test func unknownClickDoesNotProveCreation() async throws {
        let digest = HumanInterventionSummary.digest(try await review([
            finding(1, payload(label: nil), scene: scene(["Added"]), kind: .changes)
        ], final: [7: scene(["Added"])], initial: [7: scene([])]))
        let text = expanded(digest.text, using: digest.strings)
        #expect(!text.contains("click unknown target"))
        #expect(!text.contains("+ Added"))
    }

    @Test(arguments: [HumanSceneFinding.Kind.unchanged, .changes])
    func unknownClicksUseTheirCoveringRead(kind: HumanSceneFinding.Kind) async throws {
        let initial = scene([])
        let final = kind == .changes ? scene(["Added"]) : initial
        var covered = try finding(1, payload(label: nil), kind: .covered)
        covered.coveredBySequence = 2
        let text = HumanInterventionSummary.build(try await review([
            covered,
            finding(2, payload(.shortcut, command: "⌘S"), scene: final, kind: kind)
        ], final: [7: final], initial: [7: initial]))
        #expect(!text.contains("click unknown target") && text.contains("Unobserved: ⌘S."))
    }

    @Test func temporaryCreationAndRemovalStayInDetailsOnly() async throws {
        let initial = scene([])
        // A native element: pixel text carries no identity, so it would leave no step effect at all.
        var created = scene(["Temporary track"])
        created.elements[0].role = "AXStaticText"
        let digest = HumanInterventionSummary.digest(try await review([
            finding(1, payload(label: "Create", role: "AXButton"), scene: created, kind: .changes),
            finding(2, payload(label: "Delete", role: "AXButton"), scene: initial, kind: .changes)
        ], final: [7: initial], initial: [7: initial]))
        let text = expanded(digest.text, using: digest.strings)
        #expect(!text.contains("Temporary track"))
        #expect(digest.evidence.steps[0].effects.contains { $0.text == "+ Temporary track" })
        #expect(digest.evidence.steps[1].effects.contains { $0.text == "− Temporary track" })
        #expect(text.contains("No changes made."))
    }

    @Test func unidentifiedTransientPresenceDoesNotBecomeDomainCreation() async throws {
        let initial = scene([])
        var temporary = scene(["Temporary track"])
        temporary.elements[0].id = "temporary"
        temporary.elements[0].role = "AXStaticText"
        var final = scene(["Permanent track"])
        final.elements[0].id = "permanent"
        final.elements[0].role = "AXStaticText"
        let digest = HumanInterventionSummary.digest(try await review([
            finding(1, payload(label: "Create", role: "AXButton"), scene: temporary, kind: .changes),
            finding(2, payload(label: "Delete", role: "AXButton"), scene: initial, kind: .changes),
            finding(3, payload(label: "Create", role: "AXButton"), scene: final, kind: .changes)
        ], final: [7: final], initial: [7: initial]))
        let text = expanded(digest.text, using: digest.strings)
        #expect(!text.contains("+ Permanent track"))
        #expect(!text.contains("Temporary track"))
        #expect(digest.evidence.steps[0].effects.contains { $0.text == "+ Temporary track" })
        #expect(digest.evidence.steps[1].effects.contains { $0.text == "− Temporary track" })
    }

    @Test func allStepsRemainAvailableWithoutAnInlineActionList() async throws {
        let initial = scene([])
        let findings = try (1...20).map {
            try finding(UInt64($0), payload(.shortcut, command: "F\($0)"), scene: initial)
        }
        let digest = HumanInterventionSummary.digest(try await review(findings, final: [7: scene(["Added"])]))
        #expect(digest.evidence.steps.count == 20)
        #expect(digest.evidence.steps.first?.text == "F1")
        #expect(digest.evidence.steps.last?.text == "F20")
        #expect(digest.evidence.threads.actions.count == 20)
        #expect(digest.text == "No changes made.\nDetails: human_step steps 1-20 (20 actions, 20 without an observed change).")
    }

    @Test func byteLimitKeepsWholeDifferenceLinesAndLazyStepCount() async throws {
        let initial = scene([])
        let final = scene((1...40).map { "Track \($0) " + String(repeating: "🎹", count: 12) })
        let findings = try (1...20).map {
            try finding(UInt64($0), payload(.shortcut, command: "F\($0)"), scene: $0 == 20 ? final : initial)
        }
        let text = HumanInterventionSummary.build(try await review(findings, final: [7: final]))
        #expect(text.utf8.count <= 1000)
        #expect(text == "No changes made.\nDetails: human_step steps 1-20 (20 actions, 20 without an observed change).")
        #expect(!text.contains("\nF20") && !text.contains("�"))
        let complete = Set(final.elements.map { "+ " + $0.label })
        for line in text.split(separator: "\n") where line.hasPrefix("+ ") {
            #expect(complete.contains(String(line)))
        }
    }

    @Test func hugeSingleLinesAreOmittedWithoutPartialUnicode() async throws {
        let huge = String(repeating: "🎛", count: 2000)
        let text = HumanInterventionSummary.build(try await review([
            finding(1, payload(label: huge), scene: scene([huge]))
        ], final: [7: scene([huge])], initial: [7: scene([])]), note: huge)
        #expect(text.utf8.count <= 1000)
        #expect(!text.contains("🎛") && !text.contains("�"))
        #expect(text.contains("(1 action, 1 without an observed change)."))
        #expect(!text.contains("start:") && !text.contains("end:"))
    }

    @Test func protectedMetadataAndSceneValuesNeverAppear() async throws {
        let secure = payload(.typing, label: "private label", role: "AXSecureTextField", title: "private title")
        var initial = scene(["Password", "Unchanged"])
        initial.elements[0].value = "private value"
        var final = initial
        final.elements[0].value = "new private value"
        final.elements.append(.init(id: "echo", kind: .text, label: "new private value",
                                   bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1)))
        let text = HumanInterventionSummary.build(try await review([
            finding(1, secure, scene: initial)
        ], final: [7: final]))
        #expect(!text.contains("private label"))
        for secret in ["private label", "private title", "private value", "never read this"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func knownSecretsAreWithheldAcrossDifferencesActionsTitlesAndNotes() async throws {
        let secret = "private phrase"
        let minimization = ValueMinimization(secrets: [secret])
        let text = HumanInterventionSummary.build(try await review([
            finding(1, payload(label: secret, title: secret), scene: scene([]))
        ], final: [7: scene([secret], title: secret)]), note: secret,
            withholding: { minimization.minimize(text: $0).0 })
        #expect(!text.contains(secret))
        #expect(text.contains("[withheld]"))
        #expect(text.utf8.count <= 1000)
    }

    @Test func failedObservableCommitIsOmittedWithoutBlanketWarning() async throws {
        let text = HumanInterventionSummary.build(try await review([
            finding(1, payload(label: "Create", role: "AXButton"), kind: .superseded)
        ], reason: .read))
        #expect(!text.contains("surface unavailable"))
        #expect(text.contains("(1 action, 1 without an observed change)."))
        #expect(text.contains("No changes made."))
        #expect(!text.contains("Read #"))
    }

    @Test func missingStartingSceneCannotEstablishCreation() async throws {
        let text = HumanInterventionSummary.build(try await review([
            finding(1, payload(label: "Create", role: "AXButton"), kind: .failed)
        ], final: [7: scene(["New track"])]))
        #expect(text.contains("(1 action, 1 without an observed change)."))
        #expect(text.contains("No changes made."))
    }

    @Test func onlyInventoryConfirmedClosedWindowsAreReported() async throws {
        let baseline = scene(["Existing"], title: "Document")
        let finding = try finding(1, payload(), scene: baseline)
        let closed = HumanInterventionSummary.build(try await review([finding], closed: [7]))
        let failed = HumanInterventionSummary.build(try await review([finding], reason: .read))
        #expect(closed.contains("No changes made."))
        #expect(!failed.contains("Closed:"))
    }

    @Test func returnAfterTheMergedTypingStepIsStillRecorded() async throws {
        let initial = scene([])
        let actions = [payload(), payload(.typing), payload(.shortcut, command: "Return"),
                       payload(.shortcut, command: "Return")]
        let findings = try actions.enumerated().map {
            try finding(UInt64($0.offset + 1), $0.element, scene: initial)
        }
        let digest = HumanInterventionSummary.digest(try await review(findings, final: [7: initial]))
        #expect(digest.evidence.steps.map(\.text) == ["typed in Name (New Tracks)", "Return"])
        #expect(digest.evidence.steps.map(\.sequences) == [[1, 2, 3], [4]])
    }

    @Test func renamedWindowIsReportedWithoutDumpingItsScene() async throws {
        let text = HumanInterventionSummary.build(try await review([
            finding(1, payload(.shortcut, command: "⌘S"), scene: scene(["Unchanged"], title: "Untitled"))
        ], final: [7: scene(["Unchanged"], title: "Session")]))
        // The save is the only command before the title changed: it named the document, so it is that change's cause.
        #expect(text.contains("\nWindow title: Untitled → Session.") && !text.contains("Unobserved"))
        #expect(!text.contains("Unchanged"))
    }

    @Test func actionNamesDoNotReadTypedValues() {
        #expect(HumanInterventionSummary.action(payload(.typing)) == "typed in Name")
        #expect(HumanInterventionSummary.action(payload(.shortcut, command: "⌘S")) == "⌘S")
        #expect(HumanInterventionSummary.action(payload(.typing, label: "private", role: "AXSecureTextField"))
            == "typed in a protected field")
    }



    @Test func plainDetailProseIsNotImplicitlyInterned() {
        let strings = HumanInterventionStrings(tokens: [[.operand("A sufficiently long operand")], [.operand("A sufficiently long operand")]])
        #expect(strings.value("§1") == "A sufficiently long operand")
        #expect(strings.reference("open A sufficiently long operand") == "open A sufficiently long operand")
        #expect(strings.render(["literal §1"]) == "literal §1")
    }



    private func expanded(_ text: String, using strings: HumanInterventionStrings) -> String {
        var text = text
        for (index, value) in strings.entries.enumerated().reversed() {
            text = text.replacingOccurrences(of: "§\(index + 1)", with: value)
        }
        return text
    }


    @Test func emptyEpisodeIsOneLine() async throws {
        let text = HumanInterventionSummary.build(try await review([], final: [7: scene(["Existing"])]))
        #expect(text == "No changes made.")
    }
}
