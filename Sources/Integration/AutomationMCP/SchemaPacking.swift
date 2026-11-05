import Foundation
import LocalMCP

/// SchemaPacking names repeated same-document schemas without changing their validation rules.
nonisolated enum SchemaPacking {
    static func pack(_ schema: JSONValue) throws -> JSONValue {
        var counts: [String: Int] = [:]
        let encoder = JSONValue.canonicalEncoder()
        func key(_ value: JSONValue) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        func children(_ value: JSONValue, transform: (JSONValue) throws -> JSONValue) rethrows -> JSONValue {
            guard var fields = value.object else { return value }
            if let properties = fields["properties"]?.object {
                var mapped: [String: JSONValue] = [:]
                for name in properties.keys.sorted() { mapped[name] = try transform(properties[name]!) }
                fields["properties"] = .object(mapped)
            }
            if let items = fields["items"] { fields["items"] = try transform(items) }
            for name in ["anyOf", "oneOf", "allOf"] {
                if let values = fields[name]?.array { fields[name] = .array(try values.map(transform)) }
            }
            return .object(fields)
        }
        func count(_ value: JSONValue) throws -> JSONValue {
            counts[try key(value), default: 0] += 1
            return try children(value, transform: count)
        }
        _ = try count(schema)
        var names: [String: String] = [:]
        var definitions: [String: JSONValue] = [:]
        func packed(_ value: JSONValue, reference: Bool = true) throws -> JSONValue {
            let identity = try key(value)
            let count = counts[identity, default: 0]
            if reference, count > 1, (count - 1) * identity.utf8.count > count * 25 + 32 {
                if let name = names[identity] { return .object(["$ref": .string("#/$defs/" + name)]) }
                let name = "s\(names.count)"
                names[identity] = name
                definitions[name] = value
                return .object(["$ref": .string("#/$defs/" + name)])
            }
            return try children(value) { try packed($0) }
        }
        var result = try packed(schema, reference: false).object ?? [:]
        if !definitions.isEmpty { result["$defs"] = .object(definitions) }
        return .object(result)
    }
}
