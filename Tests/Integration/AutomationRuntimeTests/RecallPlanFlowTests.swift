@testable import AutomationMCP
@testable import AutomationRuntime
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

@MainActor
@Suite("RecallPlan delivery", .serialized)
struct RecallPlanFlowTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    @MainActor
    final class Fixture {
        let session: LearningSession
        let memory: MemoryService
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter: ResultFormatter
        let handler: TaskCycleHandler
        let content: TaskRevisionContent
        let owner: TaskProducer
        let task: OpenTask

        init(learn: Bool = false) async throws {
            session = P.photoSession(try W.directory())
            memory = MemoryService.shared(for: session.directory)
            RecallService.install(RecallService(memory: memory, configuration: L.configuration(.lexical)))
            if learn { _ = try await L.learnPhoto(session) }
            formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
            handler.availableRecallChannels = { Set(AgentTool.allCases.map(\.rawValue)) }
            content = try TaskRevisionContent(goal: "Export the photo in Preview")
            owner = try TaskProducer(source: .app, streamID: "plan-test")
            task = try await TaskChannel.begin(content, producer: owner, traceID: nil, memory: memory)
            handler.openTask = task
        }

        func close() async { await L.close(session) }
    }

    private func learnCompatibleCorpus(_ corpus: RecallCorpus, into directory: URL) async throws {
        // The current contact fixture's last literal is refused by qualification; keep that admission unchanged.
        for item in corpus.knowledge where item["id"].string != "contacts-new-person" {
            _ = try await corpus.learn(item, into: directory)
        }
    }

    @Test func cachedAdmissibilityIsReadOnlyForNewVersions() async throws {
        let fixture = try await Fixture(learn: true)
        let service = RecallService.shared(for: fixture.memory)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: fixture.content.goal)
        let first = try await service.prepare(request, availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        let count = await service.admissibilityReadCount
        let second = try await service.prepare(request, availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        #expect(count == 1)
        #expect(await service.admissibilityReadCount == count)
        #expect(!first.sources.isEmpty)
        #expect(first.sources.map(\.routeID) == second.sources.map(\.routeID))
        await fixture.close()
    }

    @Test func batchesBeyondEight() async throws {
        let fixture = try await Fixture()
        let rows = (1...11).map { TodoRow(id: .init(rawValue: "r\($0)"), title: "Export") }
        let answer = await fixture.handler.deliverMemory(for: rows, content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(answer["recall_error"] == nil, "\(answer)")
        #expect(fixture.handler.rowMemory.count == 11)
        #expect(Set(fixture.handler.rowMemory.values.map(\.proposal)).count == 11)
        #expect((answer["memory"]?.string ?? "").count <= RecallRendering.answerBudget)
        await fixture.close()
    }

    @Test func learnModeDeliversNoMemory() async throws {
        let fixture = try await Fixture(learn: true)
        fixture.handler.memoryAccess = MemoryAccess(reads: false, learns: true, enrichesScenes: true)
        let answer = await fixture.handler.deliverMemory(for: [.init(id: .init(rawValue: "r1"), title: "Export")],
            content: fixture.content, task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(answer == ["guidance": .string("memory is not read in this session")])
        #expect(fixture.handler.rowMemory.isEmpty)
        #expect(await RecallService.shared(for: fixture.memory).admissibilityReadCount == 0)
        await fixture.close()
    }

    @Test func unknownAppGivesCandidatesWithoutAnOffer() async throws {
        let fixture = try await Fixture()
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Export", app: "Unknown editor")
        let answer = await fixture.handler.deliverMemory(for: [row], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(answer["memory"]?.string?.contains("application not resolved") == true)
        #expect(fixture.handler.rowMemory[row.id] == nil)
        await fixture.close()
    }

    @Test func compositionWarnsOnly() {
        let first = RecallChoice.CompositionPart(bundleID: "one", entry: .unknown, exit: .unknown,
            inputs: [], outputs: ["document"])
        let next = RecallChoice.CompositionPart(bundleID: "two", entry: .unknown, exit: .unknown,
            inputs: ["image"], outputs: [])
        #expect(RecallChoice.compositionWarnings(first, next) == [.appChanges, .unusedOutput])
    }

    @Test func emptyArchiveDeliversNoInventedMemory() async throws {
        let fixture = try await Fixture()
        let rows = [TodoRow(id: .init(rawValue: "r1"), title: "Export")]
        let actual = await fixture.handler.deliverMemory(for: rows, content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(actual["memory"] == nil)
        #expect(actual["recall_error"] == nil)
        #expect(actual["recall_proposal"] == nil)
        let hasOffers = fixture.handler.deliveredOffers.values.contains { !$0.isEmpty }
        #expect(!hasOffers)
        await fixture.close()
    }

    @Test func onlyNewRowsGetMemory() async throws {
        let fixture = try await Fixture()
        let old = TodoRow(id: .init(rawValue: "r1"), title: "First")
        let added = TodoRow(id: .init(rawValue: "r2"), title: "Second")
        fixture.handler.deliveredRows = [old.id]
        #expect(fixture.handler.rowsNeedingMemory([old, added]) == [added])
        fixture.handler.forgetDeliveredMemory()
        #expect(fixture.handler.rowsNeedingMemory([old, added]) == [old, added])
        await fixture.close()
    }

    @Test func rowValidationIsolated() async throws {
        let fixture = try await Fixture(learn: true)
        let service = RecallService.shared(for: fixture.memory)
        let route = try #require(try P.rows("SELECT r.route_uuid FROM memory_procedure_versions v JOIN memory_routes r ON r.route_id = v.route_id", in: fixture.session).first)
        let source = try #require(try await fixture.memory.perform { try await $0.recall.sources([route]) }.first)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: source.procedureLabel,
            needs: [try RecallNeed(text: source.procedureLabel), try RecallNeed(text: source.procedureLabel)])
        let proposals = try await service.proposeRows(request, producer: fixture.owner, access: .readLearn,
            availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        var rows: [TodoRow] = []
        for (index, proposal) in proposals.enumerated() {
            let part = try #require(proposal.parts.first)
            let range = try #require(proposal.ranges[part.partID])
            let row = TodoRow(id: .init(rawValue: "r\(index + 1)"), title: "Export", part: part.partID)
            let proposalID = try await service.recordPlanProposal(proposal, delivered: [part.partID], bytes: 100)
            fixture.handler.rowMemory[row.id] = .init(proposal: proposalID, need: 0,
                parts: [part.partID: (index == 0 ? "unknown" : part.key, range.lowerBound, range.upperBound)])
            fixture.handler.deliveredOffers[row.id] = [part]
            rows.append(row)
        }
        #expect(rows.count == 2)
        let state = await fixture.handler.preparePlanChoices(rows, task: fixture.task, content: fixture.content,
            owner: fixture.owner, memory: fixture.memory)
        #expect(state.choices.map(\.row) == [TodoRowID(rawValue: "r2")])
        #expect(state.notices.contains { $0.hasPrefix("r1:") })
        await fixture.close()
    }

    @Test func unavailableSearchIsNotReportedAsAnAbstention() async throws {
        let fixture = try await Fixture(learn: true)
        await RecallService.shared(for: fixture.memory).setIndexFault(RecallCorpus.Failure("synthetic index failure"))
        let answer = await fixture.handler.deliverMemory(for: [.init(id: .init(rawValue: "r1"), title: "Export")],
            content: fixture.content, task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(answer["memory"]?.string?.contains("Memory search is unavailable") == true)
        await fixture.close()
    }

    @Test func abstainsUnderThresholdOnFiveAbsentNeeds() async throws {
        let fixture = try await Fixture()
        let service = RecallService(memory: fixture.memory, configuration: L.configuration(.lexical))
        RecallService.install(service)
        let corpus = try RecallCorpus.load("recall-corpus-v4")
        try await learnCompatibleCorpus(corpus, into: fixture.session.directory)
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        let queries = Array((corpus.json["queries"].array ?? []).filter {
            ($0["id"].string ?? "").hasPrefix("absent-")
        }.prefix(5))
        #expect(queries.count == 5)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: "New work",
            needs: queries.map { try RecallNeed(text: $0["remaining"].string ?? "") })
        let proposals = try await service.proposeRows(request, producer: fixture.owner, access: .readLearn,
            availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        #expect(proposals.count == 5)
        #expect(proposals.allSatisfy { $0.searchAvailable })
        #expect(proposals.allSatisfy { $0.parts.isEmpty })
        await fixture.close()
    }

    @Test func filtersBeyondCandidateLimitOnWarmCache() async throws {
        let fixture = try await Fixture()
        let service = RecallService(memory: fixture.memory, configuration: L.configuration(.lexical))
        RecallService.install(service)
        try await learnCompatibleCorpus(RecallCorpus.load("recall-corpus-v4"), into: fixture.session.directory)
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        let entries = try await fixture.memory.perform { repositories in
            try await repositories.store.read { handle in
                try handle.query("""
                    SELECT r.route_uuid, count(*) FROM memory_recall_entries e
                        JOIN memory_routes r ON r.route_id = e.route_id
                        JOIN memory_recall_generations g ON g.generation_id = e.generation_id
                        WHERE g.status = 'ready' GROUP BY e.route_id
                    """, []) { (try $0.text(0) ?? "", Int($0.integer(1) ?? 0)) }
            }
        }
        let facts = try await fixture.memory.perform { try await $0.procedures.admissibility(of: entries.map(\.0)) }
        let channels = Set(AgentTool.allCases.map(\.rawValue))
        let supported = facts.filter { !$0.value.fromFailedAttempt && $0.value.channels.isSubset(of: channels) }
        let families = Array(Set(supported.values.map(\.family))).sorted {
            ($0.bundleID, $0.rootRouteUUID) < ($1.bundleID, $1.rootRouteUUID)
        }
        let admitted = Set(families.prefix(3))
        let blocked = Set(facts.values.map(\.family)).subtracting(admitted)
        let valid = Set(supported.filter { admitted.contains($0.value.family) }.keys)
        #expect(valid.count == 3)
        #expect(entries.filter { !valid.contains($0.0) }.map(\.1).reduce(0, +) > RecallContract.candidateLimit)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: "Export the document")
        _ = try await service.prepare(request, availableChannels: channels, doNotUse: blocked)
        let reads = await service.admissibilityReadCount
        let second = try await service.prepare(request, availableChannels: channels, doNotUse: blocked)
        #expect(Set(second.sources.map(\.routeID)) == valid)
        #expect(await service.admissibilityReadCount == reads)
        await fixture.close()
    }

    @Test func compactOffersDoNotBindTaskValues() async throws {
        let fixture = try await Fixture(learn: true)
        let route = try #require(try P.rows("SELECT r.route_uuid FROM memory_procedure_versions v JOIN memory_routes r ON r.route_id = v.route_id", in: fixture.session).first)
        let source = try #require(try await fixture.memory.perform { try await $0.recall.sources([route]) }.first)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: source.procedureLabel,
            values: [try TaskValue(name: "output_name", kind: .text, content: .text("private-new-name"), source: .request)])
        let proposals = try await RecallService.shared(for: fixture.memory).proposeRows(request,
            producer: fixture.owner, access: .readLearn, availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        let parts = try #require(proposals.first?.parts)
        #expect(!parts.isEmpty)
        let summaries = RecallRendering.summaries([.init(row: .init(rawValue: "r1"), parts: parts)],
            texts: ModelText.recallRenderingTexts)
        #expect(summaries.allSatisfy { !$0.text.contains("private-new-name") && $0.text.count <= 320 })
        #expect(summaries.contains { $0.text.contains("{output_name}") })
        await fixture.close()
    }

    @Test func guideTextCannotDeclareAnUndeliveredOffer() async throws {
        let fixture = try await Fixture(learn: true)
        let route = try #require(try P.rows("SELECT r.route_uuid FROM memory_procedure_versions v JOIN memory_routes r ON r.route_id = v.route_id", in: fixture.session).first)
        let source = try #require(try await fixture.memory.perform { try await $0.recall.sources([route]) }.first)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: source.procedureLabel)
        let proposals = try await RecallService.shared(for: fixture.memory).proposeRows(request,
            producer: fixture.owner, access: .readLearn, availableChannels: Set(AgentTool.allCases.map(\.rawValue)))
        let part = try #require(proposals.first?.parts.first)
        let row = TodoRow(id: .init(rawValue: "r1"), title: source.procedureLabel, app: "com.apple.Preview")
        let text = try #require(RecallRendering.summaries([.init(row: row.id, parts: [part])],
            texts: ModelText.recallRenderingTexts).first?.text)
        let guide = try AppGuide.parse("""
            ---
            {"app":"com.apple.Preview","locale":"en","revision":1,"name":"Guide","description":"Reference"}
            ---
            r1: \(text)
            Reference information.
            """)
        fixture.handler.appGuides = AppGuides(guides: [guide], search: GuideSearch(guides: [guide]),
            estimateTokens: TokenEstimate.tokens(in:), similarity: { _, _ in 0 })
        fixture.handler.resolveGuideApp = { OpenedApp(bundleID: $0, version: nil, locale: "en") }
        fixture.handler.planMemoryBudget = 1
        let answer = await fixture.handler.deliverMemory(for: [row], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(answer["memory"]?.string?.contains(text) == true)
        #expect(fixture.handler.rowMemory[row.id]?.parts.isEmpty == true)
        await fixture.close()
    }

}

extension RecallPlanFlowTests {
    @Test func pendingStopRefusesCompletedEnd() async throws {
        let fixture = try await Fixture()
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Export")
        let revision = TodoRevision(taskID: fixture.task.taskID, number: 1, change: .drafted,
            rows: [row], recordedAtMS: 1)
        try await fixture.handler.append(revision, memory: fixture.memory)
        fixture.handler.markTaskInterrupted(producer: fixture.handler.producer)
        let request = try EndRequest(.object(["outcome": .string("completed")]), minimization: .init())
        do {
            _ = try await fixture.handler.end(request)
            Issue.record("Recorded completion during Stop")
        } catch let failure as MemoryTaskTool.Failure {
            #expect(failure.code == "task_interrupted")
        }
        #expect(fixture.handler.openTask != nil)
        await fixture.close()
    }

    @Test(arguments: [StopCause.person, .signal(15), .conversationEnded])
    func stopCauseIsKeptInLastState(_ cause: StopCause) async throws {
        let fixture = try await Fixture()
        fixture.handler.producer = CallProducer(source: .app, streamID: "plan-test")
        try await fixture.handler.append(TodoRevision(taskID: fixture.task.taskID, number: 1, change: .drafted,
            rows: [.init(id: .init(rawValue: "r1"), title: "Export")], recordedAtMS: 1), memory: fixture.memory)
        let stopped = try #require(try await fixture.handler.closeStoppedTask(cause))
        let state = try #require(stopped.lastState)
        switch cause {
        case .person: #expect(state.contains("person"))
        case .signal: #expect(state.contains("signal"))
        case .conversationEnded: #expect(state.contains("conversation"))
        }
        let notes = try P.rows("SELECT note FROM memory_task_checkpoints", in: fixture.session)
        #expect(notes.contains(state))
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func guideIsDeliveredOnceForOpenRows() async throws {
        let fixture = try await Fixture()
        let guide = try AppGuide.parse("""
            ---
            {"app":"com.apple.Preview","locale":"en","revision":1,"name":"Guide","description":"Reference"}
            ---
            A canvas holds the image.
            Inspect the toolbar before exporting.
            """)
        fixture.handler.appGuides = AppGuides(guides: [guide], search: GuideSearch(guides: [guide]),
            estimateTokens: TokenEstimate.tokens(in:), similarity: { _, _ in 0 })
        fixture.handler.resolveGuideApp = { OpenedApp(bundleID: $0, version: nil, locale: "en") }
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Export", app: "com.apple.Preview")
        fixture.handler.todo = Todo(taskID: fixture.task.taskID, revision: 1, rows: [row])
        let first = await fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        let second = await fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(first["memory"]?.string?.contains("A canvas") == true)
        #expect(second["memory"]?.string?.contains("A canvas") != true)
        fixture.handler.forgetDeliveredMemory()
        var closed = row
        closed.status = .abandoned
        fixture.handler.todo = Todo(taskID: fixture.task.taskID, revision: 2, rows: [closed])
        let third = await fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory)
        #expect(third["memory"]?.string?.contains("A canvas") != true)
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func stopBetweenReviseAndAssignmentCannotRestoreTask() async throws {
        let fixture = try await Fixture()
        fixture.handler.producer = CallProducer(source: .app, streamID: "plan-test")
        try await fixture.handler.append(TodoRevision(taskID: fixture.task.taskID, number: 1, change: .drafted,
            rows: [.init(id: .init(rawValue: "r1"), title: "Export")], recordedAtMS: 1), memory: fixture.memory)
        var stopped = false
        fixture.handler.planRevisionWritten = {
            stopped = true
            fixture.handler.markTaskInterrupted(producer: fixture.handler.producer)
            _ = try await fixture.handler.closeStoppedTask(.person)
        }
        let request = try PlanRequest(.object(["request": .string("Export a revised document"), "rows": .array([
            .object(["id": .string("r1"), "title": .string("Export")])])]), minimization: .init(), messageRef: nil)
        do {
            _ = try await fixture.handler.plan(request)
            Issue.record("Plan survived Stop")
        } catch is CancellationError {
        }
        fixture.handler.planRevisionWritten = nil
        #expect(stopped)
        #expect(fixture.handler.openTask == nil)
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func admissibilityRefreshesAfterIndexGenerationChanges() async throws {
        let fixture = try await Fixture(learn: true)
        let service = RecallService.shared(for: fixture.memory)
        let request = try RecallRequest(taskID: fixture.task.taskID, attemptID: fixture.task.attemptID,
            revision: 1, reason: .initial, remainingWork: fixture.content.goal)
        let channels = Set(AgentTool.allCases.map(\.rawValue))
        let first = try await service.prepare(request, availableChannels: channels)
        #expect(!first.sources.isEmpty)
        let reads = await service.admissibilityReadCount
        try await fixture.memory.perform { repositories in
            let generation = try await repositories.recall.startGeneration(format: .labelled, spaceID: nil, at: 1)
            try await repositories.recall.enumerate(generation, pageSize: 1000, at: 1)
            try await repositories.recall.promote(generation.generationID, requiringVectors: false, at: 1)
        }
        _ = try await service.prepare(request, availableChannels: channels)
        #expect(await service.admissibilityReadCount > reads)
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func recallFailureLeavesRowsEligibleForRetry() async throws {
        let fixture = try await Fixture()
        fixture.handler.producer = CallProducer(source: .app, streamID: "plan-test")
        try await fixture.handler.append(TodoRevision(taskID: fixture.task.taskID, number: 1, change: .drafted,
            rows: [.init(id: .init(rawValue: "r1"), title: "Export")], recordedAtMS: 1), memory: fixture.memory)
        fixture.session.offered = [.init(name: "Preview", bundleID: P.preview, version: nil, isRunning: true)]
        fixture.session.applicationLookupFailure = RecallCorpus.Failure("synthetic application lookup failure")
        let request = try PlanRequest(.object(["rows": .array([
            .object(["id": .string("r1"), "title": .string("Export"), "app": .string(P.preview)])])]), minimization: .init(), messageRef: nil)
        let failed = try await fixture.handler.plan(request)
        #expect(fixture.session.failedApplicationLookups == 1)
        #expect(failed["recall_error"].string != nil)
        #expect(fixture.handler.deliveredRows.isEmpty)
        fixture.session.applicationLookupFailure = nil
        let retried = try await fixture.handler.plan(request)
        #expect(retried["recall_error"] == .null)
        #expect(fixture.handler.deliveredRows == [.init(rawValue: "r1")])
        #expect(fixture.session.failedApplicationLookups == 1)
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func choiceFailureKeepsRenderedPreview() async throws {
        let fixture = try await Fixture()
        let state = fixture.handler.planMemoryState()
        state.choices = [TaskCycleHandler.PlanChoice(row: .init(rawValue: "r1"), key: "s1",
            steps: "Inspect the current document.", plan: .init(proposalID: "absent", needs: []),
            task: fixture.task, content: fixture.content, owner: fixture.owner, composition: nil)]
        let result = await fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory, state: state)
        #expect(result["memory"]?.string?.contains("Inspect the current document.") == true)
        #expect(result["recall_error"]?.string?.contains("r1:") == true)
        #expect(fixture.handler.deliveredPlanParts.isEmpty)
        await fixture.close()
    }

    @Test func planStateDoesNotLeakAcrossDeliveries() async throws {
        let fixture = try await Fixture()
        let first = fixture.handler.planMemoryState()
        let second = fixture.handler.planMemoryState()
        first.notices = ["First request"]
        second.notices = ["Second request"]
        async let left = fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory, state: first)
        async let right = fixture.handler.deliverMemory(for: [], content: fixture.content,
            task: fixture.task, owner: fixture.owner, memory: fixture.memory, state: second)
        let results = await (left, right)
        #expect(results.0["memory"]?.string == "First request")
        #expect(results.1["memory"]?.string == "Second request")
        await fixture.close()
    }

    @Test func encodedPlanTextCostMatchesCanonicalJSON() throws {
        let samples = ["文書", "a\nb\t\"\\/", String(UnicodeScalar(0x01)), "😀", "\u{2028}"]
        for text in samples {
            let encoded = try JSONValue.canonicalEncoder().encode(JSONValue.string(text))
            #expect(TaskCycleHandler.encodedPlanTextBytes(text) == encoded.count - 2)
        }
    }
}

extension RecallPlanFlowTests {
    @Test func concurrentPlanRevisionsKeepTheirCommittedTask() async throws {
        let fixture = try await Fixture()
        fixture.handler.producer = CallProducer(source: .app, streamID: "plan-test")
        fixture.handler.memoryAccess = SessionProfile.cli.replacing(memory: .off).memoryAccess
        try await fixture.handler.append(TodoRevision(taskID: fixture.task.taskID, number: 1, change: .drafted,
            rows: [.init(id: .init(rawValue: "r1"), title: "Export")], recordedAtMS: 1), memory: fixture.memory)
        var release: CheckedContinuation<Void, Never>?
        var paused = false
        fixture.handler.planRevisionWritten = {
            if !paused {
                paused = true
                await withCheckedContinuation { release = $0 }
            }
        }
        @MainActor func request(_ goal: String) throws -> PlanRequest {
            try PlanRequest(.object(["request": .string(goal), "rows": .array([
                .object(["id": .string("r1"), "title": .string("Export")])])]), minimization: .init(), messageRef: nil)
        }
        let firstRequest = try request("Export one document")
        let secondRequest = try request("Export another document")
        let first = Task { try await fixture.handler.plan(firstRequest) }
        while release == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await fixture.handler.plan(secondRequest)
        }
        while !secondStarted { await Task.yield() }
        release?.resume()
        let results = try await (first.value, second.value)
        fixture.handler.planRevisionWritten = nil
        #expect(results.0["status"].string == "revised")
        #expect(results.1["status"].string == "revised")
        #expect(fixture.handler.openTask?.revision == 3)
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test func continuationSharesTheEncodedPlanBudget() async throws {
        let fixture = try await Fixture(learn: true)
        fixture.handler.producer = CallProducer(source: .app, streamID: "plan-test")
        fixture.handler.planMemoryBudget = 3500
        fixture.handler.stoppedReference = StoppedTask(taskID: "previous", verifiedRows: (1...8).map {
            TodoRow(id: .init(rawValue: "r\($0)"), title: String(repeating: "Verified work ", count: 8), status: .done)
        }, uncertainGesture: false)
        let route = try #require(try P.rows("SELECT route_uuid FROM memory_routes WHERE route_id IN (SELECT route_id FROM memory_procedure_versions)", in: fixture.session).first)
        let source = try #require(try await fixture.memory.perform { try await $0.recall.sources([route]) }.first)
        let request = try PlanRequest(.object(["request": .string(source.procedureLabel), "rows": .array((1...8).map { _ in
            .object(["title": .string(source.procedureLabel), "app": .string("com.apple.Preview")])
        })]), minimization: .init(), messageRef: nil)
        let answer = try await fixture.handler.plan(request)
        #expect(answer["continues"]["task"].string == "previous")
        #expect(answer["memory"].string != nil)
        let bytes = try JSONValue.canonicalEncoder().encode(answer).count
        #expect(bytes <= fixture.handler.planMemoryBudget, "Encoded plan uses \(bytes) bytes")
        await fixture.close()
    }
}

extension RecallPlanFlowTests {
    @Test(arguments: ["", "Delivered guide text"])
    func guideReceiptRequiresDeliveredText(_ text: String) async throws {
        let fixture = try await Fixture()
        let guide = try AppGuide.parse("""
            ---
            {"app":"com.apple.Preview","locale":"en","revision":1,"name":"Guide","description":"Reference"}
            ---
            Inspect the image before exporting.
            The toolbar holds export controls.
            ## Export
            Choose an output format.
            """)
        fixture.handler.appGuides = AppGuides(guides: [guide], search: GuideSearch(guides: [guide]),
            estimateTokens: TokenEstimate.tokens(in:), similarity: { _, _ in 0 })
        let app = OpenedApp(bundleID: "com.apple.Preview", version: nil, locale: "en")
        let call = CallDispatcher.TaskStateCall(tool: "plan")
        CallDispatcher.$taskStateCall.withValue(call) {
            fixture.handler.noteDeliveredGuides(text: text, apps: [app],
                sections: [(app: app, title: "Export")], omittedSections: 0)
        }
        #expect(call.loaded.count == (text.isEmpty ? 0 : 2))
        #expect(fixture.handler.deliveredGuideApps.contains(app.bundleID) == !text.isEmpty)
        await fixture.close()
    }
}
