//
//  ModelToolLoop.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import ModelTransports

/// ParallelSafety admits calls that touch no shared state outside their own result.
public typealias ParallelSafety = @MainActor @Sendable (String, JSONValue) -> Bool

/// ModelToolLoop is Braus's own agent loop for a model provider (§7.1): the
/// turn a command line runs for itself, run here over the provider's transport
/// with the same tools and instructions.
///
/// Each round streams one tool turn, reports its text as one reply block, and
/// runs the calls it made in order, each one's result or failure going back to
/// the model the way the loopback MCP tells a command line. The assistant
/// message that made the calls keeps the provider's record of the round, which
/// its transport sends back instead of rebuilding it. A round without calls
/// ends the turn. A model that cannot call tools is sent none, and
/// instructions that say so.
///
/// Memory across turns is the history the caller passes; within a turn the
/// loop keeps every call and result. `summarize` compacts that history into a
/// summary the caller sends instead. Retryable requests before the first tool get at most two retries.
/// The host supplies tools and system text; this module requires no application or UI types.
@MainActor
public final class ModelToolLoop {

    // ponytail: a fixed ceiling of 100 tool rounds per turn; make it a setting if real work needs more.
    public static let toolRoundLimit = 100

    private let parallelSafe: ParallelSafety
    private var retryDelay: Task<Void, any Error>?
    var waitBeforeRetry: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    private let call: @MainActor (String, JSONValue) async throws -> JSONValue
    private let rejectedToolAttempt: @MainActor (String) -> Void

    /// What a final answer is followed by: the host's request for an uninterpreted learning candidate.
    /// Nil goes on to the end of the turn.
    private let reminder: @MainActor () -> String?

    /// Set by `stop`; checked before each round and each tool call.
    private var isStopRequested = false
    private var preservesObservedFailure = false

    /// The round streaming now, cancelled by `stop`.
    private var round: Task<Round, Never>?

    /// The tools a turn hands its model: those `call` serves.
    private let definitions: [JSONValue]

    /// Whether those tools open web addresses, which the instructions then teach.
    private let offersWeb: Bool

    private let instructions: any LoopInstructionComposing

    /// `call` runs one tool by name and reports its records itself; `definitions` are the tools it serves.
    /// `instructions` supplies the host's system text for each turn.
    public init(
        call        : @escaping @MainActor (String, JSONValue) async throws -> JSONValue,
        reminder    : @escaping @MainActor () -> String? = { nil },
        definitions : [JSONValue],
        offersWeb   : Bool = false,
        instructions: any LoopInstructionComposing,
        parallelSafe: @escaping ParallelSafety = { _, _ in false },
        rejectedToolAttempt: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.call         = call
        self.rejectedToolAttempt = rejectedToolAttempt
        self.reminder     = reminder
        self.definitions  = definitions
        self.offersWeb    = offersWeb
        self.instructions = instructions
        self.parallelSafe = parallelSafe
    }

    /// The window a loop turn on `selection` runs in: the `num_ctx` Braus sends
    /// Ollama, else what the provider's catalogue states for the model, and nil
    /// when it states none.
    public static func contextWindow(
        of selection: ModelSelection,
        settings    : ProviderSettings,
        catalogue   : [ModelInfo]
    ) -> Int? {
        guard selection.provider != .ollama else { return settings.ollamaContextTokens }
        return catalogue.first { $0.id == selection.model }?.contextWindow
    }

