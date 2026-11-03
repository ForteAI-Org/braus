import Foundation
import LocalMCP

/// SchemaValidation checks the entire supported schema before checking arguments without coercion.
/// Problems carry codes for the caller's text owner, never argument values. Paths contain at most 64 Unicode scalars.
public enum SchemaValidation {
    /// Problem identifies a schema or argument failure without presentation text.
    public struct Problem: Error, Sendable, Equatable {
        public let path: String
        public let code: Code

        fileprivate init(_ path: String, _ code: Code) {
            self.path = SchemaValidation.boundedPath(path)
            self.code = code
        }
    }

    public enum Code: Sendable, Equatable {
        case invalidSchema
        case unsupportedSchemaKeyword(String)
        case schemaTooDeep
        case invalidSchemaType
        case valueNotAllowed
        case expectedType([String])
        case enumMismatch
        case alternativeMismatch(String)
        case requiredArgumentMissing
        case unknownArgument
        case nonFiniteNumber
        case belowMinimum(Double)
        case aboveMaximum(Double)
        case textTooShort, textTooLong, tooFewItems, tooManyItems, duplicateItem
    }

    /// Returns the first schema failure, or the first argument failure in stable property order.
    /// The root has depth zero; schemas nested more than 32 levels are rejected, even if unused.
    public static func firstProblem(_ arguments: JSONValue, schema: JSONValue) -> Problem? {
        schemaProblem(schema, path: "$", depth: 0) ?? problem(arguments, schema: schema, path: "$")
    }

    private static let types: Set<String> = ["object", "array", "string", "boolean", "null", "number", "integer"]
    private static let keywords: Set<String> = [
        "type", "enum", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems",
        "uniqueItems", "items", "properties", "required", "additionalProperties", "anyOf", "oneOf", "allOf",
        "title", "description", "default", "examples"
    ]

