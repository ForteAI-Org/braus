//
//  HumanInterventionDetailsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import AutomationRuntime
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import InteractionObservation
import Memory
import PerceptionCore
import SeatCore
import SeatDriving
import SeatSession
import TestScratch
import Testing
@testable import SeatBroker

@MainActor
@Suite
struct HumanInterventionDetailsTests {
    private typealias Intervention = HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>
    private struct TurnFailure: Error {}

    @Test func stepsAndWindowDifferencesUseTheDigestTable() async throws {
        let fixture = try await fixture(note: "Review Session editor.")
        let first = fixture.details.result(.steps(1...1))
        #expect(!first.isError)
        #expect(first.text.contains("1:") && !first.text.contains("2:"))
        let range = fixture.details.result(.steps(1...2))
        #expect(range.text.contains("1:") && range.text.contains("2:"))
        #expect(range.text.utf8.count <= 2048)
        let byNumber = fixture.details.result(.diff("7"))
        #expect(!byNumber.isError)
        let byAlias = fixture.details.result(.diff("Session editor"))
        #expect(!byAlias.isError && byNumber.text == byAlias.text)
        #expect(byNumber.text.contains("Vivid Violet"))
        for (index, value) in fixture.digest.strings.entries.enumerated() {
            if range.text.contains("§\(index + 1)") {
                #expect(range.text.contains("§\(index + 1)=\(String(reflecting: value))"))
            }
        }
        await fixture.details.finish()
    }

    @Test func threadDetailsSayWhatEachCommandCaused() async throws {
        let fixture = try await fixture()
        let result = fixture.details.result(.steps(1...2))
        #expect(result.text.contains("Thread T1: ") && result.text.contains("Actions: "))
        #expect(result.text.components(separatedBy: "Thread T1:").count == 2)
        #expect(result.text.utf8.count <= 2048)
        await fixture.details.finish()
    }

    @Test func detailsExposeIntervalsAndDistinctSelectionAnswers() async throws {
        var state = InteractionSemanticSnapshot(processID: 42, interval: .init(start: 2.01, end: 2.03))
        state.focused = .value(0)
        var field = InteractionSemanticSnapshot.Element(id: 0, window: 7, role: "AXTextField", label: "Name")
        field.selected = .value(false)
        field.selectedRows = .unsupported
        field.selectedChildren = .unread
        var protected = InteractionSemanticSnapshot.Element(id: 1)
        protected.isProtected = true
        protected.selected = .protected
        state.elements = [field, protected]
        let fixture = try await fixture(semanticState: state)
        let result = fixture.details.result(.steps(1...1))
        #expect(result.text.contains("monotonic: 1.000000…2.000000 s"))
        #expect(result.text.contains("capture 2.100000…2.200000 s; AX 2.200000…2.300000 s"))
        #expect(result.text.contains("selected false; rows unsupported; children unread"))
        #expect(result.text.contains("Selection: protected."))
        #expect(result.text.contains("recipient unattested"))
        #expect(result.text.utf8.count <= 2048)
        await fixture.details.finish()
    }

    @Test func invalidRequestsAreShortRefusals() async throws {
        let fixture = try await fixture()
        for request in [HumanStepRequest.steps(0...1), .steps(1...3), .diff("999"),
                        .diff("§999"), .diff("§\(Int.min)"), .picture(Int.min), .picture(0), .picture(3)] {
            let result = fixture.details.result(request)
            #expect(result.isError)
            #expect(result.picture == nil)
            #expect(result.text.utf8.count < 100)
        }
        await fixture.details.finish()
    }

    @Test func retainedPicturesDescribeUnverifiedPixelsWithoutDisclosingThem() async throws {
        let clean = try await fixture(picture: true)
        let picture = clean.details.result(.picture(2))
        #expect(picture.picture == nil)
        #expect(picture.text.contains("800×600") && picture.text.contains("privacy unverified"))
        #expect(picture.text.contains("HEIC"))
        await clean.details.finish()
        #expect(clean.details.result(.picture(2)).isError)

        let uncertain = try await fixture(picture: true, inputDuringRead: true)
        let withheld = uncertain.details.result(.picture(2))
        #expect(withheld.picture == nil)
        #expect(withheld.text.contains("withheld"))
        await uncertain.details.finish()

        let absent = try await fixture()
        #expect(absent.details.result(.picture(1)).text.contains("No retained picture."))
        await absent.details.finish()
    }

