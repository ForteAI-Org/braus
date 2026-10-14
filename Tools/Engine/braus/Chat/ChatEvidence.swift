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
    /// the turns before it too), the tasks and their diagnoses, the summary.
    func record(number: Int, request: String, continues: Bool, transcript: ChatTranscript, started: Date, ended: Date,
                failure: String?, memoryFlushed: Bool, archive: URL) throws {
        let folder = directory.appendingPathComponent(String(format: "%02d", number), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (request + "\n").write(to: folder.appendingPathComponent("request.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript.conversation).write(to: folder.appendingPathComponent("conversation.json"), options: .atomic)
        let tasks = ChatScript.taskIDs(in: transcript.conversation.entries)
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
        var summary: [String: Any] = [
            "request": number, "conversation": transcript.conversation.id.uuidString, "continues_previous": continues,
            "provider": transcript.conversation.provider.rawValue, "model": transcript.conversation.model ?? "provider default",
            "started_at": formatter.string(from: started), "ended_at": formatter.string(from: ended),
            "duration_s": ended.timeIntervalSince(started), "outcome": failure == nil ? "ok" : "error",
            "tasks": tasks, "memory_flushed": memoryFlushed,
            "tool_calls": transcript.conversation.entries.filter { $0.kind == .tool && $0.text.hasPrefix("→ ") }.count,
            "assistant_messages": transcript.conversation.entries.filter { $0.kind == .assistant }.count,
        ]
        summary["error"] = failure ?? NSNull()
        if let usage = transcript.lastUsage {
            summary["tokens"] = ["input": usage.tokens.input, "cache_reads": usage.tokens.cacheReads, "cache_writes": usage.tokens.cacheWrites,
                                 "output": usage.tokens.output, "reasoning": usage.tokens.reasoning, "session_total": usage.isSessionTotal]
        } else {
            summary["tokens"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
    }
}
