//
//  Telemetry.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import Foundation
import os

/// TelemetryMetric names the metrics Braus sends. Each is listed, with its attributes, in
/// Documentation/Telemetry.md; a metric that is not there is not sent.
public enum TelemetryMetric {
    /// Tool calls, by `tool` and `outcome`.
    public static let toolCalls    = "braus.tool.calls"
    /// How long a tool call took, in seconds, by `tool`.
    public static let toolDuration = "braus.tool.duration"
    /// Worker turns, by `provider` and `ending`.
    public static let turns        = "braus.turns"
    /// How long a worker turn took, in seconds, by `provider`.
    public static let turnDuration = "braus.turn.duration"
    /// 1 at every export: the app was running.
    public static let appUp        = "braus.app.up"

    static let toolBounds: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]
    static let turnBounds: [Double] = [1, 5, 10, 30, 60, 120, 300, 600, 1800]
}

/// Telemetry is Braus's anonymous usage metrics: what is recorded, and the loop that sends it to the collector
/// once a minute. Nothing is recorded or sent until `start`, which only the app calls, and only when the
/// person and the environment allow it (`TelemetryConfiguration.isEnabled`); the command line, the tests and
/// a check run never start it.
///
/// What a value may say is bounded here, whatever the caller passes: a tool's name is kept only when it reads
/// as one of Braus's tool names, an outcome or an ending only from its closed vocabulary, a provider only from
/// the known ones. No argument, text, path, page, app name or answer is ever recorded.
public enum Telemetry {

    /// The process's recorder.
    public static let recorder = TelemetryRecorder()

    /// Sends one export body; the default posts it with `URLSession`.
    public typealias Send = @Sendable (URLRequest) async throws -> Void

    private static let log = Logger(subsystem: "dev.forte.braus", category: "telemetry")
    private static let loop = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Starts recording and the export loop. A second start while running does nothing.
    public static func start(_ configuration: TelemetryConfiguration, send: @escaping Send = Telemetry.post) {
        loop.withLock { task in
            guard task == nil else { return }
            recorder.start()
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: configuration.interval)
                    guard !Task.isCancelled, let snapshot = recorder.snapshot() else { return }
                    await export(snapshot, configuration: configuration, send: send)
                }
            }
        }
        log.info("Telemetry started; sending to \(configuration.endpoint.absoluteString, privacy: .public)")
    }

    /// Stops the loop and forgets what was recorded: nothing more is sent.
    public static func stop() {
        loop.withLock { task in
            task?.cancel()
            task = nil
        }
        recorder.stop()
    }

    public static var isRunning: Bool { loop.withLock { $0 != nil } }

    // MARK: Recording

    /// The outcome words a tool call is counted under.
    public static let outcomes: Set<String> = [
        "found_acted", "acted_unverified", "acted_noop", "ambiguous", "honest_miss", "refused", "dry_run",
        "ok", "error", "cancelled",
    ]

    /// The providers a turn is counted under: `ModelProvider`'s raw values.
    public static let providers: Set<String> = ["codex", "claudeCode", "anthropic", "gemini", "ollama"]

    /// Counts one tool call and how long it took.
    public static func toolCall(_ tool: String, outcome: String, seconds: Double) {
        guard recorder.isRecording else { return }
        let tool    = toolName(tool)
        let outcome = outcomes.contains(outcome) ? outcome : "ok"
        recorder.add(to: .init(TelemetryMetric.toolCalls, ["tool": tool, "outcome": outcome]))
        recorder.record(seconds, in: .init(TelemetryMetric.toolDuration, ["tool": tool]), bounds: TelemetryMetric.toolBounds)
    }

    /// Counts one worker turn, how it ended (`completed`, `failed` or `cancelled`) and how long it took.
    public static func turn(provider: String, ending: String, seconds: Double) {
        guard recorder.isRecording else { return }
        let provider = providers.contains(provider) ? provider : "other"
        let ending   = ["completed", "failed", "cancelled"].contains(ending) ? ending : "failed"
        recorder.add(to: .init(TelemetryMetric.turns, ["provider": provider, "ending": ending]))
        recorder.record(seconds, in: .init(TelemetryMetric.turnDuration, ["provider": provider]),
                        bounds: TelemetryMetric.turnBounds)
    }

    /// The action outcomes an answer's text may carry as `"status"` or `"outcome"`, in the order they are looked for.
    static let actionOutcomes = ["found_acted", "acted_unverified", "acted_noop", "ambiguous", "honest_miss", "refused",
                                 "dry_run"]

    /// The outcome a tool's answer reports, read from its text without decoding it: the first action outcome
    /// written as its `"status"` or `"outcome"`, else `error` for an answer marked as one, else `ok`. Only the
    /// word is kept; nothing else of the text is.
    public static func outcome(inAnswerText text: String?, isError: Bool) -> String {
        if let text {
            for word in actionOutcomes
            where text.contains("\"status\":\"\(word)\"") || text.contains("\"outcome\":\"\(word)\"") {
                return word
            }
        }
        return isError ? "error" : "ok"
    }

    /// A tool's name as recorded: lower case letters, digits and underscores, at most 48 of them, else `other`.
    static func toolName(_ name: String) -> String {
        let allowed = name.count <= 48 && !name.isEmpty
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        return allowed ? name : "other"
    }

    // MARK: Sending

    /// Posts one snapshot. A failure is logged and dropped: the next snapshot carries the same totals and more.
    static func export(_ snapshot: TelemetryRecorder.Snapshot, configuration: TelemetryConfiguration, send: Send) async {
        var request = URLRequest(url: configuration.endpoint.appending(path: "v1/metrics"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("braus/\(configuration.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = OTLPMetrics.body(snapshot, configuration: configuration)
        do { try await send(request) }
        catch { log.debug("Telemetry export failed: \(String(describing: error), privacy: .public)") }
    }

    /// Posts with an ephemeral session, which keeps no cookie or cache, and fails on any status but 2xx.
    public static let post: Send = { request in
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
    }
}
