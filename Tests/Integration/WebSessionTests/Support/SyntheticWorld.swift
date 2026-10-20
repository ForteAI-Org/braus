//
//  SyntheticWorld.swift
//  Braus
//

import Foundation
import WebDriver

/// SyntheticWorld answers, for a page without a browser, the commands `WebTabs.evaluate` sends to run one of
/// the engine's scripts in an isolated world: the main frame, the world, its global object, and a call on that
/// object. A synthetic page has one script context, so the world shares the page's globals here; the isolation
/// itself is covered by `WebWorldTests` and the Chrome tier.
enum SyntheticWorld {

    /// The id of the world's global object, which every engine script is called on.
    static let objectID = "braus-world"

    /// The answer to a command that finds the frame or makes the world, nil for any other. `loaderID` names the
    /// document the main frame holds.
    static func answer(_ method: String, _ params: JSONValue, loaderID: String = "loader-1") -> JSONValue? {
        switch method {
            case "Page.getFrameTree":
                return ["frameTree": ["frame": ["id": "main", "loaderId": .string(loaderID)]]]
            case "Page.createIsolatedWorld":
                return ["executionContextId": 1]
            case "Runtime.evaluate" where params["contextId"] != nil:
                return ["result": ["type": "object", "objectId": .string(objectID)]]
            default:
                return nil
        }
    }

    /// The expression a call on the world's global object runs, nil for any other command.
    static func expression(_ method: String, _ params: JSONValue) -> String? {
        guard method == "Runtime.callFunctionOn", params["objectId"]?.stringValue == objectID,
              let function = params["functionDeclaration"]?.stringValue
        else { return nil }
        let arguments = (params["arguments"]?.arrayValue ?? []).map { argument -> String in
            if let value = argument["value"], let data = try? JSONEncoder().encode(value) {
                return String(decoding: data, as: UTF8.self)
            }
            if let object = argument["objectId"]?.stringValue {
                if object.hasPrefix("field-"), let id = Int(object.dropFirst(6)) { return "__node(\(id))" }
                if object.hasPrefix("obj-"), let id = Int(object.dropFirst(4)) { return "__objects[\(id)]" }
            }
            return "null"
        }
        return "(\(function))(\(arguments.joined(separator: ",")))"
    }
}
