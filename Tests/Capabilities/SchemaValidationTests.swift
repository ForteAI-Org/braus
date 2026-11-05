import Capabilities
import LocalMCP
import Testing

@Suite
struct SchemaValidationTests {
    @Test func typesAreNotCoerced() {
        let cases: [(String, JSONValue, JSONValue)] = [
            ("object", .object([:]), .array([])), ("array", .array([]), .object([:])),
            ("string", .string("text"), .number(1)), ("boolean", .bool(true), .number(1)),
            ("number", .number(1.5), .string("1.5")), ("integer", .number(2), .number(1.5)),
            ("null", .null, .string("null"))
        ]
        for (type, valid, invalid) in cases {
            let schema: JSONValue = .object(["type": .string(type)])
            #expect(SchemaValidation.firstProblem(valid, schema: schema) == nil)
            #expect(SchemaValidation.firstProblem(invalid, schema: schema) != nil)
        }
        for value in [Double.infinity, -.infinity, .nan] {
            #expect(SchemaValidation.firstProblem(.number(value), schema: .object(["type": .string("number")])) != nil)
        }
    }

    @Test func requiredAndAdditionalPropertiesAreDeterministic() {
        let schema = objectSchema(["alpha": .object(["type": .string("string")])], required: ["alpha"])
        #expect(SchemaValidation.firstProblem(.object(["alpha": .string("ok")]), schema: schema) == nil)
        let missing = SchemaValidation.firstProblem(.object([:]), schema: schema)
        #expect(missing?.path == "$.alpha" && missing?.code == .requiredArgumentMissing)
        let problem = SchemaValidation.firstProblem(.object([
            "alpha": .string("ok"), "zeta": .null, "beta": .null
        ]), schema: schema)
        #expect(problem?.path == "$.beta" && problem?.code == .unknownArgument)
        #expect(problem?.path.contains("\n") == false)
    }

    @Test func numericBoundsAndEnumIncludeTheirEndpoints() {
        let schema: JSONValue = .object([
            "type": .string("number"), "minimum": .number(-2), "maximum": .number(3)
        ])
        for value in [-2.0, 0, 3] {
            #expect(SchemaValidation.firstProblem(.number(value), schema: schema) == nil)
        }
        for value in [-2.1, 3.1] {
            #expect(SchemaValidation.firstProblem(.number(value), schema: schema) != nil)
        }
        let choices: JSONValue = .object(["enum": .array([.string("up"), .string("down"), .null])])
        #expect(SchemaValidation.firstProblem(.string("up"), schema: choices) == nil)
        #expect(SchemaValidation.firstProblem(.null, schema: choices) == nil)
        #expect(SchemaValidation.firstProblem(.string("left"), schema: choices) != nil)
    }

    @Test func nestedObjectsAndArrayItemsReportTheirPath() {
        let item = objectSchema(["count": .object(["type": .string("integer")])], required: ["count"])
        let schema = objectSchema(["steps": .object(["type": .string("array"), "items": item])])
        let valid: JSONValue = .object(["steps": .array([.object(["count": .number(1)])])])
        #expect(SchemaValidation.firstProblem(valid, schema: schema) == nil)
        let invalid: JSONValue = .object(["steps": .array([.object(["count": .number(1.5)])])])
        #expect(SchemaValidation.firstProblem(invalid, schema: schema)?.path == "$.steps[0].count")
    }

