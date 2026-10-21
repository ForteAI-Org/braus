import Foundation
import Memory
@testable import AutomationRuntime
import Testing

@Suite("Typed mixed fields and current account requirements")
struct MixedFieldDeliveryTests {
    @Test("field types and empty containers survive delivery without historical content")
    func typedDelivery() throws {
        let step = RecallSource.Step(
            position: 0, partID: "step", label: nil, bundleID: "notes", tool: .appCall,
            arguments: [OperationArgument(name: "arguments", position: 0, value: .literal(.text(
                #"{"priority":1,"flag":true,"empty":[],"object":{},"private":"HISTORICAL-PRIVATE-CONTENT"}"#)))],
            entry: .notApplicable, isOffered: true,
            fields: [
                .init(path: "/priority", kind: .parameter("priority"), valueKind: .number),
                .init(path: "/flag", kind: .constant("true"), valueKind: .boolean),
                .init(path: "/private", kind: .withheld, valueKind: .text)
            ])
        #expect(step.parameterIDs == ["priority"])
        #expect(!step.namesAccount && step.requiresAccountResolution)
        let source = RecallSource(routeID: "r", procedureLabel: "method", steps: [step], parts: [], parameters: [
            .init(parameterID: "priority", name: "priority", role: "priority", kind: .number,
                  direction: .input, unit: nil, observedValues: ["1"])
        ], confirmedUses: 0)
        let selection = RecallSelection(role: .selected, routeID: "r", firstPosition: 0, lastPosition: 0,
                                        wholePartID: nil, relevance: 1, preparations: 0,
                                        requirements: [.init(kind: .accountToResolve, stepPosition: 0)])
        let delivered = RecallService.render(selection, source: source, candidates: [], values: [], constraints: [])
        let arguments = try #require(delivered.steps.first?.arguments)
        let parameter = try #require(arguments.first { $0.name == "arguments/priority" })
        #expect(parameter.value == "{priority}" && parameter.valueType == "number")
        let flag = try #require(arguments.first { $0.name == "arguments/flag" })
        #expect(flag.value == "true" && flag.valueType == "boolean")
        let structure = try #require(arguments.first { $0.kind == "structure" })
        let shape = try #require(try JSONSerialization.jsonObject(with: Data(structure.value.utf8)) as? [String: Any])
        #expect((shape["empty"] as? [Any])?.isEmpty == true)
        #expect((shape["object"] as? [String: Any])?.isEmpty == true)
        let encoded = String(decoding: try JSONEncoder().encode(delivered), as: UTF8.self)
        #expect(!encoded.contains("HISTORICAL-PRIVATE-CONTENT"))
    }

    @Test("malformed typed scalar fields are rejected before storage")
    func invalidTypes() {
        #expect(throws: OperationFactError.self) { try StructuredField(path: "/n", kind: .number, text: "NaN") }
        #expect(throws: OperationFactError.self) { try StructuredField(path: "/b", kind: .boolean, text: "0") }
        #expect(throws: OperationFactError.self) { try StructuredField(path: "/null", kind: .null, text: "null") }
    }
}
