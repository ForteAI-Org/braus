import Capabilities
import LocalMCP
import Testing

struct LocalSchemaReferenceTests {
    private func schema(_ reference: String, definition: JSONValue) -> JSONValue {
        .object(["type": .string("object"), "$defs": .object(["value": definition]),
            "properties": .object(["count": .object(["$ref": .string(reference)])]),
            "required": .array([.string("count")]), "additionalProperties": .bool(false)])
    }
    @Test func localDefinitionsKeepTypesAndRejectUnboundedOrExternalReferences() {
        let valid = schema("#/$defs/value", definition: .object(["type": .string("integer"), "minimum": .number(1)]))
        #expect(SchemaValidation.firstProblem(.object(["count": .number(2)]), schema: valid) == nil)
        #expect(SchemaValidation.firstProblem(.object(["count": .string("2")]), schema: valid) != nil)
        for ref in ["https://example.invalid/schema", "#/$defs/missing", "#"] {
            #expect(SchemaValidation.firstProblem(.object(["count": .number(2)]), schema: schema(ref, definition: .object([:]))) != nil)
        }
        let recursive = schema("#/$defs/value", definition: .object(["$ref": .string("#/$defs/value")]))
        #expect(SchemaValidation.firstProblem(.object(["count": .number(2)]), schema: recursive) != nil)
        let unusedInvalid = schema("#/$defs/value", definition: .object(["unrecognized": .bool(true)]))
        #expect(SchemaValidation.firstProblem(.object([:]), schema: unusedInvalid) != nil)
    }
}