    @Test func stringAndArraySizesAndUniqueItems() {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(2)])
        #expect(SchemaValidation.firstProblem(.string("é"), schema: text) == nil)
        #expect(SchemaValidation.firstProblem(.string("a\u{0301}"), schema: text) == nil)
        #expect(SchemaValidation.firstProblem(.string("a\u{0301}b"), schema: text) != nil)
        #expect(SchemaValidation.firstProblem(.string(""), schema: text) != nil)
        #expect(SchemaValidation.firstProblem(.string("abc"), schema: text) != nil)
        let array: JSONValue = .object([
            "type": .string("array"), "minItems": .number(1), "maxItems": .number(2), "uniqueItems": .bool(true)
        ])
        #expect(SchemaValidation.firstProblem(.array([.number(1), .number(2)]), schema: array) == nil)
        for values: [JSONValue] in [[], [.null, .null], [.number(1), .number(2), .number(3)]] {
            #expect(SchemaValidation.firstProblem(.array(values), schema: array) != nil)
        }
    }

    @Test func nullableTypesAndSchemaAlternatives() {
        let nullable: JSONValue = .object(["type": .array([.string("string"), .string("null")])])
        #expect(SchemaValidation.firstProblem(.null, schema: nullable) == nil)
        #expect(SchemaValidation.firstProblem(.string("value"), schema: nullable) == nil)
        #expect(SchemaValidation.firstProblem(.number(1), schema: nullable) != nil)
        let choices: [JSONValue] = [
            .object(["type": .string("integer")]), .object(["type": .string("number")])
        ]
        #expect(SchemaValidation.firstProblem(.number(1), schema: .object(["anyOf": .array(choices)])) == nil)
        #expect(SchemaValidation.firstProblem(.number(1), schema: .object(["oneOf": .array(choices)])) != nil)
        #expect(SchemaValidation.firstProblem(.number(1.5), schema: .object(["oneOf": .array(choices)])) == nil)
    }

    @Test func propertyNamesCannotTurnProblemsIntoMultipleLines() throws {
        let result = SchemaValidation.firstProblem(.object(["bad\nkey": .null]), schema: objectSchema([:]))
        let problem = try #require(result)
        #expect(!problem.path.contains("\n"))
    }

    @Test func unsupportedKeywordsInvalidateTheWholeSchema() {
        for keyword in ["const", "pattern", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
                        "minProperties", "maxProperties", "format", "not", "contains"] {
            let schema: JSONValue = .object([keyword: .string("unsupported")])
            #expect(SchemaValidation.firstProblem(.null, schema: schema)?.code == .unsupportedSchemaKeyword(keyword), "Accepted \(keyword)")
            let unused = objectSchema(["unused": schema])
            #expect(SchemaValidation.firstProblem(.object([:]), schema: unused) != nil)
            let alternative: JSONValue = .object(["anyOf": .array([.bool(true), schema])])
            #expect(SchemaValidation.firstProblem(.null, schema: alternative) != nil)
        }
        #expect(SchemaValidation.firstProblem(.object([:]), schema: .object([
            "additionalProperties": .object(["type": .string("string")])
        ])) != nil)
    }

    @Test func schemaDepthIsBoundedEvenForUnusedProperties() {
        var schema: JSONValue = .bool(true)
        for _ in 0..<33 { schema = objectSchema(["next": schema]) }
        #expect(SchemaValidation.firstProblem(.object([:]), schema: schema)?.code == .schemaTooDeep)
        var supported: JSONValue = .bool(true)
        for _ in 0..<32 { supported = objectSchema(["next": supported]) }
        #expect(SchemaValidation.firstProblem(.object([:]), schema: supported) == nil)
    }

    @Test func invalidTypeIsASchemaProblem() {
        for type: JSONValue in [.number(1), .string("unknown"), .array([]),
                                .array([.string("string"), .number(1)])] {
            let result = SchemaValidation.firstProblem(.null, schema: .object(["type": type]))
            #expect(result?.code == .invalidSchemaType)
        }
    }

    @Test func echoedPathsAreBounded() throws {
        let result = try #require(SchemaValidation.firstProblem(
            .object([String(repeating: "x", count: 500): .null]), schema: objectSchema([:])))
        #expect(result.path.count <= 64)
        let combined = try #require(SchemaValidation.firstProblem(
            .object(["x" + String(repeating: "\u{301}", count: 500): .null]), schema: objectSchema([:])))
        #expect(combined.path.unicodeScalars.count <= 64)
    }

    private func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)
        ])
    }
}
