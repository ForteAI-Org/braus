//
//  ScriptedWorkerTransport.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Foundation
import ModelTransports
import Synchronization

/// ScriptedWorkerTransport yields finite scripted rounds without a provider or network request.
/// Unlike the cancellation fixture in ModelToolLoopTests, exhausting this script fails immediately.
/// The mutex protects the cursor because ModelTransport is Sendable; each host owns one per turn.
nonisolated final class ScriptedWorkerTransport: ModelTransport {

    private let script: ScriptedWorkerScript
    private let played = Mutex(0)

    init(script: ScriptedWorkerScript) {
        self.script = script
    }

    var streaming: StreamingSupport { .incremental }
    var roundsPlayed: Int { played.withLock { $0 } }
    var isFinished: Bool { roundsPlayed == script.rounds.count }

    func capabilities() async throws -> ModelCapabilities {
        ModelCapabilities(supportsTools: true)
    }

    func complete(
        prompt : String,
        schema : Data,
        timeout: TimeInterval
    ) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("A worker script has no structured request.")
    }

    func converse(
        _ messages: [TurnMessage],
        tools     : [ToolDefinition],
        timeout   : TimeInterval
    ) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let events = try played.withLock { index in
            guard index < script.rounds.count else { throw ModelTransportError.streamEndedEarly(deltas: 0) }
            let events = script.rounds[index]
            index += 1
            return events
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
