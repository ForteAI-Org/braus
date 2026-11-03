import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SQLiteMemory
import Testing

// Derived Brain commands retain their writable projection in the historical fixture.
@Suite("MemoryService derived pauses", HistoricalSchema())
struct MemoryServiceTests {
    private func prepare(_ service: MemoryService, _ id: String) async throws -> CaptureSampleKey {
        let key = CaptureSampleKey(eventID: id, phase: .current)
        let window = W.window([W.open])
        await service.openPause(id)
        try await service.perform { repositories in
            let event = ActionContext(eventID: id, source: .app, streamID: "pause", sessionID: "session")
                .event(app: AppContextIdentity(bundleID: W.bundle), occurredAtMS: 100)
            _ = try await repositories.facts.open(try OperationOpening(
                call: AgentCallRecord(event: event, request: .observe(full: false)), startedAtMS: 100
            ))
            _ = try await repositories.facts.conclude(try OperationConclusion(
                end: AgentCallTransition(id, AgentCallProgress(.completed, endedAtMS: 150)),
                samples: [CaptureSample(key: key, of: window)]
            ))
        }
        return key
    }

    private func commands(_ key: CaptureSampleKey) throws -> [MemoryService.DerivedCommand] {
        [.associate(key, atMS: 200), .brainObserve(try BrainApplicationCommand.observe(
            W.window([W.open]).scene, sample: key, requestedAt: Date(timeIntervalSince1970: 0.3)
        )), .brainRelation(callEventID: key.eventID, atMS: 400)]
    }

    @Test
    func pauseWritesInOneTransaction() async throws {
        let service = try W.service()
        let key = try await prepare(service, "one")
        let before = try await service.perform { try await $0.store.diagnostics().commits }
        await service.openPause("one")
        for command in try commands(key) { await service.add(command, to: "one") }
        await service.closePause("one")
        #expect(await service.flush(within: .seconds(5)))
        let after = try await service.perform { try await $0.store.diagnostics().commits }
        #expect(after - before == 1)
        #expect(await service.status().failed == 0)
        await service.close()
    }

    @Test
    func gestureUsesThreeCommits() async throws {
        let service = try W.service()
        _ = try await MemoryExecutor.current(memory: service, source: .app)
        let before = try await service.perform { try await $0.store.diagnostics().commits }
        let recorder = W.recorder(service)
        try await recorder.begin(.act(target: "Open", verb: .click, value: nil, section: nil),
                                 app: AppContextIdentity(bundleID: W.bundle))
        await recorder.record(ActionRecord(
            bundleID: W.bundle, element: W.open, verb: .click, effect: nil, windowTitleAfter: nil,
            before: W.window([W.open]), after: W.window([W.open, W.save])
        ))
        try await recorder.end(.completed, result: .outcome(.foundActed, message: "clicked"), tool: .act)
        #expect(await service.flush(within: .seconds(5)))
        let after = try await service.perform { try await $0.store.diagnostics().commits }
        #expect(after - before == 3)
        #expect(await service.status().failed == 0)
        await service.close()
    }

    @Test
    func noDerivedWorkDuringAction() async throws {
        let service = try W.service()
        let key = try await prepare(service, "open")
        await service.openPause("open")
        await service.add(.associate(key, atMS: 200), to: "open")
        #expect(await service.flush(within: .milliseconds(100)))
        #expect(try await service.perform { try await $0.scenes.associations(of: key) }.isEmpty)
        await service.closePause("open")
        #expect(await service.flush(within: .seconds(5)))
        #expect(try await service.perform { try await $0.scenes.associations(of: key) }.count == 1)
        await service.close()
    }

    @Test
    func pauseInterleaving() async throws {
        let service = try W.service()
        let a = try await prepare(service, "a"), b = try await prepare(service, "b")
        await service.openPause("a")
        await service.add(.associate(a, atMS: 200), to: "a")
        await service.openPause("b")
        await service.closePause("a")
        #expect(await service.flush(within: .seconds(5)))
        #expect(try await service.perform { try await $0.scenes.associations(of: b) }.isEmpty)
        await service.add(.associate(b, atMS: 300), to: "b")
        await service.closePause("b")
        #expect(await service.flush(within: .seconds(5)))
        let scenes = try await service.perform { try await $0.scenes.scenes(of: W.bundle) }
        #expect(scenes.count == 1)
        #expect(await service.status().written == 2)
        await service.close()
    }

