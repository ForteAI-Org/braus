import Capabilities
import Foundation
@testable import AutomationMCP
import AutomationRuntime
import LocalMCP
import Testing

@MainActor
struct TaskCycleContractTests {
    @Test func planAndEndAreTheOnlyTaskTools() {
        let names = AutomationTools.definitions.compactMap { $0["name"].string }
        #expect(!names.contains("memory_task"))
        #expect(names.contains("plan") && names.contains("end"))
        #expect(!names.contains("ask_person"))
        #expect(AutomationTools.interruptionPolicy(for: "plan") == .mutating)
        #expect(AutomationTools.interruptionPolicy(for: "end") == .mutating)
        #expect(ActionBarrier.admittedWhileClosed.contains("plan"))
        #expect(!ActionBarrier.admittedWhileClosed.contains("memory_task"))
    }

    @Test func promptKeepsCycleAndEvidenceRulesWithoutLegacyInstructions() {
        let names = AutomationTools.definitions.compactMap { $0["name"].string }
        let text = ModelText.systemPrompt(toolNames: names, groupIndex: nil, searchesWeb: false, role: nil)
        #expect(text.contains("Pass step:\"r1\" on gestures or batches; step is an argument, not a tool"))
        #expect(!text.contains("Interpret the proposed procedure"))
        #expect(!text.contains("memory_task"))
        #expect(!text.contains("<guide>"))
        for phrase in ["If the object is missing, say so", "Claim success only with evidence"] {
            #expect(text.components(separatedBy: phrase).count == 2)
        }
        let description = AutomationTools.definitions.first { $0["name"].string == "plan" }?["description"].string ?? ""
        #expect(description.contains("3-10") && description.contains("subprocedure"))
        #expect(!AutomationTools.instructions.contains("memory_task"))
    }

    private func batchSchema() throws -> JSONValue {
        let batch = try #require(ToolCatalogue.definitions(for: [], surface: .tagged).first { $0["name"].string == "batch" })
        var schema = try #require(batch["inputSchema"].object)
        var fields = try #require(schema["properties"]?.object)
        fields.removeValue(forKey: "step")
        schema["properties"] = .object(fields)
        return .object(schema)
    }

    @Test func batchGesturesCarryStep() throws {
        let schema = try batchSchema()
        let valid: JSONValue = .object(["steps": .array([.object(["operation": .string("act"),
            "target": .string("Create"), "step": .string("r1")])])])
        #expect(SchemaValidation.firstProblem(valid, schema: schema) == nil)
        for invalid: JSONValue in [.number(1), .bool(false), .array([])] {
            let args: JSONValue = .object(["steps": .array([.object(["operation": .string("act"),
                "target": .string("Create"), "step": invalid])])])
            #expect(SchemaValidation.firstProblem(args, schema: schema)?.path == "$.steps[0].step")
        }
    }

    @Test func batchRowSchemasValidateTheirAdvertisedTypes() throws {
        let schema = try batchSchema()
        let row: [String: JSONValue] = ["operation": .string("act"), "target": .string("Create"), "step": .string("r1")]
        #expect(SchemaValidation.firstProblem(.object(["steps": .array([.object(row)])]), schema: schema) == nil)
        for field in ["target", "step"] {
            var invalid = row
            invalid[field] = .number(1)
            #expect(SchemaValidation.firstProblem(.object(["steps": .array([.object(invalid)])]), schema: schema)?.path == "$.steps[0].\(field)")
        }
    }

    @Test func statusIsDiscoveredWithoutExposingLegacyTaskOrRollout() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        var records: [String] = []
        tools.record = { records.append($0) }
        _ = try await tools.call("call", .object(["name": .string("status"), "arguments": .object([:])]))
        #expect(records.contains { $0.contains("status") })
        #expect(!records.joined().contains("switches_invalid"))
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "memory_task" })
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("memory_task", .object(["operation": .string("status")]))
        }
    }
}
