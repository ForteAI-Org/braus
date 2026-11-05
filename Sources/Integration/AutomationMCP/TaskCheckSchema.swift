import LocalMCP

/// TaskCheckSchema is the shared shape of declared result predicates, before any reads or writes.
nonisolated enum TaskCheckSchema {
    static let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static var screen: JSONValue { alternatives(includeFiles: false, includeApp: false) }
    static var check: JSONValue { alternatives(includeFiles: true, includeApp: true) }
    static var result: JSONValue {
        .object(["anyOf": .array([check, .object(["type": .string("array"), "items": check,
            "maxItems": .number(8)])])])
    }

    private static func alternatives(includeFiles: Bool, includeApp: Bool) -> JSONValue {
        let app: [String: JSONValue] = includeApp ? ["app": text] : [:]
        func variant(_ fields: [String: JSONValue], _ required: [String]) -> JSONValue {
            var value = object(fields, required: required).object ?? [:]
            value.removeValue(forKey: "type")
            return .object(value)
        }
        func shape(_ fields: [String: JSONValue], _ required: [String]) -> JSONValue {
            variant(app.merging(fields, uniquingKeysWith: { _, new in new }), required)
        }
        let boolean: JSONValue = .object(["type": .string("boolean")])
        var variants = [
            shape(["window": text, "open": boolean], ["window"]),
            shape(["element": text, "present": boolean], ["element"]),
            shape(["element": text, "value": .object(["type": .string("string")])], ["element", "value"]),
            shape(["element": text, "state": .object(["type": .string("string"),
                "enum": .array(["on", "off", "mixed"].map(JSONValue.string))])], ["element", "state"])
        ]
        if includeFiles {
            for key in ["file_written", "file_changed", "file_unchanged", "file_absent", "none"] {
                variants.append(variant([key: text], [key]))
            }
            for key in ["file_moved", "file_copied"] {
                variants.append(variant([key: text, "to": text], [key, "to"]))
            }
            variants.append(variant(["file": text, "contains": text], ["file"]))
            variants.append(variant(["no_other_files": text, "named": .object(["type": .string("array"), "items": text])],
                ["no_other_files", "named"]))
        }
        return .object(["type": .string("object"), "oneOf": .array(variants)])
    }
}
