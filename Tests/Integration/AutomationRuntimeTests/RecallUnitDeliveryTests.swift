import Foundation
@testable import AutomationRuntime
import Memory
import Testing

@Suite("Recall delivers required unit and unresolved evidence")
struct RecallUnitDeliveryTests {

    @Test("unit requirements and current identity conflicts cannot acquire a producer workaround",
          arguments: [true, false])
    func unitRequirementIsDelivered(requiresUnit: Bool) throws {
        let parameter = RecallSource.Parameter(
            parameterID: "duration", name: "duration", role: "duration", kind: .number,
            direction: .input, unit: requiresUnit ? "s" : nil, observedValues: ["2"], origins: [
                .init(source: .previousOutput, reference: "measurement", attemptID: "attempt", taskID: "task", value: "2"),
            ]
        )
        let source = RecallSource(
            routeID: "quantity", procedureLabel: "Apply duration", steps: [], parts: [
                .init(partID: "producer", kind: .subprocedure, firstPosition: 0, lastPosition: 0,
                      label: "Measure duration", bundleID: "example.editor", isOffered: true),
            ], parameters: [parameter, .init(
                parameterID: "measurement", name: "measurement", role: "measurement", kind: .number,
                direction: .output, unit: nil, observedValues: ["2"], producedBy: "producer"
            )], confirmedUses: 0
        )
        let selection = RecallSelection(
            role: .selected, routeID: source.routeID, firstPosition: 0, lastPosition: 0,
            wholePartID: nil, relevance: 1, preparations: 0,
            requirements: [.init(kind: .parameterMissing, parameterID: "duration")]
        )
        var values = [try TaskValue(name: "measurement", kind: .number, content: .text("2"), source: .request)]
        if !requiresUnit {
            values.append(try TaskValue(name: "duration", role: "track name", kind: .text,
                                        content: .text("New Bass"), source: .request))
        }
        let delivered = RecallService.render(
            selection, source: source, candidates: RecallBinding.candidates(values), values: values, constraints: []
        )
        let input = try #require(delivered.parameters.first)
        #expect(input.unit == (requiresUnit ? "s" : nil))
        #expect(input.status == "missing")
        #expect(input.value == nil && input.from == nil && input.producedBy == nil)
        #expect(delivered.conditions.contains {
            $0.kind == "unit_unresolved" && $0.detail.contains("no unit evidence")
        } == requiresUnit)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(delivered))
        let json = try #require(encoded as? [String: Any])
        let parameters = try #require(json["parameters"] as? [[String: Any]])
        #expect(parameters.first?["unit"] as? String == (requiresUnit ? "s" : nil))
    }
}