    @Test func protectedTargetsAndValuesNeverReachDetailsOrPictures() async throws {
        let fixture = try await fixture(picture: true, protected: true)
        for request in [HumanStepRequest.steps(1...2), .diff("7"), .picture(2)] {
            let result = fixture.details.result(request)
            #expect(!result.text.contains("private credential"))
            #expect(result.picture == nil)
        }
        #expect(fixture.details.result(.picture(2)).text.contains("withheld"))
        await fixture.details.finish()
    }

    @Test func finishingInvalidatesAllRequestsAndReleasesTheCore() async throws {
        let fixture = try await fixture()
        #expect(await fixture.intervention.status().retainedBytes > 0)
        await fixture.details.finish()
        await fixture.details.finish()
        for request in [HumanStepRequest.steps(1...1), .diff("7"), .picture(1)] {
            #expect(fixture.details.result(request).text == HumanStepResult.unavailable.text)
        }
        #expect(await fixture.intervention.status().retainedBytes == 0)
        #expect(await fixture.intervention.status().recordedCount == 0)
    }

    @Test func sessionExposesDetailsOnlyDuringTheResumedTurn() async throws {
        let session = session()
        #expect(await session.humanStep(.steps(1...1)).isError)
        let fixture = try await fixture()
        try await session.turn {
            #expect(await session.humanStep(.steps(1...1)).isError)
            await session.retainHumanDetails(fixture.details)
            #expect(!(await session.humanStep(.steps(1...1))).isError)
            #expect(await fixture.intervention.status().retainedBytes > 0)
        }
        #expect(await session.humanStep(.steps(1...1)).isError)
        #expect(await fixture.intervention.status().retainedBytes == 0)
        try await session.turn {
            #expect(await session.humanStep(.steps(1...1)).isError)
        }
        await session.close()
    }

