import Foundation

/// MCPRouter implements the stdio MCP request surface. Tool execution is injected and serialized:
/// concurrent callers wait in arrival order rather than interleaving application effects.
///
/// The tool list can be replaced while clients are connected (the host's tool set may change). A router built
/// with `announcesToolListChanges` declares `tools.listChanged` and tells every connection when the list
/// changes; without it the capability and the behavior are those of a fixed list.
@MainActor
public final class MCPRouter {
    public typealias Call = @MainActor (String, JSONValue) async throws -> JSONValue
    private var tools: [JSONValue]
    private let call: Call
    private let rejectedToolAttempt: (@MainActor (String) -> Void)?
    private let instructions: String?
    private let announcesToolListChanges: Bool
    private var notificationSinks: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var isBusy = false
    private var activeRequestID: JSONValue?
    private var activeCall: Task<JSONValue, any Error>?
    private struct QueuedCall {
        let id: JSONValue
        let name: String
        let arguments: JSONValue
        let continuation: CheckedContinuation<JSONValue?, Never>
    }

    private var queue: [QueuedCall] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let personResult: JSONValue

    /// AdmissionState determines whether calls run, return without being sent for human control,
    /// or stop. Human suspension preserves the admitted call, including against late cancellation.
    public enum AdmissionState: Sendable, Equatable {
        case open, suspendedForPerson, stopped
    }

    public private(set) var admission: AdmissionState = .open {
        didSet {
            switch admission {
            case .open: break
            case .suspendedForPerson: answerQueue()
            case .stopped:
                activeCall?.cancel()
                answerQueue()
            }
        }
    }

    public var isAcceptingTools: Bool { admission == .open }

    /// The ES1 outcome for a call withheld because the person took control, without model prose.
    public static let notSentForPerson = toolResult(.object([
        "gesture": .string("not_sent"), "effect": .string("not_applicable"),
        "recovery": .string("do_not_repeat"), "cause": .string("human_intervention")
    ]))

    public init(
        tools: [JSONValue],
        instructions: String?,
        notSentForPerson: JSONValue = MCPRouter.notSentForPerson,
        announcesToolListChanges: Bool = false,
        rejectedToolAttempt: (@MainActor (String) -> Void)? = nil,
        call: @escaping Call
    ) {
        self.tools = tools
        self.personResult = notSentForPerson
        self.call = call
        self.rejectedToolAttempt = rejectedToolAttempt
        self.instructions = instructions
        self.announcesToolListChanges = announcesToolListChanges
    }

