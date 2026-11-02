//
//  HumanInterventionLossAuditTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

#if DEBUG
import Foundation
import Testing
@testable import SeatBroker

/// HumanInterventionLossAuditTests measures what the handoff report keeps of what the person did, on every replay
/// archive in BRAUS_REPLAY_DIR (see ReplayArchives), judged against the truths in each archive's `expected.json`. Off
/// unless BRAUS_REPORT_AUDIT=1; BRAUS_REPORT_AUDIT_OUT names an output file, BRAUS_REPORT_AUDIT_ONLY lists archives
/// (names, comma-separated), BRAUS_REPORT_AUDIT_VERBOSE=1 adds every net change.
@Suite
struct HumanInterventionLossAuditTests {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var enabled: Bool { environment["BRAUS_REPORT_AUDIT"] == "1" }

    @Test(.enabled(if: enabled))
    func audit() async throws {
        let only = Set((Self.environment["BRAUS_REPORT_AUDIT_ONLY"] ?? "").split(separator: ",").map(String.init))
        let archives = ReplayArchives.all.filter { only.isEmpty || only.contains($0.name) }
        var recordings: [LossAudit.Recording] = []
        // The model loads once; every archive's commands and effects are then embedded for attribution.
        HumanInterventionEmbeddings.prepareLocal()
        _ = await HumanInterventionEmbeddings.local().vectors(actions: ["load"], effects: ["model"])
        for (name, directory) in archives {
            let archive = try await HumanInterventionReplay.read(directory)
            let evidence = HumanInterventionEvidence(findings: archive.findings, finalState: archive.finalState)
            let vectors = await HumanInterventionEmbeddings.local().vectors(actions: evidence.embeddingActions,
                                                                            effects: evidence.embeddingEffects)
            recordings.append(LossAudit.Recording(name: name, evidence: evidence,
                                                  truths: ReplayArchives.expectation(name)?.truths ?? [],
                                                  vectors: evidence.threadVectors(vectors), mode: vectors.mode,
                                                  model: vectors.model))
        }
        let text = LossAudit.render(recordings, verbose: Self.environment["BRAUS_REPORT_AUDIT_VERBOSE"] == "1")
        print(text)
        if let path = Self.environment["BRAUS_REPORT_AUDIT_OUT"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(recordings.allSatisfy { $0.digest.text.utf8.count <= HumanInterventionSummary.maximumBytes })
        // Invariants 5, 7 and 8: net means net, no bare count or marker as a subject, no rename chain.
        #expect(recordings.allSatisfy { $0.evidence.ledger.stale().isEmpty && $0.evidence.ledger.malformed().isEmpty })
        // Every net change is accounted for: an effect, an intermediate state, or noise with its reason.
        #expect(recordings.allSatisfy { $0.evidence.ledger.dispositions.count == $0.evidence.ledger.netChanges.count })
        // Causes are ranked only with the model the floor was calibrated on.
        #expect(recordings.allSatisfy { $0.mode != "embedding" || $0.digest.attribution.model == HumanInterventionAttribution.floorModel })
        // Invariant 6: the body is the same with and without embeddings.
        #expect(recordings.allSatisfy { $0.digest.text == $0.plain.text })
    }
}

/// LossAudit compares what the person did (each archive's account) with the effects ledger and the rendered digest. The
/// truths are audit judgements written for measurement; none of them may become an engine rule.
enum LossAudit {
    enum Verdict: String { case reported, details = "details only", unobserved = "stated unobserved", dropped }

    struct Truth: Decodable {
        enum Kind: String, Decodable { case created, deleted, renamed, moved, edited, sorted, navigated, command }
        let kind: Kind
        /// The object, control or collection; nil when the person's account does not name it.
        let subject: String?
        var before: String? = nil
        var after: String? = nil
        /// False for a consequence that did not survive to the end: details only, never the report body.
        var net = true
        var note = ""

        enum CodingKeys: String, CodingKey { case kind, subject, before, after, net, note }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(Kind.self, forKey: .kind)
            subject = try values.decodeIfPresent(String.self, forKey: .subject)
            before = try values.decodeIfPresent(String.self, forKey: .before)
            after = try values.decodeIfPresent(String.self, forKey: .after)
            net = try values.decodeIfPresent(Bool.self, forKey: .net) ?? true
            note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        }

        var title: String {
            let names = [before, subject, after].compactMap { $0 }
            return kind.rawValue + " " + (names.isEmpty ? "(unnamed)" : names.joined(separator: " → ")) + (net ? "" : " [intermediate]")
        }
    }

    struct Recording {
        let name: String
        let evidence: HumanInterventionEvidence
        let truths: [Truth]
        let digest: HumanInterventionSummary.Digest
        /// The digest without embeddings: its body must equal the ranked one's.
        let plain: HumanInterventionSummary.Digest
        let mode: String
        let model: String?

