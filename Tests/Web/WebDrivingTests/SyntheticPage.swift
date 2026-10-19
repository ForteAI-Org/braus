//
//  SyntheticPage.swift
//  Braus
//

import Foundation
import Synchronization
import WebDriver

/// SyntheticPage is a page of a scripted Chrome over a `CDPTransporting` double: one main frame
/// whose document changes on `navigate()`, isolated worlds that live as long as the document they
/// were made in, and calls on a world's global object that Chrome refuses once that document is gone.
///
/// Every message it receives is recorded. `run` gives the answer of each call that reaches a live
/// world, which counts as having run; a refused call never reaches it. `navigatesAt` names the reads
/// of the frame tree before which the document changes, the way a navigation lands between commands.
final class SyntheticPage: CDPTransporting {

    struct State {
        var sent      : [JSONValue] = []
        var loaderID  = "loader-1"
        var documents = 1
        var contexts  : [Int: String] = [:]
        var objects   : [String: String] = [:]
        var treeReads = 0
        var ran       : [String] = []
        var isClosed  = false
    }

    let incoming: AsyncStream<Data>
    private let feed       : AsyncStream<Data>.Continuation
    private let run        : @Sendable (String) -> JSONValue
    private let navigatesAt: Set<Int>
    private let state      = Mutex(State())

    init(
        navigatesAt: Set<Int> = [],
        run        : @escaping @Sendable (String) -> JSONValue = { _ in ["result": ["type": "string", "value": "ok"]] }
    ) {
        (incoming, feed) = AsyncStream<Data>.makeStream()
        self.navigatesAt = navigatesAt
        self.run         = run
    }

    /// A page on this transport, as `WebBrowser.attach` returns one.
    func page() async -> WebPage {
        WebPage(connection: await CDPConnection(transport: self), targetID: "main", sessionID: "S1")
    }

    var sent: [JSONValue] { state.withLock { $0.sent } }

    /// The function declarations of the calls that ran in a live world, in order.
    var ran: [String] { state.withLock { $0.ran } }

    func methods(_ name: String) -> [JSONValue] { sent.filter { $0["method"]?.stringValue == name } }

    /// Commits a new document in the main frame: every world made before it is gone.
    func navigate() {
        state.withLock { state in
            state.documents += 1
            state.loaderID = "loader-\(state.documents)"
        }
    }

    func send(_ message: Data) throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: message)
        let closed  = state.withLock { state in
            if !state.isClosed { state.sent.append(message) }
            return state.isClosed
        }
        if closed { throw CDPError.connectionClosed(method: message["method"]?.stringValue ?? "") }
        let id     = message["id"] ?? nil
        let params = message["params"] ?? [:]
        switch answer(message["method"]?.stringValue ?? "", params) {
            case .success(let result): feed.yield(Self.frame(["id": id, "result": result]))
            case .failure(let error) : feed.yield(Self.frame(["id": id, "error": ["code": -32000,
                                                                                  "message": .string(error.text)]]))
        }
    }

    func close() {
        state.withLock { $0.isClosed = true }
        feed.finish()
    }

    struct Refusal: Error { let text: String }

    private func answer(_ method: String, _ params: JSONValue) -> Result<JSONValue, Refusal> {
        switch method {
            case "Page.getFrameTree":
                let read = state.withLock { state in
                    state.treeReads += 1
                    return state.treeReads
                }
                if navigatesAt.contains(read) { navigate() }
                let loader = state.withLock { $0.loaderID }
                return .success(["frameTree": ["frame": ["id": "main", "loaderId": .string(loader)]]])
            case "Page.createIsolatedWorld":
                return .success(["executionContextId": .number(Double(state.withLock { state in
                    let context = state.contexts.count + 1
                    state.contexts[context] = state.loaderID
                    return context
                }))])
            case "Runtime.evaluate":
                return state.withLock { state in
                    guard let context = params["contextId"]?.intValue, let document = state.contexts[context],
                          document == state.loaderID
                    else { return .failure(Refusal(text: "Cannot find context with specified id")) }
                    let object = "world-\(context)"
                    state.objects[object] = document
                    return .success(["result": ["type": "object", "objectId": .string(object)]])
                }
            case "Runtime.callFunctionOn":
                let function = params["functionDeclaration"]?.stringValue ?? ""
                let isLive   = state.withLock { state in
                    guard let object = params["objectId"]?.stringValue, state.objects[object] == state.loaderID
                    else { return false }
                    state.ran.append(function)
                    return true
                }
                guard isLive else { return .failure(Refusal(text: "Cannot find context with specified id")) }
                return .success(run(function))
            default:
                return .success([:])
        }
    }

    static func frame(_ value: JSONValue) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0)
        return data
    }
}
