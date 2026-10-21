//
//  BrainCoverageContractTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 19/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// Contract version 2 of the application contract: an observation carries its coverage as three
/// typed arguments, a command is stored under the version its content makes, and a version 1
/// application reads back exactly as it was stored, without coverage.
@Suite("The brain application contract, version 2: an observation's coverage")
struct BrainCoverageContractTests {

    private let t0 = Fixtures.t0
    private let sample = CaptureSampleKey(eventID: "e1", phase: .after)
    private let partialDesktop = BrainObservationCoverage(completeness: .partial, surface: .popupUnion, representation: .desktop)

    private func observe(_ labels: [String], coverage: BrainObservationCoverage?) throws -> BrainApplicationCommand {
        try .observe(
            detections : labels.enumerated().map { BrainDetection(kind: .control, label: $0.element, bounds: Fixtures.rect(0.5, 0.1 * Double($0.offset))) },
            window     : "inbox",
            bundleID   : "test.app",
            sample     : sample,
            requestedAt: t0,
            coverage   : coverage
        )
    }

    private func rebuild(_ command: BrainApplicationCommand, _ arguments: [BrainArgument], version: Int) throws -> BrainApplicationCommand {
        try BrainApplicationCommand(key: command.key, bundleID: command.bundleID, requestedAtMS: command.requestedAtMS,
                                    arguments: arguments, applicationID: 7, contractVersion: version)
    }

    private func refusal(_ malformation: BrainApplicationError.Malformation) -> BrainApplicationError {
        .malformedApplication(applicationID: 7, malformation: malformation)
    }

    @Test("a scene observed with coverage is a version 3 command; without it, version 1, as before")
    func versionsFollowContent() throws {
        let scene = SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Inbox",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let legacy = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: t0)
        let covered = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: t0, coverage: partialDesktop)
        let explicitNil = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: t0, coverage: nil)
        #expect(legacy.coverage == nil && legacy.contractVersion == 1)
        #expect(explicitNil.hasSameInput(as: legacy) && explicitNil.contractVersion == 1)
        #expect(covered.coverage == partialDesktop && covered.contractVersion == 3)
        #expect(!covered.hasSameInput(as: legacy), "the coverage is input: a retry with another coverage is a conflict")
        let named = try BrainApplicationCommand.setName("x", anchorKey: "k", in: "test.app", eventID: "e2", requestedAt: t0)
        #expect(named.contractVersion == 1)
        #expect(throws: BrainApplicationError.invalidCommand(.inputDoesNotMatchOperation)) {
            _ = try BrainApplicationCommand(key: named.key, bundleID: "test.app", requestedAtMS: 0, input: named.input,
                                            coverage: partialDesktop)
        }
        #expect(BrainApplicationContract.version == 3 && BrainApplicationContract.legacyVersion == 1)
        #expect(BrainApplicationContract.algorithmVersion == "brain-updater-1")
        #expect(BrainApplicationContract.coverageAlgorithmVersion == "brain-updater-3")
    }

    @Test("version 3 arguments carry the coverage after the window and rebuild the very command; version 1 ones rebuild without it")
    func roundTrip() throws {
        let covered = try observe(["Send", "Mute"], coverage: partialDesktop)
        #expect(covered.arguments.map(\.name).prefix(5)
            == ["detection_count", "window", "capture_completeness", "capture_surface", "representation"])
        #expect(covered.arguments.filter { ["capture_completeness", "capture_surface", "representation"].contains($0.name) }
            .map(\.value) == [.text("partial"), .text("popup_union"), .text("desktop")])
        let rebuilt = try rebuild(covered, covered.arguments, version: 3)
        #expect(rebuilt.hasSameInput(as: covered) && rebuilt.coverage == partialDesktop)

        let legacy = try observe(["Send", "Mute"], coverage: nil)
        #expect(!legacy.arguments.contains { $0.name == "representation" })
        let read = try BrainApplicationCommand(key: legacy.key, bundleID: legacy.bundleID, requestedAtMS: legacy.requestedAtMS,
                                               arguments: legacy.arguments, applicationID: 7)
        #expect(read.hasSameInput(as: legacy) && read.coverage == nil, "the default version is 1, every application before coverage")
        for completeness in CaptureQuality.Completeness.allCases {
            for surface in CaptureSurface.allCases {
                for representation in BrainObservationCoverage.Representation.allCases {
                    let coverage = BrainObservationCoverage(completeness: completeness, surface: surface, representation: representation)
                    let command = try observe(["A"], coverage: coverage)
                    #expect(try rebuild(command, command.arguments, version: 3).coverage == coverage)
                }
            }
        }
    }

    @Test("coverage outside its version, current version without coverage, unknown codes and unknown versions are refused")
    func refusals() throws {
        let covered = try observe(["Send"], coverage: partialDesktop)
        let legacy = try observe(["Send"], coverage: nil)
        #expect(throws: refusal(.forbiddenArgument("capture_completeness"))) { _ = try rebuild(covered, covered.arguments, version: 1) }
        #expect(throws: refusal(.missingArgument("capture_completeness"))) { _ = try rebuild(legacy, legacy.arguments, version: 3) }
        #expect(throws: refusal(.missingArgument("representation"))) {
            _ = try rebuild(covered, covered.arguments.filter { $0.name != "representation" }, version: 3)
        }
        #expect(throws: refusal(.unknownCode(argument: "representation", code: "braille"))) {
            _ = try rebuild(covered, covered.arguments.map {
                $0.name == "representation" ? BrainArgument(name: "representation", position: 0, value: .text("braille")) : $0
            }, version: 3)
        }
        #expect(throws: refusal(.unknownCode(argument: "capture_surface", code: "popupUnion"))) {
            _ = try rebuild(covered, covered.arguments.map {
                $0.name == "capture_surface" ? BrainArgument(name: "capture_surface", position: 0, value: .text("popupUnion")) : $0
            }, version: 3)
        }
        #expect(throws: refusal(.duplicateArgument("capture_surface", position: 0))) {
            _ = try rebuild(covered, covered.arguments + [BrainArgument(name: "capture_surface", position: 0, value: .text("window"))],
                            version: 3)
        }
        #expect(throws: BrainApplicationError.unsupportedContractVersion(4)) { _ = try rebuild(covered, covered.arguments, version: 4) }
        #expect(throws: BrainApplicationError.unsupportedContractVersion(0)) { _ = try rebuild(legacy, legacy.arguments, version: 0) }
        let named = try BrainApplicationCommand.setName("x", anchorKey: "k", in: "test.app", eventID: "e2", requestedAt: t0)
        #expect(throws: refusal(.contractVersion(stored: 3, arguments: 1))) { _ = try rebuild(named, named.arguments, version: 3) }
    }
    @Test("historical version 2 coverage keeps its original absence semantics and arguments")
    func historicalVersionTwo() throws {
        let current = try observe(["A", "B", "C"], coverage: BrainObservationCoverage(
            completeness: .complete, surface: .window, representation: .native))
        let historicalArguments = current.arguments.filter { $0.name != "spatial_coverage" }
        let historical = try rebuild(current, historicalArguments, version: 2)
        #expect(historical.contractVersion == 2)
        #expect(historical.coverage?.spatialScope == .legacyWindow)
        #expect(historical.coverage?.attestsAbsence == true)
        #expect(historical.arguments == historicalArguments)
        #expect(current.coverage?.attestsAbsence == false)
    }

}
