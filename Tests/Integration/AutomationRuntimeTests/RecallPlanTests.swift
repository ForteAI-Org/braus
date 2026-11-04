import AutomationMCP
@testable import AutomationRuntime
import Memory
import SQLiteMemory
import Testing

@MainActor
@Suite("RecallPlan")
struct RecallPlanTests {
    func source(_ id: String, kind: PartKind = .procedure, score: Double) -> ScoredSource {
        let source = RecallSource(routeID: id, procedureLabel: "Export", steps: [],
            parts: [.init(partID: id, kind: kind, firstPosition: 0, lastPosition: 0, label: "Export",
                          bundleID: "com.apple.Notes", isOffered: true)], parameters: [], confirmedUses: 0)
        return ScoredSource(source: source, stepRelevance: kind == .step ? [0: score] : [:], partRelevance: [id: score])
    }

    @Test func belowThresholdIsNotOffered() {
        let scored = [[source("one", score: 0.01)]]
        #expect(RecallChoice.shortlist(scored, suggestions: []).isEmpty)
    }

    @Test func thresholdsByKind() {
        #expect(RecallChoice.shortlist([[source("part", score: 0.62)]], suggestions: []).count == 1)
        #expect(RecallChoice.shortlist([[source("step", kind: .step, score: 0.65)]], suggestions: []).isEmpty)
        #expect(RecallChoice.shortlist([[source("step", kind: .step, score: 0.68)]], suggestions: []).count == 1)
    }

    @Test func noGlobalCapOnVersions() {
        let scored = (1...8).map { [source("route\($0)", score: 0.8)] }
        #expect(RecallChoice.shortlist(scored, suggestions: []).count == 8)
        #expect(RecallChoice.shortlist(Array(scored.reversed()), suggestions: []).count == 8)
    }

    @Test func trustLabelOfferedWithLowerWeight() {
        let result = RecallChoice.shortlist([[source("a", score: 0.6), source("b", score: 0.6)]],
            suggestions: [], trust: ["a": .notYetVerified])
        #expect(result.map(\.routeID) == ["b", "a"])
        #expect(result.last?.relevance == 0.6)
    }

    @Test func allNamesResolveApp() {
        let known = [RecallApplications.Known(bundleID: "com.apple.Notes", names: ["Notes", "Note"])]
        #expect(RecallApplications.resolve("Note", among: known) == .resolved("com.apple.Notes"))
        #expect(RecallApplications.resolve("Notes", among: known) == .resolved("com.apple.Notes"))
        #expect(RecallApplications.candidates(for: "Ntes", among: known) == ["com.apple.Notes"])
    }

    @Test func ambiguousAppGivesCandidates() {
        let known = [RecallApplications.Known(bundleID: "com.apple.mail", names: ["Mail"]),
                     .init(bundleID: "com.other.mail", names: ["Mail"])]
        #expect(RecallApplications.resolve("Mail", among: known) == .ambiguous(known.map(\.bundleID)))
        #expect(RecallApplications.candidates(for: "Mail", among: known) == known.map(\.bundleID))
    }
    @Test func filtersBeforeTopK() {
        let family = ProcedureFamilyID(bundleID: "com.apple.Notes", rootRouteUUID: "root")
        let filter = RecallFilters(bundleIDs: ["com.apple.Notes"], availableChannels: ["menu"], doNotUse: [family])
        func entry(_ number: Int, bundle: String? = "com.apple.Notes") -> SQLiteRecallRepository.IndexEntry {
            .init(partID: "part\(number)", routeID: "route\(number)", kind: .procedure, digest: "d",
                  text: "Export", vector: nil, bundleID: bundle)
        }
        let valid = RecallAdmissibility(family: .init(bundleID: "com.apple.Notes", rootRouteUUID: "other"),
            channels: ["menu"], trust: nil, fromFailedAttempt: false)
        let excluded = RecallAdmissibility(family: family, channels: ["menu"], trust: nil, fromFailedAttempt: false)
        let failed = RecallAdmissibility(family: valid.family, channels: ["menu"], trust: nil, fromFailedAttempt: true)
        let unavailable = RecallAdmissibility(family: valid.family, channels: ["app_call:export"], trust: nil, fromFailedAttempt: false)
        let candidates = [(entry(0, bundle: "com.other.App"), valid), (entry(1), excluded), (entry(2), failed)]
            + (3...55).map { (entry($0), unavailable) } + (56...58).map { (entry($0), valid) }
        let admitted = candidates.filter { filter.admits($0.0, $0.1) }.prefix(3)
        #expect(admitted.map { $0.0.partID } == ["part56", "part57", "part58"])
        #expect(!filter.admits(entry(59), nil))
        #expect(filter.admits(entry(60, bundle: nil), valid))
    }

    @Test func learnModeDeliversNoMemory() async throws {
        let memory = try W.service()
        let service = RecallService(memory: memory, configuration: RecallCycleTests.configuration(.lexical))
        let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: "Export")
        await memory.close()
        let prepared = try await service.prepare(request, access: MemoryAccess(reads: false, learns: true, enrichesScenes: true))
        #expect(!prepared.readsMemory)
        #expect(prepared.sources.isEmpty)
        #expect(prepared.cache == nil)
        let counts = await service.admissibilityReadCount
        #expect(counts == 0)
        await memory.close()
    }

    @Test func kIsThreePerRow() {
        let candidates = (1...5).map { source("route\($0)", score: 0.9 - Double($0) * 0.01) }
        let result = RecallChoice.shortlist([candidates, candidates], suggestions: [])
        #expect(result.filter { $0.needPosition == 0 }.count == 3)
        #expect(result.filter { $0.needPosition == 1 }.count == 3)
    }

}