        init(name: String, evidence: HumanInterventionEvidence, truths: [Truth], vectors: [[Float]], mode: String,
             model: String?) {
            self.name = name
            self.evidence = evidence
            self.truths = truths
            self.mode = mode
            self.model = model
            digest = HumanInterventionSummary.digest(evidence, actionVectors: vectors, embeddingModel: model)
            plain = HumanInterventionSummary.digest(evidence)
        }

        /// Where the report put what the person did.
        func verdict(_ truth: Truth) -> (Verdict, String) {
            let key = HumanInterventionIdentity.normalized
            func names(_ text: String?) -> Bool {
                guard let subject = truth.subject.map(key), !subject.isEmpty, let text else { return false }
                return key(text).contains(subject)
            }
            let ledger = evidence.ledger
            func matches(_ effect: HumanInterventionEffects.Effect) -> Bool {
                switch truth.kind {
                case .created: return effect.kind == .created && names(effect.label)
                case .deleted: return effect.kind == .deleted && names(effect.label)
                case .renamed: return effect.kind == .renamed && (names(effect.after) || names(effect.label))
                case .moved: return effect.kind == .moved && names(effect.label)
                case .sorted: return effect.kind == .resorted || effect.whole
                case .edited: return [.value, .edited, .state].contains(effect.kind)
                    && (names(effect.label) || truth.after.map { key(effect.after ?? "").contains(key($0)) } == true)
                case .navigated: return effect.kind == .title && truth.after.map { key(effect.after ?? "").contains(key($0)) } == true
                case .command: return names(effect.after) || names(effect.label)
                }
            }
            if let found = ledger.effects.first(where: matches) { return (.reported, HumanInterventionEffects.describe(found)) }
            if let found = ledger.intermediate.first(where: matches) {
                return (.details, HumanInterventionEffects.describe(found) + " (intermediate)")
            }
            if let line = digest.text.split(separator: "\n").first(where: { $0.hasPrefix("Unobserved: ") }),
               truth.subject.map({ key(String(line)).contains(key($0)) }) == true {
                return (.unobserved, String(line))
            }
            if evidence.steps.flatMap(\.observed).contains(where: names) { return (.details, "observed in a step") }
            return (.dropped, "")
        }
    }

    static func render(_ recordings: [Recording], verbose: Bool) -> String {
        var lines = ["# Report Human Interaction loss audit", ""]
        var totals: [Verdict: Int] = [:]
        var wrongPlace = 0
        for recording in recordings {
            lines += ["## \(recording.name)", "", "Report (\(recording.digest.text.utf8.count) bytes):", "```",
                      recording.digest.text, "```", ""]
            if !recording.truths.isEmpty {
                lines += ["| truth | verdict | evidence |", "|---|---|---|"]
                for truth in recording.truths {
                    var (verdict, evidence) = recording.verdict(truth)
                    // An intermediate truth belongs in details; in the body it is in the wrong place.
                    if !truth.net, verdict == .reported { wrongPlace += 1; evidence += " — wrong place" }
                    if !truth.net, verdict == .details { verdict = .reported }
                    totals[verdict, default: 0] += 1
                    lines.append("| \(truth.title) | \(verdict.rawValue) | \(evidence.replacingOccurrences(of: "|", with: "/")) |")
                }
                lines.append("")
            }
            let ledger = recording.evidence.ledger
            var dispositions: [String: Int] = [:]
            for disposition in ledger.dispositions {
                switch disposition {
                case .effect: dispositions["effect", default: 0] += 1
                case .intermediate: dispositions["intermediate", default: 0] += 1
                case .noise(let reason): dispositions["noise: " + reason, default: 0] += 1
                }
            }
            lines.append("Ledger: \(ledger.netChanges.count) net changes, \(ledger.stepChanges.count) step changes; "
                + dispositions.keys.sorted().map { "\($0) \(dispositions[$0] ?? 0)" }.joined(separator: ", ") + ".")
            lines.append("Effects: " + (ledger.effects.map(HumanInterventionEffects.describe).joined(separator: "; ")))
            if verbose {
                lines.append("```")
                for (change, disposition) in zip(ledger.netChanges, ledger.dispositions) {
                    lines.append("NET w\(change.window) r\(change.from)→r\(change.to) \(change.kind.rawValue) \"\(change.name)\" "
                        + "\(change.before ?? "∅") → \(change.after ?? "∅") \(change.role ?? "") -> \(disposition)")
                }
                lines.append("```")
            }
            lines.append("")
        }
        lines += ["## Totals", "",
                  Verdict.allCases.map { "\($0.rawValue) \(totals[$0] ?? 0)" }.joined(separator: ", ")
                    + ", wrong place \(wrongPlace)."]
        return lines.joined(separator: "\n")
    }
}

extension LossAudit.Verdict: CaseIterable {}
#endif