    private static func schemaProblem(_ schema: JSONValue, path: String, depth: Int) -> Problem? {
        guard depth <= 32 else { return Problem(path, .schemaTooDeep) }
        if case .bool = schema { return nil }
        guard let fields = schema.object else { return Problem(path, .invalidSchema) }
        for key in fields.keys.sorted() where !keywords.contains(key) {
            return Problem(path, .unsupportedSchemaKeyword(boundedPath(key)))
        }
        if let type = fields["type"] {
            let names: [String]
            if let name = type.string {
                names = [name]
            } else if let array = type.array, !array.isEmpty, array.allSatisfy({ $0.string != nil }) {
                names = array.compactMap(\.string)
            } else {
                return Problem(path, .invalidSchemaType)
            }
            guard Set(names).count == names.count, names.allSatisfy({ types.contains($0) }) else {
                return Problem(path, .invalidSchemaType)
            }
        }
        if let extra = fields["additionalProperties"], extra != .bool(true), extra != .bool(false) {
            return Problem(path, .unsupportedSchemaKeyword("additionalProperties"))
        }
        if let choices = fields["enum"], choices.array?.isEmpty != false {
            return Problem(path, .invalidSchema)
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let bound = fields[key] {
                guard let number = numberValue(bound), number.isFinite else { return Problem(path, .invalidSchema) }
                if key != "minimum" && key != "maximum", number < 0 || number.rounded(.towardZero) != number {
                    return Problem(path, .invalidSchema)
                }
            }
        }
        if let unique = fields["uniqueItems"], unique != .bool(true), unique != .bool(false) {
            return Problem(path, .invalidSchema)
        }
        if let required = fields["required"] {
            guard let array = required.array, array.allSatisfy({ $0.string != nil }),
                  Set(array.compactMap(\.string)).count == array.count else { return Problem(path, .invalidSchema) }
        }
        if let properties = fields["properties"] {
            guard let object = properties.object else { return Problem(path, .invalidSchema) }
            for key in object.keys.sorted() {
                if let child = object[key],
                   let issue = schemaProblem(child, path: propertyPath(path, key), depth: depth + 1) { return issue }
            }
        }
        if let items = fields["items"], let issue = schemaProblem(items, path: path, depth: depth + 1) { return issue }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let alternatives = fields[key] {
                guard let array = alternatives.array, !array.isEmpty else { return Problem(path, .invalidSchema) }
                for child in array {
                    if let issue = schemaProblem(child, path: path, depth: depth + 1) { return issue }
                }
            }
        }
        return nil
    }

    private static func problem(_ value: JSONValue, schema: JSONValue, path: String) -> Problem? {
        if case .bool(let accepts) = schema { return accepts ? nil : Problem(path, .valueNotAllowed) }
        guard let fields = schema.object else { return Problem(path, .invalidSchema) }
        if let type = fields["type"] {
            let names = type.string.map { [$0] } ?? type.array?.compactMap(\.string) ?? []
            if !names.contains(where: { matches(value, type: $0) }) { return Problem(path, .expectedType(names)) }
        }
        if let choices = fields["enum"]?.array, !choices.contains(value) { return Problem(path, .enumMismatch) }
        for keyword in ["anyOf", "oneOf", "allOf"] {
            if let alternatives = fields[keyword]?.array {
                let matches = alternatives.filter { problem(value, schema: $0, path: path) == nil }.count
                let accepts = keyword == "anyOf" ? matches > 0
                    : keyword == "oneOf" ? matches == 1 : matches == alternatives.count
                if !accepts { return Problem(path, .alternativeMismatch(keyword)) }
            }
        }
        switch value {
        case .object(let object):
            return objectProblem(object, schema: schema, path: path)
        case .array(let array):
            return arrayProblem(array, schema: schema, path: path)
        case .number(let number):
            guard number.isFinite else { return Problem(path, .nonFiniteNumber) }
            if let minimum = numberValue(schema["minimum"]), number < minimum { return Problem(path, .belowMinimum(minimum)) }
            if let maximum = numberValue(schema["maximum"]), number > maximum { return Problem(path, .aboveMaximum(maximum)) }
        case .string(let text):
            let length = Double(text.unicodeScalars.count)
            if let minimum = numberValue(schema["minLength"]), length < minimum { return Problem(path, .textTooShort) }
            if let maximum = numberValue(schema["maxLength"]), length > maximum { return Problem(path, .textTooLong) }
        case .bool, .null:
            break
        }
        return nil
    }

    private static func objectProblem(_ object: [String: JSONValue], schema: JSONValue, path: String) -> Problem? {
        let properties = schema["properties"].object ?? [:]
        for key in (schema["required"].array ?? []).compactMap(\.string).sorted() where object[key] == nil {
            return Problem(propertyPath(path, key), .requiredArgumentMissing)
        }
        for key in object.keys.sorted() {
            let childPath = propertyPath(path, key)
            if let child = object[key], let childSchema = properties[key] {
                if let issue = problem(child, schema: childSchema, path: childPath) { return issue }
            } else if schema["additionalProperties"] == .bool(false) {
                return Problem(childPath, .unknownArgument)
            }
        }
        return nil
    }

    private static func arrayProblem(_ array: [JSONValue], schema: JSONValue, path: String) -> Problem? {
        if let minimum = numberValue(schema["minItems"]), Double(array.count) < minimum { return Problem(path, .tooFewItems) }
        if let maximum = numberValue(schema["maxItems"]), Double(array.count) > maximum { return Problem(path, .tooManyItems) }
        if schema["uniqueItems"] == .bool(true) {
            for index in array.indices where array[..<index].contains(array[index]) {
                return Problem("\(path)[\(index)]", .duplicateItem)
            }
        }
        if let items = schema.object?["items"] {
            for (index, item) in array.enumerated() {
                if let issue = problem(item, schema: items, path: boundedPath("\(path)[\(index)]")) { return issue }
            }
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null):
            return true
        case ("number", .number(let number)):
            return number.isFinite
        case ("integer", .number(let number)):
            return number.isFinite && number.rounded(.towardZero) == number
        default:
            return false
        }
    }

    private static func numberValue(_ value: JSONValue) -> Double? {
        if case .number(let number) = value { return number }
        return nil
    }

    private static func boundedPath(_ path: String) -> String {
        String(String.UnicodeScalarView(path.unicodeScalars.prefix(64)))
    }

    private static func propertyPath(_ path: String, _ key: String) -> String {
        var result = path
        guard result.unicodeScalars.count < 64 else { return result }
        result += "."
        for scalar in key.unicodeScalars {
            let escaped = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
            guard result.unicodeScalars.count + escaped.unicodeScalars.count <= 64 else { break }
            result += escaped
        }
        return result
    }
}