    /// Replaces the tools offered from the next `tools/list` and `tools/call` on. A call already running
    /// finishes. When the router announces list changes, every connection receives
    /// `notifications/tools/list_changed`.
    public func replaceTools(_ tools: [JSONValue]) {
        guard tools != self.tools else { return }
        self.tools = tools
        guard announcesToolListChanges else { return }
        let notification: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed"),
        ])
        for sink in notificationSinks.values { sink(notification) }
    }

    /// Where notifications go for one connection, until `removeNotificationSink` with the returned key.
    func addNotificationSink(_ sink: @escaping @MainActor (JSONValue) -> Void) -> UUID {
        let key = UUID()
        notificationSinks[key] = sink
        return key
    }

    func removeNotificationSink(_ key: UUID) { notificationSinks[key] = nil }

    public func pause() { admission = .stopped }

    /// Suspends admission for human control without cancelling the admitted call. Late cancellation
    /// notifications from the interrupted provider cannot cut it short. An explicit pause still can.
    public func suspendForHumanIntervention() { admission = .suspendedForPerson }

    public func resume() { admission = .open }

    /// Waits until the admitted call finishes and every queued call has been answered or cancelled.
    public func drain() async {
        guard isBusy || !queue.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    public func handle(_ request: JSONValue) async -> JSONValue? {
        let id = request["id"]
        guard request["jsonrpc"].string == "2.0", let method = request["method"].string else {
            return error(id, -32600, "Invalid JSON-RPC request.")
        }
        if id == .null {
            if method == "notifications/cancelled" {
                let cancelledID = request["params"]["requestId"]
                if let index = queue.firstIndex(where: { $0.id == cancelledID }) {
                    let cancelled = queue.remove(at: index)
                    rejectedToolAttempt?(cancelled.name)
                    cancelled.continuation.resume(returning: nil)
                    finishDrainIfIdle()
                } else if admission != .suspendedForPerson, cancelledID == activeRequestID {
                    activeCall?.cancel()
                }
            }
            return nil
        }
        do {
            let result: JSONValue
            switch method {
            case "initialize":
                let requested = request["params"]["protocolVersion"].string ?? ""
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                var initialization: [String: JSONValue] = [
                    "protocolVersion": .string(supported.contains(requested) ? requested : "2025-11-25"),
                    "capabilities": .object(["tools": announcesToolListChanges
                        ? .object(["listChanged": .bool(true)]) : .object([:])]),
                    "serverInfo": .object(["name": .string("braus"), "version": .string("0.1.0")])
                ]
                if let instructions { initialization["instructions"] = .string(instructions) }
                result = .object(initialization)
            case "ping": result = .object([:])
            case "tools/list": result = .object(["tools": .array(tools)])
            case "tools/call":
                let attemptedName = request["params"]["name"].string ?? "<unlisted>"
                switch admission {
                case .suspendedForPerson: rejectedToolAttempt?(attemptedName); return response(id, personResult)
                case .stopped: rejectedToolAttempt?(attemptedName); return stoppingError(id)
                case .open: break
                }
                guard let name = request["params"]["name"].string,
                      tools.contains(where: { $0["name"].string == name }) else {
                    rejectedToolAttempt?(attemptedName)
                    return error(id, -32602, "Unknown tool.")
                }
                return await withCheckedContinuation { continuation in
                    queue.append(QueuedCall(
                        id: id, name: name, arguments: request["params"]["arguments"],
                        continuation: continuation
                    ))
                    startNextCall()
                }
            default: return error(id, -32601, "Method not found: \(method)")
            }
            return response(id, result)
        }
    }

    private func startNextCall() {
        guard !isBusy, !queue.isEmpty else { return }
        guard admission == .open else { answerQueue(); return }
        let next = queue.removeFirst()
        guard tools.contains(where: { $0["name"].string == next.name }) else {
            rejectedToolAttempt?(next.name)
            next.continuation.resume(returning: error(next.id, -32602, "Unknown tool."))
            startNextCall()
            finishDrainIfIdle()
            return
        }
        isBusy = true
        activeRequestID = next.id
        let task = Task { try await call(next.name, next.arguments) }
        activeCall = task
        Task {
            let result: JSONValue
            do { result = try await task.value }
            catch { result = Self.failureResult(error) }
            activeCall = nil
            activeRequestID = nil
            isBusy = false
            next.continuation.resume(returning: response(next.id, result))
            startNextCall()
            finishDrainIfIdle()
        }
    }

    private func answerQueue() {
        let waiting = queue
        queue.removeAll()
        for entry in waiting {
            rejectedToolAttempt?(entry.name)
            let answer = admission == .suspendedForPerson
                ? response(entry.id, personResult) : stoppingError(entry.id)
            entry.continuation.resume(returning: answer)
        }
        finishDrainIfIdle()
    }

    private func finishDrainIfIdle() {
        guard !isBusy, queue.isEmpty else { return }
        let waiting = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func response(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func stoppingError(_ id: JSONValue) -> JSONValue {
        error(id, -32000, "Braus is stopping. No further actions accepted.")
    }

    /// A tool's value as one text item of JSON, and nothing else. No tool declares an output schema, so
    /// the protocol asks for no `structuredContent`, and a client that shows both reads every scene twice.
    public static func toolResult(_ value: JSONValue, isError: Bool = false) -> JSONValue {
        let text: String
        do { text = String(decoding: try JSONValue.canonicalEncoder().encode(value), as: UTF8.self) }
        catch { text = "Could not encode tool result: \(error)" }
        return textResult(text, isError: isError)
    }

    /// A tool's answer already written as text, as one text item, for a tool whose answer is not JSON.
    public static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError)
        ])
    }

    /// Carries an answer rendered by Braus as one text content item.
    public static func answerResult(_ text: String, isError: Bool = false) -> JSONValue {
        textResult(text, isError: isError)
    }

    /// The result a tool call that threw carries back to the model: the error in its own words, marked
    /// as an error, with the guidance that its effects may be partial.
    public static func failureResult(_ error: any Error) -> JSONValue {
        let beforeDispatch = (error as? any MCPFailureContext)?.isBeforeDispatch == true
        return toolResult(.object([
            "status": .string("error"),
            "message": .string(String(describing: error)),
            "dispatch": .string(beforeDispatch ? "not_dispatched" : "not_known"),
            "guidance": .string(beforeDispatch ? "Nothing was dispatched. Correct the arguments before trying again."
                : "Effects may be partial. Observe before deciding the next action; do not replay automatically.")
        ]), isError: true)
    }

    private func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
