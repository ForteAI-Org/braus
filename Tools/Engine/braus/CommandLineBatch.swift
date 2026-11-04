//
//  CommandLineBatch.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// CommandLineBatch records a `braus batch` as the tools record a batch: one call with its steps planned
/// at their positions, confirmed before the first gesture; each step started before it acts and ended by
/// its own command, with that command's check; the steps that never ran recorded as skipped once the
/// batch stops; and the batch's end with the summary its steps allow. The batch itself proves nothing:
/// only its steps carry checks. A batch the memory does not confirm does nothing; a step it does not
/// confirm is not run, and stops the batch.
enum CommandLineBatch {

    /// The call a step is, as the contract keeps it.
    static func request(of step: BatchStep) -> AgentCallRequest {
        switch step {
            case .select(let control, let item):
                .select(control: control, item: item)
            case .act(let action):
                .act(target: action.target, verb: action.verb, value: action.desiredState, section: action.section)
        }
    }

    /// Runs `steps` as one recorded batch. `prepare` checks a step before it starts (nothing acts there);
    /// `perform` runs the started step with its recorder, which its command ends.
    @MainActor
    static func run(
        _ steps : [BatchStep],
        app     : AppContextIdentity,
        parent  : CallRecorder,
        children: [CallRecorder],
        entryScene: SceneSnapshot? = nil,
        expectations: [ScreenExpectation?] = [],
        windowNumber: () -> Int? = { nil },
        prepare : (Int, BatchStep) async throws -> SceneSnapshot? = { _, _ in nil },
        perform : (Int, BatchStep, CallRecorder) async throws -> ActOutcome
    ) async throws {
        precondition(children.count == steps.count, "one recorder per step")
        try Task.checkCancellation()
        do {
            try await parent.begin(batch: zip(children, steps).map { ($0, request(of: $1)) }, app: app)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            print("refused: Braus's memory did not confirm the batch before it could act (\(error)); nothing was done")
            throw ActFailure(.refused)
        }
        if entryScene == nil {
            for child in children { try await child.skip() }
            let cancelled = Task.isCancelled
            try await parent.end(cancelled ? .cancelled : .completed,
                result: cancelled ? nil : .batch(stopped: true, attempted: 0, verified: 0),
                tool: .batch, batchConclusion: cancelled ? nil : .stopped(at: 0, reason: .refused))
            if cancelled { throw CancellationError() }
            throw ActFailure(.refused)
        }
        var started = 0, verified = 0
        var stop: (any Error)?
        var conclusion: BatchConclusion?
        if let entryScene {
            let result = try await BatchSequence.runPolicy(steps, expectations: expectations, entryScene: entryScene,
                bundleID: app.bundleID, prepare: { number, step in
                    guard let scene = try await prepare(number, step) else { throw ActFailure(.refused) }
                    return scene
                }, windowNumber: windowNumber) { number, step in
                    try await children[number - 1].startStep()
                    started += 1
                    if Task.isCancelled {
                        try await children[number - 1].end(.cancelled, result: nil, tool: request(of: step).tool)
                        throw CancellationError()
                    }
                    if AutomationCallInterruption.current?.wasInterrupted == true {
                        let refused = ActOutcome(.refused, "person_in_control", notSent: .humanIntervention)
                        try await children[number - 1].end(.completed, result: .outcome(refused.kind, message: refused.message),
                                                         tool: request(of: step).tool)
                        return refused
                    }
                    return try await perform(number, step, children[number - 1])
                }
            verified = result.verified
            conclusion = result.conclusion
            stop = result.failure
            switch result.conclusion {
            case .stopped(_, let reason):
                print("batch: stopped: \(reason.rawValue); attempted \(started), verified \(verified)")
            case .ranToEnd:
                print("batch: completed \(started)/\(steps.count) steps; verified \(verified)")
            }
        }
        for child in children.dropFirst(started) {
            do {
                try await child.skip()
            } catch {
                print("memory: a step that never ran could not be recorded as skipped (\(error))")
            }
        }
        let cancelled = Task.isCancelled
        do {
            try await parent.end(
                cancelled ? .cancelled : .completed,
                result: cancelled ? nil : .batch(stopped: conclusion.map { if case .stopped = $0 { true } else { false } }
                    ?? (started < steps.count || verified < started), attempted: started,
                               verified: verified),
                tool  : .batch,
                batchConclusion: cancelled ? nil : conclusion
            )
            if let gap = await parent.recordingGap { print("memory: part of the batch was not recorded: \(gap)") }
        } catch {
            print("memory: the batch ran, but its record was not saved (\(error)); do not repeat it")
            if stop == nil { stop = CommandLineCall.Unsaved(reason: "\(error)") }
        }
        try Task.checkCancellation()
        if let stop { throw stop }
    }
}
