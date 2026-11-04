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
        #expect(text.contains("Use `step` to name the row served"))
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

    @Test func batchGesturesCarryStep() throws {
        let batch = try #require(ToolCatalogue.definitions(for: [], surface: .tagged).first { $0["name"].string == "batch" })
        let items = batch["inputSchema"]["properties"]["steps"]["items"]
        let variants = items["oneOf"].array ?? [items]
        #expect(variants.allSatisfy { $0["properties"]["step"]["type"].string == "string" })
    }

    @Test func batchRowSchemasValidateTheirAdvertisedTypes() throws {
        let batch = try #require(ToolCatalogue.definitions(for: [], surface: .tagged).first { $0["name"].string == "batch" })
        let schema = batch["inputSchema"]["properties"]["steps"]
        let valid: JSONValue = .array([.object(["operation": .string("act"), "target": .string("Create"), "step": .string("r1")])])
        #expect(SchemaValidation.firstProblem(valid, schema: schema) == nil)
        for field in ["target", "step"] {
            var row = try #require(valid.array?.first?.object)
            row[field] = .number(1)
            #expect(SchemaValidation.firstProblem(.array([.object(row)]), schema: schema)?.path == "$[0].\(field)")
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
