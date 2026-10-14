import AutomationRuntime
//
//  ActCommand.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SeatBroker

/// ActFailure is an action that did not land: the process exits non zero once the seat is down.
struct ActFailure: Error, CustomStringConvertible {

    let kind: ActOutcomeKind

    init(_ kind: ActOutcomeKind) { self.kind = kind }

    var description: String { "the action ended \(kind.rawValue)" }
}

/// ActCommand performs one verified action and prints the outcome kind, the sentence, and the scene
/// after acting, so a person sees exactly what a model would be told. With `--seat` the action is the
/// brokered session's own (`BrokeredSeat`), guards included; without it, the foreground engine's.
enum ActCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let arguments = try ActArguments(invocation)
        let request = ActionRequest(
            processID   : application.processIdentifier,
            bundleID    : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName     : application.localizedName ?? "pid \(application.processIdentifier)",
            target      : arguments.target,
            verb        : arguments.verb,
            section     : arguments.section,
            desiredState: arguments.desiredState,
            isDryRun    : invocation.flags.contains("dry-run")
        )
        let kind: ActOutcomeKind
        if invocation.flags.contains("seat") {
            let knowledge = Runtime.knowledgeDirectory(invocation)
            var acted = ActOutcomeKind.refused
            try await BrokeredSeat.withSession(
                application,
                invocation,
                knowledge: knowledge,
                recorder : Runtime.commandLineRecorder(knowledge: knowledge)
            ) { desktop, _ in
                acted = try await perform(
                    request,
                    recorder: Runtime.commandLineRecorder(knowledge: knowledge)
                ) { recorder in
                    try await brokered(request, on: desktop, recorder: recorder)
                }
            }
            kind = acted
        } else {
            let runtime = Runtime(invocation: invocation)
            kind = try await perform(request, recorder: runtime.commandLineRecorder()) { recorder in
                await runtime.engine(
                    recorder         : recorder,
                    allowsDestructive: invocation.flags.contains("allow-destructive")
                ).act(request)
            }
            await runtime.finish()
        }
        let acceptable: Set<ActOutcomeKind> = [.foundActed, .dryRun, .actedNoop]
        if !acceptable.contains(kind) { throw ActFailure(kind) }
    }

    /// The brokered session's act of `request`, made as the call `recorder` records.
    static func brokered(
        _ request : ActionRequest,
        on desktop: BrokeredAutomationSession,
        recorder  : CallRecorder
    ) async throws -> ActOutcome {
        try await CallRecorder.$current.withValue(recorder) {
            try await desktop.act(
                target      : request.target,
                verb        : request.verb,
                section     : request.section,
                desiredState: request.desiredState,
                isDryRun    : request.isDryRun
            )
        }
    }

    /// Acts once through `acting` and ends the call `recorder` records. The action is a call of the
    /// living memory, as an agent's is: confirmed before it acts, ended with its check after. A start
    /// the memory does not confirm acts on nothing; an end it cannot save is reported and throws once
    /// the outcome is printed. `begun` is set for a batch's step, which its batch already started. An
    /// action that throws, such as one the seat refuses, ends its call as failed before the error goes on.
    static func perform(
        _ request: ActionRequest,
        recorder : CallRecorder,
        begun    : Bool = false,
        acting   : (CallRecorder) async throws -> ActOutcome
    ) async throws -> ActOutcomeKind {
        let call = AgentCallRequest.act(target: request.target, verb: request.verb, value: request.desiredState,
                                        section: request.section)
        if !request.isDryRun, !begun {
            do {
                try await recorder.begin(call, app: AppContextIdentity(bundleID: request.bundleID))
            } catch {
                print("refused: Braus's memory did not confirm the action before it could act (\(error)); nothing was done")
                return .refused
            }
        }
        let started = ContinuousClock.now
        let outcome: ActOutcome
        do {
            outcome = try await acting(recorder)
        } catch {
            if !request.isDryRun {
                try? await recorder.end(
                    error is CancellationError ? .cancelled : .failed,
                    result: error is CancellationError ? nil : .error(message: String(describing: error)),
                    tool  : .act
                )
            }
            throw error
        }
        let elapsed = started.duration(to: .now)
        print("\(outcome.kind.rawValue): \(outcome.message)")
        if let scene = outcome.scene {
            print("")
            print(scene.text())
        }
        FileHandle.standardError.write(Data("acted in \(elapsed)\n".utf8))
        if !request.isDryRun {
            try await CommandLineCall.end(recorder, outcome: outcome, tool: .act)
        }
        return outcome.kind
    }
}
