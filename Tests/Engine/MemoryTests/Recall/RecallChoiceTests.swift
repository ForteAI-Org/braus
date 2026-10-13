//
//  RecallChoiceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
@testable import Memory
import Testing

/// RecallChoiceTests prove the structural side of the experiment of the agent's choice on versions built by hand: the
/// shortlist keeps a version the automatic selector names nothing in; a plan is admitted only when the proposal, the
/// versions, the steps and the order allow it; every tract is evaluated by the automatic selector's own rules; and the
/// coverage is Engine's, the agent's declaration beside it. The plans here are written by the test: they prove the API,
/// not what an agent chooses.
@Suite("The agent's choice: shortlist, validation and coverage")
struct RecallChoiceTests {
    typealias S = RecallSelectionTests

    static let producer = try! TaskProducer(source: .app, streamID: "worker")

    static func proposal(_ needs: [RecallNeed], _ shortlisted: [RecallChoice.Shortlisted], revision: Int = 1, at: Int64 = 1_000,
                         attempt: String = "attempt") -> RecallChoice.Proposal {
        RecallChoice.Proposal(proposalID: "p", taskID: "task", attemptID: attempt, revision: revision, producer: producer, reason: .initial,
                              remainingWork: needs.first?.text ?? "work", needs: needs, shortlisted: shortlisted, recordedAtMS: at)
    }