    /// Runs one turn and reports its events in order: each round's text as one
    /// `.assistant` block, the tools' records as they run them, then
    /// `.completed`. The text a round delivered stays reported even when the
    /// round then fails or is stopped.
    ///
    /// What the rounds that completed cost comes last, however the turn ends,
    /// as one `.usage`: their counts added up, the context the last of them
    /// left (its input and output), and `contextWindow`. A turn whose provider
    /// reported no count reports none.
    ///
    /// `seat`, Braus's seat line, goes ahead of `prompt` when the model can
    /// call tools; one without tools is told it cannot use apps.
    ///
    /// `baseTools` are the tools the host serves this turn, and `instructions` is their base text.
    ///
    /// Throws `CancellationError` after `stop`, once a tool call in flight has
    /// finished; the transport's failure, in the provider's words; or a failure
    /// naming `toolRoundLimit` when the model keeps calling tools.
    public func run(
        transport    : any ModelTransport,
        role         : String?,
        history      : [TurnMessage],
        prompt       : String,
        seat         : String? = nil,
        contextWindow: Int? = nil,
        baseTools    : [JSONValue]? = nil,
        instructions : String,
        onEvent      : @escaping @MainActor (ProviderEvent) -> Void
    ) async throws {
        let hasTools = try await transport.capabilities().supportsTools
        let offered  = try Self.toolDefinitions(baseTools ?? definitions)
        let tools    = hasTools ? offered : []
        var messages = [TurnMessage(
            role: .system,
            text: self.instructions.systemText(
                role      : role,
                hasTools  : hasTools,
                tools     : instructions
            )
        )]
        messages += history
        let asked = if hasTools, let seat { seat + "\n\n" + prompt } else { prompt }
        messages.append(TurnMessage(
            role: .user,
            text: asked
        ))

        var spent  : ProviderUsage.Tokens?
        var context: Int?
        defer {
            if let spent {
                onEvent(.usage(ProviderUsage(
                    tokens       : spent,
                    contextTokens: context,
                    contextWindow: contextWindow
                )))
            }
        }

        var anyToolRan = false
        var toolRounds = 0
        while true {
            if isStopRequested { throw CancellationError() }

            let reply = try await request(
                transport: transport,
                messages: messages,
                tools: tools,
                anyToolRan: anyToolRan
            )

            if let usage = reply.usage, usage.inputTokens != nil || usage.outputTokens != nil {
                let counted = Self.tokens(of: usage)
                spent   = (spent ?? ProviderUsage.Tokens()) + counted
                context = usage.inputTokens == nil ? nil : counted.input + counted.output
            }

            let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onEvent(.assistant(text)) }
            if preservesObservedFailure, let failure = reply.failure, !(failure is CancellationError) {
                throw failure
            }
            if isStopRequested { throw CancellationError() }
            if let failure = reply.failure { throw failure }
            guard !reply.calls.isEmpty else {
                // A candidate left uninterpreted is never learned: one more round asks for it, as `braus chat` does.
                if hasTools, let asked = reminder() {
                    onEvent(.activity(asked))
                    messages.append(TurnMessage(role: .assistant, text: reply.text, record: reply.record))
                    messages.append(TurnMessage(role: .user, text: asked))
                    continue
                }
                onEvent(.completed)
                return
            }
            guard toolRounds < Self.toolRoundLimit else {
                throw AutomationFailure("The model kept calling tools after \(Self.toolRoundLimit) rounds in one "
                                        + "response, so Braus stopped it. Review the app before continuing.")
            }

            toolRounds += 1
            messages.append(TurnMessage(
                role     : .assistant,
                text     : reply.text,
                toolCalls: reply.calls,
                record   : reply.record
            ))
            anyToolRan = true
            messages += try await results(of: reply.calls)
        }
    }

    // MARK: Compaction

    /// What the summary call is told it is for.
    public static let summaryInstructions = "You summarize a conversation between a person and an assistant, so "
        + "the assistant can go on from the summary alone."

    /// What the summary call asks for, after the history.
    public static let summaryRequest = "Summarize the conversation so far for yourself to continue from: the "
        + "person's goals, the decisions made, the current state of the work, and the open items. Be "
        + "concise, a few hundred words at most, and write only the summary."

    /// What a later turn is sent before a summary, in place of the messages it replaced.
    public static let summaryPreface = "Summary of the conversation before this point, which replaces it:\n\n"

    /// Asks the model for a summary of `history`, which a later turn is sent
    /// in place of it, in one call with no tools, so it needs no desktop.
    /// Returns the summary and what the call cost when the provider counted it:
    /// its input is the context before, its output the summary's size.
    ///
    /// Throws `CancellationError` after `stop`, the transport's failure, or a
    /// failure when the model wrote no summary. It is never retried.
    public func summarize(
        transport: any ModelTransport,
        history  : [TurnMessage]
    ) async throws -> (summary: String, tokens: ProviderUsage.Tokens?) {
        var messages = [TurnMessage(
            role: .system,
            text: Self.summaryInstructions
        )]
        messages += history
        messages.append(TurnMessage(
            role: .user,
            text: Self.summaryRequest
        ))

        if isStopRequested { throw CancellationError() }
        let stream = try transport.converse(
            messages,
            tools  : [],
            timeout: transport.requestTimeout
        )
        let task = Task { await Self.collect(stream) }
        round = task
        let reply = await task.value
        round = nil

        if preservesObservedFailure, let failure = reply.failure, !(failure is CancellationError) {
            throw failure
        }
        if isStopRequested { throw CancellationError() }
        if let failure = reply.failure { throw failure }
        let summary = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AutomationFailure("The model returned an empty summary.") }

        let counted = reply.usage.flatMap { $0.inputTokens != nil || $0.outputTokens != nil ? $0 : nil }
        return (summary, counted.map(Self.tokens(of:)))
    }

    /// Stops the running turn: the round streaming now is cancelled and no
    /// further tool call starts. A call already running finishes, and `run`
    /// then throws.
    public func stop() {
        preservesObservedFailure = false
        isStopRequested = true
        round?.cancel()
        retryDelay?.cancel()
    }

    /// Interrupts generation and backoff for a human episode. A retryable failure before any tool
    /// becomes suspension; other observed failures retain the host's ordinary failure-cleanup path.
    public func suspendForHumanIntervention() {
        stop()
        preservesObservedFailure = true
    }

    // MARK: Rounds

    /// Requests only the model again; no tool or tool result is replayed.
    private func request(
        transport: any ModelTransport,
        messages: [TurnMessage],
        tools: [ToolDefinition],
        anyToolRan: Bool
    ) async throws -> Round {
        var attempt = 1
        while true {
            if isStopRequested { throw CancellationError() }
            let task = Task {
                if isStopRequested { return Round(failure: CancellationError()) }
                do {
                    return await Self.collect(try transport.converse(
                        messages, tools: tools, timeout: transport.requestTimeout
                    ))
                } catch { return Round(failure: error) }
            }
            round = task
            let reply = await task.value
            round = nil
            guard let failure = reply.failure else { return reply }
            let decision = RequestRetry.decide(
                RequestRetry.classify(failure), attempt: attempt,
                anyToolRan: anyToolRan, isSuspended: preservesObservedFailure
            )
            switch decision {
            case .suspend: return reply.interrupted()
            case .fail: return reply
            case .retry(let delay):
                if isStopRequested { return reply.interrupted() }
                let waiting = Task { try await waitBeforeRetry(delay) }
                retryDelay = waiting
                defer { retryDelay = nil }
                do { try await waiting.value }
                catch {
                    if isStopRequested { return reply.interrupted() }
                    throw error
                }
                if isStopRequested { return reply.interrupted() }
                attempt += 1
            }
        }
    }

    /// Runs consecutive admitted calls together and restores the model's requested order.
    /// An unadmitted call is a barrier; the default admission keeps every call sequential.
    func results(of calls: [ToolCall]) async throws -> [TurnMessage] {
        var results: [TurnMessage] = []
        var index = 0
        while index < calls.count {
            if isStopRequested { throw CancellationError() }
            guard admits(calls[index]) else {
                results.append(await result(of: calls[index]))
                index += 1
                continue
            }
            let start = index
            while index < calls.count, admits(calls[index]) { index += 1 }
            let group = Array(calls[start..<index])
            let tasks = group.map { call in
                Task { @MainActor () -> TurnMessage? in
                    if self.isStopRequested { return nil }
                    return await self.result(of: call)
                }
            }
            var ordered: [TurnMessage] = []
            var interrupted = false
            for task in tasks {
                if let answer = await task.value { ordered.append(answer) }
                else { interrupted = true }
            }
            if interrupted { throw CancellationError() }
            results += ordered
        }
        return results
    }

    private func admits(_ call: ToolCall) -> Bool {
        guard let arguments = try? JSONDecoder().decode(JSONValue.self, from: call.arguments) else { return false }
        return parallelSafe(call.name, arguments)
    }

    /// What one round delivered: its text, its calls, the provider's record of it, what it cost when
    /// it completed, and the failure that ended it early, if any.
    private struct Round: Sendable {
        var text   = ""
        var calls  : [ToolCall] = []
        var record : TurnRecord?
        var usage  : ModelUsage?
        var failure: (any Error)?

        func interrupted() -> Self {
            var reply = self
            reply.failure = CancellationError()
            return reply
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<TurnEvent, any Error>) async -> Round {
        var round = Round()
        do {
            for try await event in stream {
                switch event {
                case .delta(let text):       round.text += text
                case .toolCall(let call):    round.calls.append(call)
                case .record(let record):    round.record = record
                case .completed(let usage):  round.usage = usage
                }
            }
        } catch {
            round.failure = error
        }
        return round
    }

    /// A round's counts, with the cache reads and writes a provider counts apart from its input
    /// added to it, so `input` is everything the model read.
    static func tokens(of usage: ModelUsage) -> ProviderUsage.Tokens {
        let reads  = usage.cacheReadTokens ?? 0
        let writes = usage.cacheWriteTokens ?? 0
        return ProviderUsage.Tokens(
            input      : (usage.inputTokens ?? 0) + reads + writes,
            cacheReads : reads,
            cacheWrites: writes,
            cacheWritesHour: usage.cacheWriteHourTokens ?? 0,
            output     : usage.outputTokens ?? 0,
            reasoning  : usage.reasoningTokens ?? 0
        )
    }

    /// Definitions as a model provider takes them, each with its schema.
    static func toolDefinitions(_ definitions: [JSONValue]) throws -> [ToolDefinition] {
        try definitions.map { definition in
            ToolDefinition(
                name       : definition["name"].string ?? "",
                description: definition["description"].string ?? "",
                parameters : try JSONValue.canonicalEncoder().encode(definition["inputSchema"])
            )
        }
    }

    /// The tool's answer as the model reads it: the text of the MCP result, and
    /// on a thrown error the same failure result `MCPRouter` gives a command line.
    private func result(
        of toolCall: ToolCall
    ) async -> TurnMessage {
        let result: JSONValue
        var decoded = false
        do {
            let arguments = try JSONDecoder().decode(
                JSONValue.self,
                from: toolCall.arguments
            )
            decoded = true
            result = try await call(
                toolCall.name,
                arguments
            )
        } catch {
            if !decoded { rejectedToolAttempt(toolCall.name) }
            result = MCPRouter.failureResult(error)
        }

        var text = (result["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
        if (text.isEmpty || result["_meta"]["braus/content-complete"].bool != true), result["structuredContent"] != .null, let data = try? JSONValue.canonicalEncoder().encode(result["structuredContent"]) {
            text += "\n" + String(decoding: data, as: UTF8.self)
        }
        return TurnMessage(
            result : text,
            of     : toolCall,
            isError: result["isError"].bool == true
        )
    }
}
