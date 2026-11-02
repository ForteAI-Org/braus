//
//  HumanInterventionInvariantTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

#if DEBUG
import Foundation
import PerceptionCore
import Testing
@testable import SeatBroker

/// HumanInterventionInvariantTests checks the report's invariants on every replay archive in BRAUS_REPLAY_DIR (see
/// ReplayArchives); without them nothing runs.
@Suite
struct HumanInterventionInvariantTests {
    private static let archives = ReplayArchives.names

    @Test(.enabled(if: !archives.isEmpty), arguments: archives)
    func invariants(_ name: String) async throws {
        let digest = try await HumanInterventionReplay.replay(try #require(ReplayArchives.url(name)))
        digest.checkInvariants(name)
        // 4. Attribution is conservative: without any cause the body states the same effects.
        var uncaused = digest.evidence
        uncaused.ledger.attribute(Array(repeating: [], count: uncaused.ledger.effects.count + uncaused.ledger.intermediate.count))
        #expect(HumanInterventionSummary.digest(uncaused).stated.sorted() == digest.stated.sorted(), "\(name)")
        // 6. Determinism: with the episode's embeddings the body is identical; only causes in details may change.
        let vectors = await HumanInterventionEmbeddings.local().vectors(actions: digest.evidence.embeddingActions,
                                                                        effects: digest.evidence.embeddingEffects)
        let embedded = HumanInterventionSummary.digest(digest.evidence, actionVectors: digest.evidence.threadVectors(vectors),
                                                       embeddingModel: vectors.model)
        #expect(embedded.text == digest.text, "\(name)")
        #expect(embedded.attribution.links.count == digest.evidence.ledger.effects.count + digest.evidence.ledger.intermediate.count)
    }

}
#endif
