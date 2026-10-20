//
//  BrainCoverageApplicationTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 19/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Observations with coverage through the stored path: each application is stored under its own
/// contract and algorithm versions, a partial capture records presence without moving the stored
/// clock, version 1 applications replay as they were decided, and the representations that saw
/// an anchor come from its stored evidence.
@Suite("Brain applications with coverage: own versions, presence without absence, replay, provenance")
struct BrainCoverageApplicationTests {

    private typealias A = BrainApplicationFixtures
    private typealias Coverage = BrainObservationCoverage

    private static let completeNative  = Coverage(completeness: .complete, surface: .window, representation: .native, spatialScope: .wholeSurface)
    private static let completeDesktop = Coverage(completeness: .complete, surface: .window, representation: .desktop, spatialScope: .wholeSurface)
    private static let partialNative   = Coverage(completeness: .partial, surface: .window, representation: .native)

    private func block(_ n: Int) throws -> Date { try BrainClock.canonical(A.t0.addingTimeInterval(Double(n) * UIBrain.observationBlock)) }

    /// Records the event and its sample, then applies an observation of them.
    @discardableResult
    private func observe(
        _ memory  : A.Memory,
        _ eventID : String,
        _ detections: [BrainDetection],
        window    : String? = nil,
        at date   : Date,
        coverage  : Coverage?
    ) async throws -> BrainApplicationResult {
        try await memory.event(eventID, kind: .observation)
        let sample = try await memory.sample(eventID)
        return try await memory.applications.apply(try .observe(
            detections: detections, window: window, bundleID: A.bundle, sample: sample, requestedAt: date, coverage: coverage
        ))
    }

    private func unlabeledColumn() -> [BrainDetection] {
        (0..<6).map { BrainDetection(kind: .control, label: "", bounds: NormalizedRect(x: 0.236, y: 0.18 + Double($0) * 0.036,
                                                                                       width: 0.03, height: 0.017)) }
    }

    @Test("each application is stored under its command's versions, reads back with its coverage, and is answered once")
    func ownVersions() async throws {
        let memory = try await A.open()
        try await observe(memory, "e1", A.controls(["Send", "Draft", "Discard"]), at: A.t0, coverage: nil)
        let covered = try await observe(memory, "e2", A.controls(["Send", "Draft", "Discard"]), at: try block(1),
                                        coverage: Self.partialNative)
        #expect(try await memory.texts("SELECT contract_version || '/' || algorithm_version FROM brain_applications ORDER BY application_id")
            == ["1/brain-updater-1", "3/brain-updater-3"])
        #expect(try await memory.texts("SELECT DISTINCT assessment_version FROM brain_evidence WHERE event_id = 'e2'") == ["brain-updater-3"])
        let key = BrainApplicationKey.observe(CaptureSampleKey(eventID: "e2", phase: .after))
        let stored = try #require(try await memory.applications.application(key))
        #expect(stored.contractVersion == 3 && stored.algorithmVersion == "brain-updater-3")
        #expect(stored.command.coverage == Self.partialNative)
        let again = try await memory.applications.apply(stored.command)
        #expect(again.receipt == .alreadyApplied && again.applicationID == covered.applicationID)

