//
//  ChatEvidence.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import ChatCore
import Foundation
import LocalMCP
import Memory
import SQLiteMemory

/// ChatEvidence keeps what a script's run leaves for a reader, in one folder per run: the preflight's answer and
/// verdict, and per request a folder with the request, the conversation as saved (every tool line complete), the
/// tasks it named, each task's diagnosis as `braus memory --task` prints it, and a summary with the times, the
/// outcome and the provider's token counts when it gave them. Nothing of it is sent anywhere.
@MainActor
final class ChatEvidence {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The preflight's answer and verdict.
    func preflight(found: JSONValue, differences: [ChatScript.Difference]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(found).write(to: directory.appendingPathComponent("preflight.json"), options: .atomic)
        let verdict = differences.isEmpty ? "ok: the process matches the expectation\n"
            : differences.map(\.description).joined(separator: "\n") + "\n"
        try verdict.write(to: directory.appendingPathComponent("preflight.txt"), atomically: true, encoding: .utf8)
    }

    /// One request's evidence, in `NN/`: the request, the conversation (whole, so a request that continues one holds
    /// the turns before it too), the tasks and their diagnoses, the summary. The summary says, in fields a run of many
    /// tasks reads without parsing words: where a failure came from (`failure`: the provider with its kind, a signal,
    /// or Braus), what the archive holds of each task the request named (`task_states`: status, versions, candidates no
    /// interpretation took, Braus's verdict on the result), the task Braus closed itself (`braus_closed`), the candidate it
    /// interpreted itself because the agent did not (`braus_interpreted`), the agent's own
    /// calls and its longest run of identical ones (`repeated_calls`, shown, never acted on), and the request's tokens.
    func record(number: Int, request: String, continues: Bool, transcript: ChatTranscript, started: Date, ended: Date,
                failure: (any Error)?, signal: Int32? = nil, abandonment: ChatSession.Abandonment?,
                brausInterpreted: String? = nil, toolCalls: Int, agentEntries: Int? = nil, memoryFlushed: Bool,
                archive: URL) throws {
        let folder = directory.appendingPathComponent(String(format: "%02d", number), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (request + "\n").write(to: folder.appendingPathComponent("request.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript.conversation).write(to: folder.appendingPathComponent("conversation.json"), options: .atomic)
        var tasks = ChatScript.taskIDs(in: transcript.conversation.entries)
        if let abandonment, !tasks.contains(abandonment.task) { tasks.append(abandonment.task) }
        try (tasks.joined(separator: "\n") + (tasks.isEmpty ? "" : "\n"))
            .write(to: folder.appendingPathComponent("tasks.txt"), atomically: true, encoding: .utf8)
        var diagnoses: [String: String] = [:]
        for task in tasks {
            let text: String
            switch SQLiteMemoryInspection.task(task, in: archive) {
                case .found(let inspection): text = inspection.text.joined(separator: "\n")
                case .notFound:              text = "no task \(task) in \(archive.path)"
                case .unavailable(let why):  text = "the task was not read: \(why)"
            }
            diagnoses[task] = text
            try (text + "\n").write(to: folder.appendingPathComponent("task-\(task).txt"), atomically: true, encoding: .utf8)
        }
        let formatter = ISO8601DateFormatter()
        let outcome = signal != nil ? "interrupted" : failure == nil ? "ok" : "error"
        var summary: [String: Any] = [
            "request": number, "conversation": transcript.conversation.id.uuidString, "continues_previous": continues,
            "provider": transcript.conversation.provider.rawValue, "model": transcript.conversation.model ?? "provider default",
            "started_at": formatter.string(from: started), "ended_at": formatter.string(from: ended),
            "duration_s": ended.timeIntervalSince(started), "outcome": outcome,
            "tasks": tasks, "memory_flushed": memoryFlushed, "tool_calls": toolCalls,
            "assistant_messages": transcript.conversation.entries.filter { $0.kind == .assistant }.count,
            "repeated_calls": Self.longestRepeat(in: Array(transcript.conversation.entries.prefix(agentEntries ?? .max))),
        ]
        summary["error"] = failure.map { transcript.shown($0.localizedDescription) }
            ?? (signal.map { "stopped by signal \($0)" } ?? NSNull())
        // The provider's subtype is its own free text: its copy here is withheld as the transcript's texts are.
        var failed = Self.failure(failure, signal: signal)
        if let subtype = failed?["subtype"] as? String { failed?["subtype"] = transcript.shown(subtype) }
        summary["failure"] = failed ?? NSNull()
        summary["braus_closed"] = abandonment.map { closed -> [String: Any] in
            ["task": closed.task, "closed": closed.closed, "problem": closed.problem ?? NSNull()]
        } ?? NSNull()
        summary["task_states"] = Self.states(of: tasks, in: archive)
        summary["braus_interpreted"] = brausInterpreted ?? NSNull()
        if let tokens = transcript.requestTokens {
            summary["tokens"] = ["input": tokens.input, "cache_reads": tokens.cacheReads, "cache_writes": tokens.cacheWrites,
                                 "output": tokens.output, "reasoning": tokens.reasoning, "session_total": false]
        } else {
            summary["tokens"] = NSNull()
        }
        if let limits = transcript.lastUsage?.rateLimits, !limits.isEmpty {
            summary["rate_limits"] = limits.map { limit -> [String: Any] in
                ["window": limit.window, "used": limit.usedFraction,
                 "resets_at": limit.resetsAt.map(formatter.string(from:)) ?? NSNull()]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
    }

    /// Where a request's failure came from, in fields: the provider (with the kind it stated, whether a retry may
    /// succeed with nothing changed, its HTTP status, subtype and exit status), a stop by signal, or Braus itself.
    static func failure(_ error: (any Error)?, signal: Int32?) -> [String: Any]? {
        if let signal { return ["source": "signal", "signal": Int(signal), "retryable": true] }
        guard let error else { return nil }
        guard let provider = error as? ProviderFailure else {
            return ["source": "braus", "kind": "error", "retryable": false]
        }
        var object: [String: Any] = ["source": "provider", "kind": provider.kind.rawValue, "retryable": provider.retryable]
        object["api_status"] = provider.apiStatus ?? NSNull()
        object["subtype"] = provider.subtype ?? NSNull()
        object["exit_status"] = provider.exitStatus.map(Int.init) ?? NSNull()
        object["resets_at"] = provider.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        return object
    }

    /// What the archive holds of each task: its status, versions, candidates and those no interpretation took, and
    /// Braus's verdict on its result.
    static func states(of tasks: [String], in archive: URL) -> [[String: Any]] {
        guard case .found(let rows) = SQLiteMemoryInspection.tasks(in: archive, ids: tasks) else { return [] }
        return rows.map { row in
            ["task": row.taskID, "status": row.status, "versions": row.versions, "candidates": row.candidates,
             "uninterpreted": row.uninterpreted, "result": row.result, "guards_failed": row.guardsFailed]
        }
    }

    /// The longest run of identical consecutive tool calls (same tool, same arguments) in the conversation, with the
    /// tool: an agent repeating itself, shown for a reader and never acted on.
    static func longestRepeat(in entries: [Conversation.Entry]) -> [String: Any] {
        var best = (count: 0, tool: ""), run = (count: 0, line: "")
        for entry in entries where entry.kind == .tool && entry.text.hasPrefix("→ ") {
            run = entry.text == run.line ? (run.count + 1, run.line) : (1, entry.text)
            if run.count > best.count {
                best = (run.count, String(entry.text.dropFirst(2).prefix { $0 != " " }))
            }
        }
        return ["count": best.count, "tool": best.tool]
    }
}