    @Test func failedTurnAndReplacementReleaseRetainedReviews() async throws {
        let session = session()
        let first = try await fixture()
        let replacement = try await fixture()
        await #expect(throws: TurnFailure.self) {
            try await session.turn {
                await session.retainHumanDetails(first.details)
                await session.retainHumanDetails(replacement.details)
                #expect(first.details.result(.steps(1...1)).isError)
                #expect(await first.intervention.status().retainedBytes == 0)
                #expect(!(await session.humanStep(.steps(1...1))).isError)
                throw TurnFailure()
            }
        }
        #expect(await session.humanStep(.steps(1...1)).isError)
        #expect(await replacement.intervention.status().retainedBytes == 0)
        await session.close()
    }

    @Test func attachingOutsideATurnDiscardsTheReview() async throws {
        let session = session()
        let fixture = try await fixture()
        await session.retainHumanDetails(fixture.details)
        #expect(await session.humanStep(.steps(1...1)).isError)
        #expect(await fixture.intervention.status().retainedBytes == 0)
        await session.close()
    }

    @Test func closingDuringTheTurnImmediatelyReleasesDetails() async throws {
        let session = session()
        let fixture = try await fixture()
        try await session.turn {
            await session.retainHumanDetails(fixture.details)
            #expect(!(await session.humanStep(.steps(1...1))).isError)
            await session.close()
            #expect(await session.humanStep(.steps(1...1)).isError)
            #expect(await fixture.intervention.status().retainedBytes == 0)
        }
    }

    @Test(.enabled(
        if: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty,
        "Requires a GUI application process for the broker lease"
    ))
    func startingAnotherEpisodeRevokesThePreviousTurnsDetails() async throws {
        let processID = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = scene(value: "Level 0", protected: false)
        let session = BrokeredAutomationSession(
            broker: SeatBroker(),
            workerID: UUID(),
            knowledgeDirectory: Scratch.directory("braus-human-details"),
            allowsDestructive: false,
            resolving: { $0 == "Test" ? "test.process" : $0 },
            missingGrant: { nil },
            requestGrants: {},
            seating: { _, _, _ in
                (TargetApp(pid: processID, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                 SeatTarget())
            },
            perceiving: { _, _ in scene },
            readDialog: { _ in nil }
        )
        let fixture = try await fixture()
        do {
            try await session.turn {
                _ = try await session.open(application: "Test", window: nil)
                await session.retainHumanDetails(fixture.details)
                #expect(!(await session.humanStep(.steps(1...1))).isError)
                _ = try session.retainForHumanIntervention()
                #expect(await session.humanStep(.steps(1...1)).isError)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while await fixture.intervention.status().retainedBytes > 0, ContinuousClock.now < deadline {
                    await Task.yield()
                }
                #expect(await fixture.intervention.status().retainedBytes == 0)
                #expect(fixture.details.result(.steps(1...1)).isError)
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        #expect(!session.holdsComputer)
    }

    private func session() -> BrokeredAutomationSession {
        BrokeredAutomationSession(
            broker: SeatBroker(),
            workerID: UUID(),
            knowledgeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    private func fixture(
        picture: Bool = false,
        inputDuringRead: Bool = false,
        protected: Bool = false,
        note: String? = nil,
        semanticState: InteractionSemanticSnapshot? = nil
    ) async throws -> (
        intervention: Intervention,
        details: HumanInterventionDetails,
        digest: HumanInterventionSummary.Digest
    ) {
        let intervention = try Intervention(maximumEvents: 4, maximumRetainedBytes: 100_000)
        var initial = scene(value: "Level 0; Colour Blue", protected: protected)
        if !protected { initial.elements[0].label = "Original channel" }
        let first = scene(value: "Level -3; Colour Blue", protected: protected)
        let final = scene(value: "Level -3; Colour Vivid Violet", protected: protected)
        let other = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Meters",
                                  viewportPixelSize: .init(width: 800, height: 600), elements: [])
        for (index, scene) in [first, final].enumerated() {
            let payload = payload(sequence: UInt64(index + 1), label: index == 0 ? "Level" : "Vivid Violet",
                                  picture: picture, protected: protected)
            try await intervention.record(payload, retainedBytes: payload.retainedBytes)
            let item = try #require(await intervention.next())
            var finding = try HumanSceneFinding(sequence: UInt64(index + 1), kind: .keyframe,
                text: scene.text(), readMilliseconds: 1, windowNumber: 7, scenes: [7: scene])
            finding.recordedAction = payload.summaryAction
            if let semanticState {
                finding.recordedAction?.provenance = .init(interval: .init(start: 1, end: 2),
                    sourceSequence: UInt64(index + 1), targetInferred: false, semantics: semanticState)
                finding.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "textOnly",
                    capture: .init(start: 2.1, end: 2.2), accessibility: .init(start: 2.2, end: 2.3))])
            }
            finding.inputDuringRead = inputDuringRead
            try await intervention.complete(item, with: finding, retainedBytes: finding.compressedBytes)
        }
        let finalFinding = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "", readMilliseconds: 1,
            scenes: [7: final, 8: other], initialScenes: [7: initial, 8: other])
        let revision = try await intervention.endInput()
        let review = try await intervention.beginReview(revision, finalState: finalFinding,
                                                       retainedBytes: finalFinding.compressedBytes)
        let digest = HumanInterventionSummary.digest(review, note: note)
        try await intervention.resolve(revision, as: .resume)
        let details = HumanInterventionDetails(review: review, digest: digest, intervention: intervention,
                                               withholding: { $0 })
        return (intervention, details, digest)
    }

    private func scene(value: String, protected: Bool) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Session editor",
            viewportPixelSize: .init(width: 800, height: 600),
            elements: [.init(id: "channel", kind: .control,
                label: protected ? "Password" : "Primary channel",
                bounds: .init(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
                role: protected ? "AXSecureTextField" : "AXSlider",
                value: protected ? "private credential" : value)])
    }

    private func payload(sequence: UInt64, label: String, picture: Bool,
                         protected: Bool) -> HumanRecordedInteraction {
        let metadata = InteractionElementMetadata.read(isReservedLabel: ValueMinimization.namesSecret) {
            ["AXRole": protected ? "AXSecureTextField" : "AXButton",
             "AXTitle": protected ? "Password" : label][$0]
        }
        let event = InteractionEvent(kind: .click, timestamp: Date(), startedAt: 1, endedAt: 2,
            precedingRevision: 0, revision: sequence, point: .zero,
            window: .init(processID: 42, number: 7, title: "Session editor", layer: 0,
                          frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            processID: 42, sequence: sequence)
        let retained = picture ? HumanPreviewControl.RetainedPicture(heic: Data([0, 1, 2, 3]),
            pixelSize: CGSize(width: 800, height: 600), encodedSize: CGSize(width: 800, height: 600)) : nil
        return HumanRecordedInteraction(event: event, element: metadata, endElement: nil,
                                        commandName: nil, picture: retained)
    }
}