        let legacy = try BrainApplicationCommand(key: key, bundleID: A.bundle, requestedAtMS: stored.command.requestedAtMS,
                                                 input: stored.command.input)
        let error = await storeError { _ = try await memory.applications.apply(legacy) }
        guard case .identity(let conflict)? = error else {
            Issue.record("expected a conflict, got \(String(describing: error))")
            return
        }
        #expect(conflict.storedFingerprint.hasPrefix("v3/brain-updater-3/"))
        #expect(conflict.offeredFingerprint.hasPrefix("v1/brain-updater-1/"))
        await memory.store.close()
    }

    @Test("partial captures move neither the stored clock nor any retirement; complete ones still retire what they do not show")
    func partialKeepsStoredClock() async throws {
        let memory = try await A.open()
        try await observe(memory, "e0", A.controls(["Bounce", "Mix", "Edit"]), window: "bounce", at: A.t0, coverage: Self.completeNative)
        for i in 1...20 {
            let result = try await observe(memory, "p\(i)", A.controls(["Mix", "Edit", "Save"]), window: "bounce", at: try block(i),
                                           coverage: Self.partialNative)
            #expect(result.outcome == .observed(created: i == 1 ? 1 : 0, updated: i == 1 ? 2 : 3, skippedAmbiguous: 0))
        }
        #expect(try await memory.integers("SELECT ingest_epoch FROM brain_apps WHERE bundle_id = ?", [.text(A.bundle)]) == [1])
        #expect(try await memory.integers("SELECT epoch FROM brain_app_window_epochs") == [1])
        #expect(try await memory.count("SELECT count(*) FROM brain_anchors WHERE retired_at_ms IS NOT NULL") == 0)
        #expect(try await memory.integers("SELECT seen_count FROM brain_anchors WHERE label = 'Save'") == [20])

        for i in 21...32 {
            try await observe(memory, "c\(i)", A.controls(["Mix", "Edit", "Other"]), window: "bounce", at: try block(i),
                              coverage: Self.completeNative)
        }
        #expect(try await memory.integers("SELECT ingest_epoch FROM brain_apps WHERE bundle_id = ?", [.text(A.bundle)]) == [13])
        #expect(try await memory.texts("SELECT retirement_cause FROM brain_anchors WHERE label = 'Bounce'") == ["transient"])
        #expect(try await memory.count("SELECT count(*) FROM brain_anchors WHERE label = 'Save' AND retired_at_ms IS NULL") == 1)
        await memory.store.close()
    }

    @Test("stored applications replayed in order into another store rebuild the same brain: version 1 as decided, version 2 with its coverage")
    func replayIdentical() async throws {
        let source = try await A.open()
        typealias Step = (labels: [String], window: String?, coverage: Coverage?)
        let opening: [Step] = [
            (["Bounce", "Mix", "Edit"], "bounce", nil), (["Mix", "Edit", "Save"], "bounce", nil), (["Lone"], nil, nil),
            (["Mix", "Edit", "Save"], "bounce", Self.partialNative), (["Tracks", "Clips", "Save"], "edit", nil),
        ]
        let aging = [Step](repeating: (["Mix", "Edit", "Other"], "bounce", nil), count: 14)
        let closing: [Step] = [(["Mix", "Edit", "Save"], "bounce", Self.completeDesktop)]
        let plan = opening + aging + closing
        var keys: [BrainApplicationKey] = []
        // Each label keeps one place: anchors at one height would tie in a group's member order.
        let places = ["Bounce", "Mix", "Edit", "Save", "Lone", "Tracks", "Clips", "Other"]
        func placed(_ labels: [String]) -> [BrainDetection] {
            labels.map { label in
                BrainDetection(kind: .control, label: label, bounds: NormalizedRect(
                    x: 0.5, y: 0.1 + 0.05 * Double(places.firstIndex(of: label) ?? 0), width: 0.03, height: 0.017))
            }
        }
        for (i, step) in plan.enumerated() {
            try await observe(source, "s\(i)", placed(step.labels), window: step.window, at: try block(i), coverage: step.coverage)
            keys.append(.observe(CaptureSampleKey(eventID: "s\(i)", phase: .after)))
        }
        let replica = try await A.open()
        for key in keys {
            let stored = try #require(try await source.applications.application(key))
            try await replica.event(key.eventID, kind: .observation)
            _ = try await replica.sample(key.eventID)
            let result = try await replica.applications.apply(stored.command)
            #expect(result.receipt == .committed && result.outcome == stored.outcome)
        }
        let original = try #require(try await source.brain())
        #expect(try await replica.brain() == original)
        #expect(original.objects.contains { $0.label == "Bounce" } == false, "the version 1 scenes aged it as they always did")
        let versions = "SELECT contract_version || '/' || algorithm_version FROM brain_applications ORDER BY application_id"
        #expect(try await replica.texts(versions) == (try await source.texts(versions)))
        await source.store.close()
        await replica.store.close()
    }

    @Test("an anchor's provenance is the representations of its supporting observations; another representation binds it only exactly")
    func provenanceFromEvidence() async throws {
        let memory = try await A.open()
        let first = try await observe(memory, "n1", unlabeledColumn(), at: A.t0, coverage: Self.completeNative)
        #expect(first.outcome == .observed(created: 6, updated: 0, skippedAmbiguous: 0))
        let native = Set(try await memory.texts("SELECT anchor_id FROM brain_anchors"))
        func provenance(_ key: String) async throws -> Set<Coverage.Representation> {
            try await memory.store.write { try SQLiteBrainApplicationRows.provenance($0, anchorKey: key) }
        }
        for key in native { #expect(try await provenance(key) == [.native]) }

        let seat = try await observe(memory, "d1", unlabeledColumn(), at: try block(1), coverage: Self.completeDesktop)
        #expect(seat.outcome == .observed(created: 6, updated: 0, skippedAmbiguous: 0), "no positional claim across representations")
        let again = try await observe(memory, "n2", unlabeledColumn(), at: try block(2), coverage: Self.completeNative)
        #expect(again.outcome == .observed(created: 0, updated: 6, skippedAmbiguous: 0))
        let seatAgain = try await observe(memory, "d2", unlabeledColumn(), at: try block(3), coverage: Self.completeDesktop)
        #expect(seatAgain.outcome == .observed(created: 0, updated: 6, skippedAmbiguous: 0), "the Seat binds its own column")
        let desktop = Set(try await memory.texts("SELECT anchor_id FROM brain_anchors")).subtracting(native)
        #expect(desktop.count == 6)
        for key in desktop { #expect(try await provenance(key) == [.desktop]) }

        let labels = A.controls(["Send", "Draft", "Discard"])
        #expect(try await observe(memory, "n3", labels, at: try block(4), coverage: Self.completeNative).outcome
            == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(try await observe(memory, "d3", labels, at: try block(5), coverage: Self.completeDesktop).outcome
            == .observed(created: 0, updated: 3, skippedAmbiguous: 0), "the exact label and kind bind across representations")
        let send = try #require(try await memory.texts("SELECT anchor_id FROM brain_anchors WHERE label = 'Send'").first)
        #expect(try await provenance(send) == [.native, .desktop])

        try await observe(memory, "v1", unlabeledColumn(), at: try block(6), coverage: nil)
        let legacy = try #require(try await memory.applications.application(.observe(CaptureSampleKey(eventID: "v1", phase: .after))))
        #expect(legacy.outcome == .observed(created: 0, updated: 6, skippedAmbiguous: 0), "a version 1 observation matches as before")
        await memory.store.close()
    }
}