    @Test
    func pauseErrorFallsBackToSingles() async throws {
        let service = try W.service()
        let key = try await prepare(service, "valid")
        await service.openPause("error")
        await service.add(.associate(key, atMS: 200), to: "error")
        await service.add(.associate(CaptureSampleKey(eventID: "missing", phase: .current), atMS: 200), to: "error")
        for command in try commands(key).dropFirst() { await service.add(command, to: "error") }
        await service.closePause("error")
        #expect(await service.flush(within: .seconds(5)))
        #expect(try await service.perform { try await $0.scenes.associations(of: key) }.count == 1)
        #expect(try await service.application(.observe(key)) != nil)
        #expect(await service.status().partial == 1)
        await service.close()
    }

    @Test
    func sameRowsGroupedOrNot() async throws {
        let grouped = try W.service(), singles = try W.service()
        let a = try await prepare(grouped, "same"), b = try await prepare(singles, "same")
        await grouped.openPause("same")
        for command in try commands(a) { await grouped.add(command, to: "same") }
        await grouped.closePause("same")
        try await singles.perform { repositories in
            _ = try await repositories.scenes.associate(b, at: 200)
            _ = try await repositories.applications.apply(try BrainApplicationCommand.observe(
                W.window([W.open]).scene, sample: b, requestedAt: Date(timeIntervalSince1970: 0.3)
            ))
            _ = try await repositories.relations.apply(callEventID: b.eventID, at: 400)
        }
        #expect(await grouped.flush(within: .seconds(5)))
        let groupedApplication = try await grouped.application(.observe(a))
        let singleApplication = try await singles.application(.observe(b))
        let groupedResult = try #require(groupedApplication)
        let singleResult = try #require(singleApplication)
        #expect(groupedResult.command.hasSameInput(as: singleResult.command))
        #expect(groupedResult.outcome == singleResult.outcome)
        #expect(groupedResult.effectiveAtMS == singleResult.effectiveAtMS)
        let first = try await grouped.perform { try await $0.relations.application(of: a.eventID) }
        let second = try await singles.perform { try await $0.relations.application(of: b.eventID) }
        #expect(first?.exclusion == second?.exclusion)
        let sceneSQL = "SELECT scene_kind || '/' || structural_key || '/' || first_seen_ms || '/' || last_seen_ms || '/' || observation_count FROM brain_scenes ORDER BY structural_key"
        let groupedScenes = try await grouped.perform { repositories in
            try await repositories.store.read { try $0.query(sceneSQL, []) { try $0.text(0) ?? "" } }
        }
        let singleScenes = try await singles.perform { repositories in
            try await repositories.store.read { try $0.query(sceneSQL, []) { try $0.text(0) ?? "" } }
        }
        #expect(groupedScenes == singleScenes)
        let associationSQL = "SELECT event_id || '/' || phase || '/' || sample_ordinal || '/' || match_status || '/' || matched_by || '/' || matcher_version FROM memory_event_scenes ORDER BY event_id"
        let groupedAssociations = try await grouped.perform { repositories in
            try await repositories.store.read { try $0.query(associationSQL, []) { try $0.text(0) ?? "" } }
        }
        let singleAssociations = try await singles.perform { repositories in
            try await repositories.store.read { try $0.query(associationSQL, []) { try $0.text(0) ?? "" } }
        }
        #expect(groupedAssociations == singleAssociations)
        let evaluationSQL = "SELECT call_event_id || '/' || sequence || '/' || policy_version || '/' || cause || '/' || outcome || '/' || coalesce(reason, '') || '/' || evaluated_at_ms FROM brain_relation_evaluations ORDER BY call_event_id, sequence"
        let groupedEvaluations = try await grouped.perform { repositories in
            try await repositories.store.read { try $0.query(evaluationSQL, []) { try $0.text(0) ?? "" } }
        }
        let singleEvaluations = try await singles.perform { repositories in
            try await repositories.store.read { try $0.query(evaluationSQL, []) { try $0.text(0) ?? "" } }
        }
        #expect(groupedEvaluations == singleEvaluations)
        await grouped.close()
        await singles.close()
    }

    @Test
    func cancelledCallStillClosesPause() async throws {
        let service = try W.service()
        let recorder = W.recorder(service)
        let task = Task {
            try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
            await recorder.holdPauseUntilAnswered()
            _ = await recorder.observe(W.window([W.open]))
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await recorder.end(.cancelled, result: nil, tool: .observe)
            } catch {
                #expect(error is CancellationError || error is EssentialWriteFailure)
            }
            await recorder.answered()
        }
        try await task.value
        try await PauseTestWait.untilWritten(service)
        #expect(await service.flush(within: .seconds(5)))
        #expect(try await service.application(.observe(CaptureSampleKey(eventID: recorder.eventID, phase: .current))) != nil)
        await service.close()
    }
}

/// PauseTestWait observes the asynchronous answer signal without closing the recorder itself.
enum PauseTestWait {
    static func untilWritten(_ service: MemoryService, count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await service.status().written < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await service.status().written >= count)
    }
}
