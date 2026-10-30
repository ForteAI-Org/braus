import Foundation

/// MCPRouter implements the stdio MCP request surface. Tool execution is injected and serialized:
/// a concurrent caller gets a busy error rather than interleaving application effects.
///
/// The tool list can be replaced while clients are connected (the host's tool set may change). A router built
/// with `announcesToolListChanges` declares `tools.listChanged` and tells every connection when the list
/// changes; without it the capability and the behavior are those of a fixed list.
@MainActor
public final class MCPRouter {
    public typealias Call = @MainActor (String, JSONValue) async throws -> JSONValue
    private var tools: [JSONValue]
    private let call: Call
    private let instructions: String
    private let announcesToolListChanges: Bool
    private var notificationSinks: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var isBusy = false
    private var activeRequestID: JSONValue?
    private var activeCall: Task<JSONValue, any Error>?
    private var preservesActiveCall = false
    public private(set) var isAcceptingTools = true

    public init(
        tools: [JSONValue],
        instructions: String = "Use windows, then open_session. All actions stay on the background Seat. "
            + "Observe after resuming a conversation. Never repeat an unverified action blindly.",
        announcesToolListChanges: Bool = false,
        call: @escaping Call
    ) {
        self.tools = tools
        self.call = call
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

    public func pause() {
        isAcceptingTools = false
        preservesActiveCall = false
        activeCall?.cancel()
    }

    /// Suspends admission for human control without cancelling the admitted call. Late cancellation
    /// notifications from the interrupted provider cannot cut it short. An explicit pause still can.
    public func suspendForHumanIntervention() {
        isAcceptingTools = false
        preservesActiveCall = true
    }

    public func resume() {
        preservesActiveCall = false
        isAcceptingTools = true
    }

    /// Waits for an in-flight call before the owner releases Seat resources.
    public func drain() async {
        while isBusy { try? await Task.sleep(for: .milliseconds(25)) }
    }

    public func handle(_ request: JSONValue) async -> JSONValue? {
        let id = request["id"]
        guard request["jsonrpc"].string == "2.0", let method = request["method"].string else {
            return error(id, -32600, "Invalid JSON-RPC request.")
        }
        if id == .null {
            if method == "notifications/cancelled", !preservesActiveCall,
               request["params"]["requestId"] == activeRequestID {
                activeCall?.cancel()
            }
            return nil
        }
        do {
            let result: JSONValue
            switch method {
            case "initialize":
                let requested = request["params"]["protocolVersion"].string ?? ""
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                result = .object([
                    "protocolVersion": .string(supported.contains(requested) ? requested : "2025-11-25"),
                    "capabilities": .object(["tools": announcesToolListChanges
                        ? .object(["listChanged": .bool(true)]) : .object([:])]),
                    "serverInfo": .object(["name": .string("braus"), "version": .string("0.1.0")]),
                    "instructions": .string(instructions)
                ])
            case "ping": result = .object([:])
            case "tools/list": result = .object(["tools": .array(tools)])
            case "tools/call":
                guard isAcceptingTools else { return error(id, -32000, "Braus is stopping. No further actions accepted.") }
                guard !isBusy else { return error(id, -32000, "Another Braus operation is still running. Observe when it finishes.") }
                guard let name = request["params"]["name"].string,
                      tools.contains(where: { $0["name"].string == name }) else {
                    return error(id, -32602, "Unknown tool.")
                }
                isBusy = true
                activeRequestID = id
                defer { isBusy = false; activeCall = nil; activeRequestID = nil }
                do {
                    let task = Task { try await call(name, request["params"]["arguments"]) }
                    activeCall = task
                    result = try await task.value
                } catch {
                    result = Self.failureResult(error)
                }
            default: return error(id, -32601, "Method not found: \(method)")
            }
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        }
    }

    /// A tool's value as one text item of JSON, and nothing else. No tool declares an output schema, so
    /// the protocol asks for no `structuredContent`, and a client that shows both reads every scene twice.
    public static func toolResult(_ value: JSONValue, isError: Bool = false) -> JSONValue {
        let text: String
        do { text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
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

    /// The result a tool call that threw carries back to the model: the error in its own words, marked
    /// as an error, with the guidance that its effects may be partial.
    public static func failureResult(_ error: any Error) -> JSONValue {
        toolResult(.object([
            "status": .string("error"),
            "message": .string(String(describing: error)),
            "guidance": .string("Effects may be partial. Observe before deciding the next action; do not replay automatically.")
        ]), isError: true)
    }

    private func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
