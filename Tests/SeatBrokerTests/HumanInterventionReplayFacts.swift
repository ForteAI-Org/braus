//
//  HumanInterventionReplayFacts.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

#if DEBUG
import Foundation
import Testing
@testable import SeatBroker

/// Recorded interventions replayed by tests. They hold what a person did in real applications, so they stay out of
/// the repository: BRAUS_REPLAY_DIR names a folder of archives; without it the replay tests do not run.
enum ReplayArchives {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["BRAUS_REPLAY_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Every archive in the folder this engine reads (version 3), by name, sorted.
    static var all: [(name: String, url: URL)] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            struct Manifest: Decodable { let version: Int }
            guard let data = try? Data(contentsOf: url.appendingPathComponent("review.json")),
                  (try? JSONDecoder().decode(Manifest.self, from: data))?.version == 3 else { return nil }
            return (name.hasPrefix(".replay-") ? String(name.dropFirst(".replay-".count)) : name, url)
        }
    }

    static var names: [String] { all.map(\.name) }

    static func url(_ name: String) -> URL? { all.first { $0.name == name }?.url }

    /// What the person did and what the report must say, from `expected.json` beside the archive.
    static func expectation(_ name: String) -> ReplayExpectation? {
        guard let url = url(name), let data = try? Data(contentsOf: url.appendingPathComponent("expected.json")) else { return nil }
        return try? JSONDecoder().decode(ReplayExpectation.self, from: data)
    }
}

/// An archive's expected facts, each optional: effects and invariants rather than wording.
struct ReplayExpectation: Decodable {
    /// The person's account, for the loss audit.
    var truths: [LossAudit.Truth]?
    /// The body's effects exactly, in any order.
    var stated: [String]?
    var statedIncludes: [String]?
    var textIncludes: [String]?
    var textExcludes: [String]?
    /// The body's "Unobserved:" entries exactly, or entries starting with these.
    var unobserved: [String]?
    var unobservedPrefixes: [String]?
    /// Effect kinds the body must not hold (a positional identifier read as a rename, a member never named).
    var noEffectKinds: [String]?
    /// No body effect without a cause ("Also changed" stays out).
    var allCaused: Bool?
    /// Texts the details keep: intermediate effects and every step's observations.
    var detailsIncludes: [String]?
}

/// What a replayed report states, for tests that check facts rather than wording: the body's net effects, the
/// effects details keep as intermediate, and the body's "Unobserved:" entries.
extension HumanInterventionSummary.Digest {
    /// Each body effect in neutral words: "+ A", "− B", "C → D", "E moved after F", "G: H → I".
    var stated: [String] { evidence.ledger.effects.map(HumanInterventionEffects.describe) }
    /// Body effects under "Also changed (cause unknown)".
    var uncaused: [String] { evidence.ledger.effects.filter { $0.causes.isEmpty }.map(HumanInterventionEffects.describe) }
    /// Effects that did not survive to the end, and every step's texts: details only.
    var between: [String] {
        evidence.ledger.intermediate.map(HumanInterventionEffects.describe) + evidence.steps.map(\.text)
    }
    var unobserved: [String] {
        text.split(separator: "\n").first { $0.hasPrefix("Unobserved: ") }
            .map { $0.dropFirst("Unobserved: ".count).dropLast().components(separatedBy: "; ") } ?? []
    }

    /// The invariants every report keeps: the budget, every net change accounted for (an effect, an intermediate
    /// state or noise), net means net, no bare count, time, date or marker as a subject, no rename chain, and no
    /// claims or thread counts in place of effects.
    func checkInvariants(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(text.utf8.count <= HumanInterventionSummary.maximumBytes, "\(name)", sourceLocation: sourceLocation)
        let ledger = evidence.ledger
        #expect(ledger.dispositions.count == ledger.netChanges.count, "\(name)", sourceLocation: sourceLocation)
        #expect(evidence.ledger.stale() == [], "\(name)", sourceLocation: sourceLocation)
        #expect(evidence.ledger.malformed() == [], "\(name)", sourceLocation: sourceLocation)
        #expect(!text.contains("performed, not verified") && !text.contains("threads omitted"), "\(name)",
                sourceLocation: sourceLocation)
    }

    func check(_ expected: ReplayExpectation, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if let stated = expected.stated { #expect(self.stated.sorted() == stated.sorted(), "\(name)", sourceLocation: sourceLocation) }
        for fact in expected.statedIncludes ?? [] { #expect(self.stated.contains(fact), "\(name)", sourceLocation: sourceLocation) }
        for fact in expected.textIncludes ?? [] { #expect(text.contains(fact), "\(name)", sourceLocation: sourceLocation) }
        for fact in expected.textExcludes ?? [] { #expect(!text.contains(fact), "\(name)", sourceLocation: sourceLocation) }
        if let unobserved = expected.unobserved { #expect(self.unobserved == unobserved, "\(name)", sourceLocation: sourceLocation) }
        for prefix in expected.unobservedPrefixes ?? [] {
            #expect(self.unobserved.contains { $0.hasPrefix(prefix) }, "\(name)", sourceLocation: sourceLocation)
        }
        for kind in expected.noEffectKinds ?? [] {
            #expect(!evidence.ledger.effects.contains { "\($0.kind)" == kind }, "\(name)", sourceLocation: sourceLocation)
        }
        if expected.allCaused == true { #expect(uncaused.isEmpty, "\(name)", sourceLocation: sourceLocation) }
        for fact in expected.detailsIncludes ?? [] {
            #expect(between.contains { $0.contains(fact) }, "\(name)", sourceLocation: sourceLocation)
        }
    }
}
#endif
