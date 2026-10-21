import Memory
@testable import SQLiteMemory
import Testing

@Suite("Structured fields bind only to typed inputs of their source attempt")
struct StructuredParameterTests {
    @Test("matching field binds; another type, role, attempt or missing value never does")
    func matching() throws {
        let parameter = RouteParameter(parameterID: "p", name: "count", direction: .input, valueType: .integer, isRequired: true)
        let binding = ParameterBinding(parameterID: "p", attemptID: "source", content: .text("2"),
                                       source: .request, sourceRef: nil, sourceVersion: nil)
        let field = try StructuredField(path: "/count", kind: .number, text: "2")
        #expect(SQLiteCallFieldRows.parameters(for: field, among: [parameter], bindings: [binding], attemptID: "source") == ["p"])
        #expect(SQLiteCallFieldRows.parameters(for: field, among: [parameter], bindings: [binding], attemptID: "other").isEmpty)
        let text = try StructuredField(path: "/count", kind: .text, text: "2")
        #expect(SQLiteCallFieldRows.parameters(for: text, among: [parameter], bindings: [binding], attemptID: "source").isEmpty)
        let fractional = try StructuredField(path: "/count", kind: .number, text: "2.5")
        #expect(SQLiteCallFieldRows.parameters(for: fractional, among: [parameter], bindings: [binding], attemptID: "source").isEmpty)
        let unrelated = try StructuredField(path: "/priority", kind: .number, text: "2")
        #expect(SQLiteCallFieldRows.parameters(for: unrelated, among: [parameter], bindings: [binding], attemptID: "source").isEmpty)
        #expect(SQLiteCallFieldRows.parameters(for: field, among: [parameter], bindings: [], attemptID: "source").isEmpty)
    }
}
