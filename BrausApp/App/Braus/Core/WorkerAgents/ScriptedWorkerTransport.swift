//
//  ScriptedWorkerTransport.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import Foundation
import LocalMCP
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
            let events = try script.rounds[index].map { event -> TurnEvent in
                guard case .toolCall(let call) = event else { return event }
                var arguments = try JSONDecoder().decode(
                    JSONValue.self,
                    from: call.arguments
                )
                if arguments["session"] == .string("$session") {
                    guard let session = Self.session(in: messages), var fields = arguments.object else {
                        throw AutomationFailure("The script requested $session before a tool returned a live session.")
                    }
                    fields["session"] = .string(session)
                    arguments = .object(fields)
                }
                return .toolCall(ToolCall(
                    id       : call.id,
                    name     : call.name,
                    arguments: try JSONEncoder().encode(arguments)
                ))
            }
            index += 1
            return events
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    /// Resolves only the session argument, from the most recent successful tool answer naming it.
    /// Plain-text answers have no session; a null session invalidates one returned earlier.
    private static func session(in messages: [TurnMessage]) -> String? {
        for message in messages.reversed() where message.role == .tool && !message.isError {
            guard let line = message.text.split(separator: "\n").last,
                  let value = try? JSONDecoder().decode(
                      JSONValue.self,
                      from: Data(line.utf8)
                  ),
                  value.object?["session"] != nil else { continue }
            guard let session = value["session"].string, UUID(uuidString: session) != nil else { return nil }
            return session
        }
        return nil
    }
}
