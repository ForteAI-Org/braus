//
//  WebAXNode.swift
//  Braus
//

import Foundation
import WebDriver

/// WebAXNode is one node of Chrome's accessibility tree as `Accessibility.getFullAXTree` reports
/// it: Chrome's own role names (`button`, `textbox`, `StaticText`...), the computed name and value,
/// and the DOM node its box is measured on.
public struct WebAXNode: Sendable, Equatable {

    public var id           : String
    public var parentID     : String?
    public var childIDs     : [String]
    public var role         : String
    public var name         : String
    public var value        : String?
    public var isIgnored    : Bool
    public var backendNodeID: Int?
    /// The node's properties by name, such as `checked`, `disabled`, `multiline` and `editable`.
    public var properties   : [String: JSONValue]

    public init(
        id           : String,
        parentID     : String? = nil,
        childIDs     : [String] = [],
        role         : String,
        name         : String = "",
        value        : String? = nil,
        isIgnored    : Bool = false,
        backendNodeID: Int? = nil,
        properties   : [String: JSONValue] = [:]
    ) {
        self.id            = id
        self.parentID      = parentID
        self.childIDs      = childIDs
        self.role          = role
        self.name          = name
        self.value         = value
        self.isIgnored     = isIgnored
        self.backendNodeID = backendNodeID
        self.properties    = properties
    }

    /// Reads one node; nil when it has no id.
    public init?(json: JSONValue) {
        guard let id = json["nodeId"]?.stringValue else { return nil }
        var properties: [String: JSONValue] = [:]
        for property in json["properties"]?.arrayValue ?? [] {
            if let name = property["name"]?.stringValue { properties[name] = property["value"]?["value"] ?? .null }
        }
        self.init(
            id           : id,
            parentID     : json["parentId"]?.stringValue,
            childIDs     : (json["childIds"]?.arrayValue ?? []).compactMap(\.stringValue),
            role         : json["role"]?["value"]?.stringValue ?? "",
            name         : json["name"]?["value"]?.stringValue ?? "",
            value        : Self.text(json["value"]?["value"]),
            isIgnored    : json["ignored"]?.boolValue ?? false,
            backendNodeID: json["backendDOMNodeId"]?.intValue,
            properties   : properties
        )
    }

    /// The nodes of a `getFullAXTree` answer, in its order.
    public static func nodes(fromFullTree answer: JSONValue) -> [WebAXNode] {
        (answer["nodes"]?.arrayValue ?? []).compactMap(WebAXNode.init(json:))
    }

    /// A boolean property; nil when absent or not a boolean.
    func flag(_ name: String) -> Bool? {
        properties[name]?.boolValue
    }

    /// A string property, such as `checked`'s `"true"`, `"false"` or `"mixed"`.
    func token(_ name: String) -> String? {
        switch properties[name] {
            case .string(let text)?: text
            case .bool(let flag)?  : flag ? "true" : "false"
            default                : nil
        }
    }

    /// A value Chrome reports as a string or a number, as text.
    private static func text(_ value: JSONValue?) -> String? {
        switch value {
            case .string(let text)?: return text
            case .number(let number)?:
                return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
            default: return nil
        }
    }
}