    static func validate(_ plan: [RecallChoice.PlannedNeed], _ proposal: RecallChoice.Proposal, sources: [RecallSource],
                         values: [TaskValue] = S.exportValues, constraints: [String] = [], superseded: Set<String> = [], revision: Int = 1,
                         now: Int64 = 2_000, attempt: String = "attempt", producer: TaskProducer = Self.producer) -> Result<[RecallChoice.Chosen], RecallChoice.Refusal> {
        RecallChoice.validate(RecallChoice.Plan(proposalID: "p", needs: plan), against: proposal,
                              sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.routeID, $0) }), superseded: superseded, producer: producer,
                              attemptID: attempt, revision: revision,
                              context: RecallSelector.Context(values: values, constraints: constraints, needs: proposal.needs), nowMS: now)
    }

    static func need(_ text: String, app: String? = nil) -> RecallNeed { try! RecallNeed(text: text, bundleID: app) }

    static func tract(_ key: String, _ from: Int, _ to: Int) -> RecallChoice.Tract { RecallChoice.Tract(key: key, first: from - 1, last: to - 1) }

    static func admitted(_ result: Result<[RecallChoice.Chosen], RecallChoice.Refusal>) throws -> [RecallChoice.Chosen] {
        switch result {
            case .success(let chosen): return chosen
            case .failure(let refusal):
                Issue.record("refused: \(refusal)")
                throw refusal
        }
    }

    static func refusal(_ result: Result<[RecallChoice.Chosen], RecallChoice.Refusal>) -> RecallChoice.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    // MARK: Shortlist

    @Test("the shortlist keeps the most relevant versions per need, a name each, even one the automatic selector names nothing in")
    func shortlistKeepsTheSource() {
        let photo = S.scored(S.photo(), steps: [2: 0.91, 3: 0.91, 4: 0.91, 5: 0.91, 6: 0.91], parts: ["photo/block-1": 0.95])
        let other = S.scored(S.photo(route: "other"), steps: [3: 0.2], parts: [:])
        let unrelated = S.scored(S.photo(route: "none"), steps: [:], parts: [:], floor: 0)
        let paraphrase = S.select([photo], need: "Turn the open picture clockwise and export it as PNG", app: S.preview)
        let italian = S.select([photo], need: "Ruota l'immagine e salvala in PNG", app: S.preview)
        let list = RecallChoice.shortlist([[other, photo, unrelated], [photo]], suggestions: [paraphrase, italian])
        #expect(list.map(\.key) == ["s1", "s2", "s1"] && list.map(\.routeID) == ["photo", "other", "photo"], "\(list)")
        #expect(list[0].suggested == paraphrase.selected?.positions, "the automatic suggestion is kept beside the version")
        #expect(list[2].suggested == nil && italian.selected == nil, "the Italian request names nothing, the version is still shortlisted")
        #expect(!list.contains { $0.routeID == "none" }, "a version relevant in nothing is not shortlisted")
    }

    // MARK: Admitted plans

    @Test("F11 in A: the paraphrase's rotation and export, chosen by the agent, are delivered complete; the export alone is partial when said so")
    func paraphraseChosen() throws {
        let need = Self.need("Turn the open picture clockwise and export it as PNG", app: S.preview)
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.95, suggested: 3...6)])
        let chosen = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 3, 7)], declared: .all,
                                                                               uncovered: nil)], proposal, sources: [S.photo()]))
        let outcome = try #require(chosen.first?.outcome)
        #expect(outcome.coverage == .complete && outcome.plan.map(\.positions) == [2...6] && outcome.selected == nil)
        #expect(outcome.plan.first?.requirements.contains { $0.kind == .entryState && $0.stepPosition == 2 } == true)
        let narrow = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .part,
                                                                               uncovered: "the clockwise rotation")], proposal, sources: [S.photo()]))
        #expect(narrow.first?.outcome.coverage == .partial && narrow.first?.outcome.reason == .gaps)
        #expect(narrow.first?.declared == .part && narrow.first?.uncovered == "the clockwise rotation")
    }

    @Test("F10 in A: the producer and the consumer as two tracts of one source; the download between is not delivered and the input is produced")
    func producerAndConsumerApart() throws {
        let source = RecallProvenanceTests.twoReports(attachment: "task-rep/exported_report")
        let need = Self.need("Email the report to luca@example.com")
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "rep", relevance: 0.9, suggested: 2...5)])
        let values = [S.value("recipient", "luca@example.com")]
        let chosen = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 1, 1), Self.tract("s1", 3, 6)],
                                                                               declared: .all, uncovered: nil)],
                                                     proposal, sources: [source], values: values))
        let outcome = try #require(chosen.first?.outcome)
        #expect(outcome.plan.map(\.positions) == [0...0, 2...5] && outcome.coverage == .complete, "\(outcome.plan.map(\.positions)) \(outcome.coverage)")
        #expect(outcome.plan[1].requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" && $0.stepPosition == 0 })
        #expect(!outcome.plan.contains { $0.positions.contains(1) }, "the Safari download is not delivered")
        let consumerAlone = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 3, 6)], declared: .all,
                                                                                      uncovered: nil)], proposal, sources: [source], values: values))
        #expect(consumerAlone.first?.outcome.coverage == .ambiguous, "without its producer the attachment stays missing")
        #expect(consumerAlone.first?.outcome.plan.first?.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "attachment" } == true)
    }

    @Test("a missing parameter stays missing whatever the agent declares; no tract is an absence")
    func declarationsDoNotOverrideFacts() throws {
        let need = Self.need("Export the image as PNG", app: S.preview)
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil)])
        let lacking = [S.value("output_extension", "png"), S.value("output_format", "PNG")]
        let chosen = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .all,
                                                                               uncovered: nil)], proposal, sources: [S.photo()], values: lacking))
        #expect(chosen.first?.outcome.coverage == .ambiguous && chosen.first?.outcome.reason == .unresolvedInput)
        let none = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [], declared: .none, uncovered: "nothing fits")],
                                                   proposal, sources: [S.photo()]))
        #expect(none.first?.outcome.coverage == .absent && none.first?.outcome.plan.isEmpty == true)
    }

    @Test("two needs, one covered by a source and the other by none: each keeps its own coverage")
    func oneNeedUncovered() throws {
        let needs = [Self.need("Export the image as PNG", app: S.preview), Self.need("Print the exported image")]
        let proposal = Self.proposal(needs, [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil),
                                             RecallChoice.Shortlisted(needPosition: 1, key: "s1", routeID: "photo", relevance: 0.3, suggested: nil)])
        let chosen = try Self.admitted(Self.validate([
            RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .all, uncovered: nil),
            RecallChoice.PlannedNeed(position: 1, tracts: [], declared: .none, uncovered: "no learned printing"),
        ], proposal, sources: [S.photo()]))
        #expect(chosen.map(\.outcome.coverage) == [.complete, .absent])
        #expect(NeedOutcome.overall(chosen.map(\.outcome)) == .partial, "complete never ignores an uncovered need")
    }

    // MARK: Refused plans

    @Test("names, ranges and order the proposal or the version do not admit are refused, every reason listed")
    func invalidPlans() {
        let need = Self.need("Export the image as PNG", app: S.preview)
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil)])
        func refused(_ plan: [RecallChoice.PlannedNeed], superseded: Set<String> = [], sources: [RecallSource] = [S.photo()]) -> [String] {
            guard let refusal = Self.refusal(Self.validate(plan, proposal, sources: sources, superseded: superseded)) else {
                Issue.record("admitted: \(plan)")
                return []
            }
            #expect(refusal.code == .invalid)
            return refusal.problems
        }
        func planned(_ tracts: [RecallChoice.Tract], declared: RecallChoice.Declared = .all, position: Int = 0) -> [RecallChoice.PlannedNeed] {
            [RecallChoice.PlannedNeed(position: position, tracts: tracts, declared: declared, uncovered: nil)]
        }
        #expect(refused(planned([Self.tract("s9", 4, 7)])).contains { $0.contains("no source s9") })
        #expect(refused(planned([Self.tract("s1", 4, 12)])).contains { $0.contains("are not steps") })
        #expect(refused(planned([Self.tract("s1", 5, 7), Self.tract("s1", 4, 4)])).contains { $0.contains("in its order") })
        #expect(refused(planned([Self.tract("s1", 4, 7)], declared: .none)).contains { $0.contains("covered by none") })
        #expect(refused(planned([], declared: .all)).contains { $0.contains("by no tract") })
        #expect(refused(planned([Self.tract("s1", 4, 7)], position: 1)).contains { $0.contains("no need 2") })
        #expect(refused(planned([Self.tract("s1", 1, 7)])).contains { $0.contains("runs in com.apple.finder") }, "the need is bound to Preview")
        #expect(refused(planned([Self.tract("s1", 4, 7)]), superseded: ["photo"]).contains { $0.contains("superseded") })
        #expect(refused(planned([Self.tract("s1", 4, 7)]), sources: [S.photo(offered: Set(0...7).subtracting([5]))])
                    .contains { $0.contains("step 6 of s1 is no longer offered") })
        #expect(refused(planned([Self.tract("s1", 4, 7)]), sources: []).contains { $0.contains("can no longer be read") })
    }

    @Test("a fixed choice the task contradicts, or a step a constraint forbids, refuses the tract whatever the agent declares")
    func certainExclusionsRefuse() {
        let need = Self.need("Export the image as PNG")
        let fixed = RecallScopeSelectionTests.fixedJPEG()
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: fixed.routeID, relevance: 0.9, suggested: nil)])
        let conflict = Self.refusal(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .all,
                                                                            uncovered: nil)], proposal, sources: [fixed]))
        #expect(conflict?.problems.contains { $0.contains("contradicts") } == true, "\(conflict?.problems ?? [])")
        let photoProposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil)])
        let forbidden = Self.refusal(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 3, 7)], declared: .all,
                                                                             uncovered: nil)], photoProposal, sources: [S.photo()],
                                                   constraints: ["Do not rotate the image"]))
        #expect(forbidden?.problems.contains { $0.contains("constraint 1 forbids") } == true, "\(forbidden?.problems ?? [])")
    }

    @Test("a proposal of another producer is unknown; one of an earlier attempt, another revision, or one too old, is stale")
    func staleAndUnknownProposals() {
        let need = Self.need("Export the image as PNG", app: S.preview)
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil)])
        let plan = [RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .all, uncovered: nil)]
        #expect(Self.refusal(Self.validate(plan, proposal, sources: [S.photo()], attempt: "resumed"))?.code == .stale)
        let other = try! TaskProducer(source: .mcp, streamID: "client")
        #expect(Self.refusal(Self.validate(plan, proposal, sources: [S.photo()], producer: other))?.code == .unknown)
        #expect(Self.refusal(Self.validate(plan, proposal, sources: [S.photo()], revision: 2))?.code == .stale)
        #expect(Self.refusal(Self.validate(plan, proposal, sources: [S.photo()], now: 1_000 + RecallChoice.validityMS + 1))?.code == .stale)
        #expect(Self.refusal(Self.validate(plan, proposal, sources: [S.photo()], now: 1_000 + RecallChoice.validityMS)) == nil)
    }

    @Test("an ambiguous answer runs no tract, gives at least two alternatives and the question; alternatives belong to it alone")
    func ambiguousAnswers() throws {
        let need = Self.need("Export the image", app: S.preview)
        let proposal = Self.proposal([need], [RecallChoice.Shortlisted(needPosition: 0, key: "s1", routeID: "photo", relevance: 0.9, suggested: nil),
                                              RecallChoice.Shortlisted(needPosition: 0, key: "s2", routeID: "other", relevance: 0.8, suggested: nil)])
        let sources = [S.photo(), S.photo(route: "other")]
        let malformed = [
            RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .ambiguous, uncovered: "Which format?",
                                     alternatives: [Self.tract("s1", 4, 7), Self.tract("s2", 4, 7)]),
            RecallChoice.PlannedNeed(position: 0, tracts: [], declared: .ambiguous, uncovered: "Which format?", alternatives: [Self.tract("s1", 4, 7)]),
            RecallChoice.PlannedNeed(position: 0, tracts: [], declared: .ambiguous, uncovered: nil,
                                     alternatives: [Self.tract("s1", 4, 7), Self.tract("s2", 4, 7)]),
            RecallChoice.PlannedNeed(position: 0, tracts: [Self.tract("s1", 4, 7)], declared: .all, uncovered: nil,
                                     alternatives: [Self.tract("s2", 4, 7)]),
        ]
        let reasons = ["with tracts to run", "1 alternative", "without the question", "not said ambiguous"]
        for (planned, reason) in zip(malformed, reasons) {
            let refused = Self.refusal(Self.validate([planned], proposal, sources: sources))
            #expect(refused?.code == .invalid && refused?.problems.contains { $0.contains(reason) } == true, "\(reason): \(String(describing: refused))")
        }
        let chosen = try Self.admitted(Self.validate([RecallChoice.PlannedNeed(position: 0, tracts: [], declared: .ambiguous, uncovered: "Which format?",
                                                                               alternatives: [Self.tract("s1", 4, 7), Self.tract("s2", 4, 7)])],
                                                     proposal, sources: sources))
        let outcome = try #require(chosen.first?.outcome)
        #expect(outcome.coverage == .ambiguous && outcome.reason == .alternatives && outcome.delivered.isEmpty)
        #expect(outcome.alternatives.map(\.routeID) == ["photo", "other"] && outcome.alternatives.allSatisfy { $0.role == .alternative })
    }
}
