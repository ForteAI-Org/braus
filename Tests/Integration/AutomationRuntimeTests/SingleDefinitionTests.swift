@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

struct SingleDefinitionTests {
    private struct Case: Decodable {
        let value: String?
        let field: FieldSignals
    }

    @Test func sharedGuardAndDeclarations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/Engine/MemoryTests/Privacy/Fixtures/sensitivity-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        let classifier = SensitivityClassifier()
        for item in cases {
            guard let value = item.value else { continue }
            let expected = classifier.classify(value, in: .init(labels: item.field.labels)).sensitivity == .secret
            #expect(ProductionPerception.workerValueGuard.withholdsValue(value, item.field.labels) == expected)
            #expect(classifier.valueGuard.withholdsValue(value, item.field.labels) == expected)
            let arguments: JSONValue = .object(["inputs": .array([.object([
                "value": .string(value), "secret": .bool(item.field.declaredSecret)
            ])])])
            let declared = classifier.classify(value, in: .init(declaredSecret: item.field.declaredSecret))
                .sensitivity == .secret
            #expect(MemoryTaskTool.declaredSecrets(in: arguments).contains(value) == declared)
        }
    }
}
