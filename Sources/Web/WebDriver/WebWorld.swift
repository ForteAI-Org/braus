//
//  WebWorld.swift
//  Braus
//

import Foundation

/// WebWorld is an isolated script world Braus made in the current document of a page's main frame:
/// it shares the page's DOM but none of its JavaScript, so a page that replaces `elementFromPoint`,
/// a prototype's getter or a global changes nothing a script run here reads, and what such a script
/// leaves on `window` stays out of the page's own world.
///
/// The handle is the world's global object, not its execution context id: Chrome can hand the same
/// context id to another renderer process after a navigation, while an object id names one context
/// only. When the document goes, the world goes with it, and a call through the handle is refused
/// with `CDPError.protocolError` before anything runs.
public struct WebWorld: Sendable, Hashable {

    /// The main frame the world lives in.
    public let frameID: String

    /// The document the world was made for: Chrome changes it at every cross-document navigation.
    public let loaderID: String

    /// The world's global object, which each call runs on.
    let objectID: String
}

extension WebPage {

    /// Makes an isolated world named `name` in the main frame's current document.
    ///
    /// The document is read before and after the world's global object is fetched; when it changed in
    /// between, that object may belong to another document, so it is released and the world made again.
    /// Throws `CDPError.malformedResult` when Chrome answers without a frame, a context or an object, or
    /// when the document keeps changing over `attempts` tries.
    public func makeWorld(
        named name: String,
        attempts  : Int = 3
    ) async throws -> WebWorld {
        for _ in 0..<max(1, attempts) {
            let before  = try await mainDocument()
            let created = try await send(
                "Page.createIsolatedWorld",
                ["frameId": .string(before.frameID), "worldName": .string(name)]
            )
            guard let context = created["executionContextId"]?.intValue else {
                throw CDPError.malformedResult(method: "Page.createIsolatedWorld", detail: "no executionContextId")
            }
            let global = try await send(
                "Runtime.evaluate",
                ["expression": "globalThis", "contextId": .number(Double(context))]
            )
            guard let objectID = global["result"]?["objectId"]?.stringValue else {
                throw CDPError.malformedResult(method: "Runtime.evaluate", detail: "no objectId for the world")
            }
            if try await mainDocument() == before {
                return WebWorld(frameID: before.frameID, loaderID: before.loaderID, objectID: objectID)
            }
            // Releasing a handle whose document is gone can only fail with it; either way nothing holds it.
            _ = try? await send("Runtime.releaseObject", ["objectId": .string(objectID)])
        }
        throw CDPError.malformedResult(method: "Page.createIsolatedWorld", detail: "the document kept changing")
    }

    /// Evaluates `expression` in `world` and returns its value by value, awaiting a returned promise.
    /// The expression is what `evaluate` takes, without a trailing semicolon.
    ///
    /// Throws `CDPError.protocolError` when the world's document is gone, in which case nothing ran,
    /// and `CDPError.scriptFailed` with the exception's description when the script throws.
    public func evaluate(
        _ expression  : String,
        in world      : WebWorld,
        timeoutSeconds: Double? = nil
    ) async throws -> JSONValue {
        let answer = try await send(
            "Runtime.callFunctionOn",
            [
                "functionDeclaration": .string("function () {\nreturn (\n" + expression + "\n);\n}"),
                "objectId"           : .string(world.objectID),
                "returnByValue"      : true,
                "awaitPromise"       : true,
            ],
            timeoutSeconds: timeoutSeconds
        )
        if let exception = answer["exceptionDetails"] {
            let detail = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "exception"
            throw CDPError.scriptFailed(detail)
        }
        return answer["result"]?["value"] ?? .null
    }

    /// The main frame and the document it holds now.
    private func mainDocument() async throws -> (frameID: String, loaderID: String) {
        let tree = try await send("Page.getFrameTree")
        guard let frame = tree["frameTree"]?["frame"], let id = frame["id"]?.stringValue,
              let loader = frame["loaderId"]?.stringValue
        else { throw CDPError.malformedResult(method: "Page.getFrameTree", detail: "no main frame") }
        return (id, loader)
    }
}
