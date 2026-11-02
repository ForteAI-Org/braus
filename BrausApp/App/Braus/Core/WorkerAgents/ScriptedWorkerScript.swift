//
//  ScriptedWorkerScript.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import Foundation
import LocalMCP
import ModelTransports

/// ScriptedWorkerScript reads a JSON array of ordered rounds, for example:
/// `[ {"calls":[{"tool":"status","arguments":{}}]}, {"answer":"Done."} ]`.
/// Every round except the last has a nonempty `calls` array; only the last has an `answer`.
/// Arguments must be objects. At most 100 tool rounds precede the final nonempty answer.
/// Calls run serially through ModelToolLoop; a tool failure is logged and the script continues.
/// A session argument of `$session` uses the last successful earlier round's live session id.
nonisolated struct ScriptedWorkerScript: Sendable {

    let rounds: [[TurnEvent]]

    init(data: Data) throws {
        let json = try JSONDecoder().decode(
            JSONValue.self,
            from: data
        )
        guard let rounds = json.array, !rounds.isEmpty, rounds.count <= 101 else {
            throw AutomationFailure("A worker script needs 1...101 rounds, ending with an answer.")
        }
        let usage = ModelUsage(
            inputTokens : nil,
            outputTokens: nil,
            duration    : .zero
        )
        self.rounds = try rounds.enumerated().map { index, round in
            if index == rounds.count - 1 {
                guard round.object?.count == 1, let answer = round["answer"].string,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AutomationFailure("The last script round must contain only a nonempty answer.")
                }
                return [.delta(answer), .completed(usage)]
            }
            guard round.object?.count == 1, let calls = round["calls"].array, !calls.isEmpty else {
                throw AutomationFailure("Script round \(index + 1) must contain only a nonempty calls array.")
            }
            let events: [TurnEvent] = try calls.enumerated().map { callIndex, call in
                guard call.object?.count == 2, let name = call["tool"].string,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      call["arguments"].object != nil else {
                    throw AutomationFailure("Every scripted call needs a tool name and an arguments object.")
                }
                return .toolCall(ToolCall(
                    id       : "script-\(index + 1)-\(callIndex + 1)",
                    name     : name,
                    arguments: try JSONEncoder().encode(call["arguments"])
                ))
            }
            return events + [.completed(usage)]
        }
    }
}
