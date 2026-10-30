//
//  HumanInterventionEmbeddingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import Memory
import InteractionListener
import InteractionObservation
@testable import SeatBroker
import Synchronization
import Testing

@Suite
struct HumanInterventionEmbeddingTests {

    nonisolated private final class Stub: TextEmbedding {

        struct Call: Sendable {
            let text: String
            let role: EmbeddingRole
            let isMainThread: Bool
        }

        let calls = Mutex<[Call]>([])
        let delay: TimeInterval
        let invalid: Bool

        init(delay: TimeInterval = 0, invalid: Bool = false) {
            self.delay = delay
            self.invalid = invalid
        }

        let space = EmbeddingSpace(
            modelID: "fixture",
            modelRevision: "1",
            weightsDigest: "fixture",
            tokenizerDigest: "fixture",
            dimensions: 2,
            pooling: "mean",
            queryPrefix: "query: ",
            documentPrefix: "document: ",
            maximumTokens: 128
        )

        func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
            texts.map { text in
                calls.withLock {
                    $0.append(Call(text: text, role: role, isMainThread: Thread.isMainThread))
                }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                let vector: [Float] = invalid ? [.nan, 0] : text.contains("colour") ? [1, 0] : [0, 1]
                return EmbeddedText(vector: vector, tokenCount: 1, isTruncated: false)
            }
        }
    }

    @Test
    func returnContextsProduceDistinctStubVectors() async {
        func action(_ label: String, _ window: String) -> HumanRecordedInteraction.SummaryAction {
            var state = InteractionSemanticSnapshot(processID: 42, interval: .init(start: 11.01, end: 11.03))
            state.focused = .value(0)
            state.elements = [.init(id: 0, window: 7, role: "AXTextField", label: label)]
            state.windowTitles = [7: window]
            var before = state
            before.interval = .init(start: 9, end: 9.03)
            return .init(kind: .shortcut, processID: 42, windowNumber: 7, windowTitle: window,
                  role: "AXTextField", label: label, isProtected: false, destination: nil,
                  commandName: "Return", lostCritical: 0,
                  provenance: .init(interval: .init(start: 10, end: 11), sourceSequence: 1, targetInferred: false, stateAtAction: true, semantics: state, beforeSemantics: before))
        }
        let create = HumanInterventionThreads(actions: [action("Name", "New Items")], sequences: [1], scenes: [:])
        let colour = HumanInterventionThreads(actions: [action("colour", "Appearance")], sequences: [1], scenes: [:])
        let texts = [create.roots[0].embeddingText, colour.roots[0].embeddingText]
        #expect(texts[0].contains("Return in text field 'Name' (New Items)"))
        #expect(texts[1].contains("Return in text field 'colour' (Appearance)"))
        let result = await HumanInterventionEmbeddings { Stub() }.vectors(actions: texts, effects: ["context"])
        #expect(result.mode == "embedding")
        #expect(result.actionVectors == [[0, 1], [1, 0]])
    }

    @Test
    func rolesAndRepeatedTextsAreCachedOffMainThread() async {
        let stub = Stub()
        let loads = Mutex<[Bool]>([])
        let embeddings = HumanInterventionEmbeddings {
            loads.withLock { $0.append(Thread.isMainThread) }
            return stub
        }
        let actions = ["colour palette", "Track menu", "colour palette"]
        let effects = ["colour changed", "track added"]
        let first = await embeddings.vectors(actions: actions, effects: effects)
        let second = await embeddings.vectors(actions: actions, effects: effects)

        #expect(first.mode == "embedding")
        #expect(first.actionVectors == [[1, 0], [0, 1], [1, 0]])
        #expect(first.effectVectors == [[1, 0], [0, 1]])
        #expect(second.elapsedMilliseconds == first.elapsedMilliseconds)
        #expect(loads.withLock { $0 } == [false])
        let calls = stub.calls.withLock { $0 }
        #expect(calls.map(\.role) == [.document, .document, .query, .query])
        #expect(calls.allSatisfy { !$0.isMainThread })
        #expect(first.elapsedMilliseconds < 150)
        print("human digest embedding stub: \(first.elapsedMilliseconds) ms")
    }

    @Test
    func missingModelFallbackIsCached() async {
        let loads = Mutex(0)
        let embeddings = HumanInterventionEmbeddings {
            loads.withLock { $0 += 1 }
            return nil
        }
        let first = await embeddings.vectors(actions: ["Track"], effects: ["new track"])
        let second = await embeddings.vectors(actions: ["Track"], effects: ["new track"])

        #expect(first.mode == "deterministic")
        #expect(first.actionVectors.isEmpty && first.effectVectors.isEmpty)
        #expect(second.elapsedMilliseconds == first.elapsedMilliseconds)
        #expect(loads.withLock { $0 } == 1)
    }

    @Test
    func deadlineDoesNotWaitForSynchronousInference() async throws {
        let stub = Stub(delay: 0.25)
        let embeddings = HumanInterventionEmbeddings { stub }
        let start = ContinuousClock.now
        let result = await embeddings.vectors(
            actions: ["colour palette", "Track menu"],
            effects: ["colour changed"],
            timeout: .milliseconds(20)
        )
        let elapsed = start.duration(to: .now)

        #expect(result.mode == "deterministic")
        #expect(elapsed < .milliseconds(150))
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.calls.withLock { $0.count } == 1)
        let cached = await embeddings.vectors(
            actions: ["colour palette", "Track menu"],
            effects: ["colour changed"]
        )
        #expect(cached.mode == "deterministic")
        #expect(cached.elapsedMilliseconds == result.elapsedMilliseconds)
        print("human digest embedding timeout: \(result.elapsedMilliseconds) ms")
    }

    @Test
    func concurrentRequestsShareOneJobAndChangedInputsDoNotStartAnother() async {
        let stub = Stub(delay: 0.005)
        let embeddings = HumanInterventionEmbeddings { stub }
        async let first = embeddings.vectors(actions: ["Track menu"], effects: ["track added"])
        async let second = embeddings.vectors(actions: ["Track menu"], effects: ["track added"])
        let results = await [first, second]

        #expect(results.allSatisfy { $0.mode == "embedding" })
        #expect(stub.calls.withLock { $0.count } == 2)
        let changed = await embeddings.vectors(actions: ["another action"], effects: ["another effect"])
        #expect(changed.mode == "deterministic")
        #expect(stub.calls.withLock { $0.count } == 2)
    }

    @Test
    func oversizedInputAndZeroBudgetNeverLoadTheModel() async {
        let loads = Mutex(0)
        let embeddings = HumanInterventionEmbeddings {
            loads.withLock { $0 += 1 }
            return Stub()
        }
        let many = await embeddings.vectors(actions: Array(repeating: "Track", count: 97), effects: ["added"])
        let long = await embeddings.vectors(actions: [String(repeating: "x", count: 1_025)], effects: ["added"])
        let zero = await embeddings.vectors(actions: ["Track"], effects: ["added"], timeout: .zero)

        #expect([many, long, zero].allSatisfy { $0.mode == "deterministic" })
        #expect(loads.withLock { $0 } == 0)
    }

    @Test
    func invalidVectorsLeaveNoPartialEmbeddingResult() async {
        let embeddings = HumanInterventionEmbeddings { Stub(invalid: true) }
        let result = await embeddings.vectors(actions: ["Track"], effects: ["added"])

        #expect(result.mode == "deterministic")
        #expect(result.actionVectors.isEmpty && result.effectVectors.isEmpty)
    }

    @Test
    func lateModelLoadIsSharedWithLaterEpisodesWithoutOverlappingLoads() async throws {
        let loads = Mutex(0)
        let stub = Stub()
        let model = HumanInterventionEmbeddings.ModelCache {
            loads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.1)
            return stub
        }
        let cold = HumanInterventionEmbeddings { await model.model() }
        let first = await cold.vectors(
            actions: ["Track"],
            effects: ["track added"],
            timeout: .milliseconds(10)
        )
        #expect(first.mode == "deterministic" && first.reason == "deadline")

        let overlapping = HumanInterventionEmbeddings { await model.model() }
        let second = await overlapping.vectors(actions: ["Track"], effects: ["track added"])
        #expect(second.mode == "embedding")
        #expect(loads.withLock { $0 } == 1)
    }

    @Test
    func preparedModelIsReadyBeforeTheEpisodeNeedsIt() async throws {
        let loads = Mutex(0)
        let model = HumanInterventionEmbeddings.ModelCache {
            loads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.1)
            return Stub()
        }
        model.prepare()
        _ = await model.model()
        let warm = HumanInterventionEmbeddings { await model.model() }
        let result = await warm.vectors(actions: ["Track"], effects: ["track added"], timeout: .milliseconds(50))
        #expect(result.mode == "embedding")
        #expect(loads.withLock { $0 } == 1)
    }

    @Test
    func installedModelReportsItsModeAndTiming() async throws {
        HumanInterventionEmbeddings.prepareLocal()
        try await Task.sleep(for: .seconds(3))
        let result = await HumanInterventionEmbeddings.local().vectors(
            actions: ["AXMenuBarItem Track Edit: Session", "Colour palette Vivid Violet Edit: Session"],
            effects: ["Audio 25 Stereo track added", "Draft 15 Colour Vivid Violet"]
        )
        #expect(["embedding", "deterministic"].contains(result.mode))
        #expect(result.elapsedMilliseconds < 200)
        print("human digest local model: \(result.mode), \(result.elapsedMilliseconds) ms, \(result.reason ?? "")")
    }
    @Test
    func vectorsReportTheModelTheyComeFrom() async {
        let result = await HumanInterventionEmbeddings { Stub() }.vectors(actions: ["Track"], effects: ["track added"])
        #expect(result.model == "fixture@1")
        #expect(HumanInterventionAttribution.floorModel == "ibm-granite/granite-embedding-107m-multilingual@d6cffd338414d6a1c1f5decfad5fec62eebc90d5")
    }

    /// The floor holds only for the model it was calibrated on: vectors from any other model rank nothing.
    @Test
    func anotherModelLeavesCausesUnranked() async throws {
        let archives = ReplayArchives.all
        for (_, url) in archives {
            let evidence = try await HumanInterventionReplay.replay(url).evidence
            guard evidence.attribution.links.contains(where: { $0.preferred.count > 1 }) else { continue }
            let vectors = Array(repeating: [Float](repeating: 1, count: 4),
                                count: evidence.attribution.commandTexts.count + evidence.attribution.effectTexts.count)
            let calibrated = HumanInterventionSummary.digest(evidence, actionVectors: vectors,
                                                             embeddingModel: HumanInterventionAttribution.floorModel)
            let other = HumanInterventionSummary.digest(evidence, actionVectors: vectors, embeddingModel: "fixture@1")
            let unnamed = HumanInterventionSummary.digest(evidence, actionVectors: vectors)
            #expect(calibrated.attribution.model == HumanInterventionAttribution.floorModel && calibrated.attribution.skipped == nil)
            #expect(calibrated.attribution.links.contains { $0.preferred.count > 1 && $0.cause != nil })
            for digest in [other, unnamed] {
                #expect(digest.attribution.model == nil && digest.attribution.skipped != nil)
                #expect(digest.attribution.links.allSatisfy { $0.confidence == .unranked && ($0.preferred.count == 1 || $0.cause == nil) })
                #expect(digest.text == calibrated.text)
            }
            return
        }
        #expect(archives.isEmpty, "no archive has an effect with several candidates")
    }
}
