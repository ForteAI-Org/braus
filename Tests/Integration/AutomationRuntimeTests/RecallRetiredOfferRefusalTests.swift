@testable import AutomationMCP
@testable import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import SQLiteMemory
import Testing

@MainActor
@Suite(.serialized, .automaticSelection)
struct RecallRetiredOfferRefusalTests {
    @Test
    func explicitChoiceRetiredAfterDeliveryIsRejectedBeforePlanCommit() async throws {
        let session = ProcedureLearningTests.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        do {
            let (_, routeID) = try await RecallLifecycleTests.learnPhoto(session)
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
            defer { withExtendedLifetime((secrets, sceneText, formatter)) {} }
            handler.availableRecallChannels = { Set(AgentTool.allCases.map(\.rawValue)) }
            let row = TodoRowID(rawValue: "r1")
            let title = "Rotate <file> and export it as <name>.<extension> in <format>"
            let initialArguments: JSONValue = .object([
                "request": .string("Rotate and export the photo as JPEG"),
                "inputs": .array([
                    .object(["name": .string("criterion"), "value": .string("foto_demo")]),
                    .object(["name": .string("output_name"), "value": .string("new_photo")]),
                    .object(["name": .string("output_extension"), "value": .string("jpg")]),
                    .object(["name": .string("output_format"), "value": .string("JPEG")])
                ]),
                "rows": .array([.object(["title": .string(title), "app": .string("com.apple.Preview")])])
            ])
            func payload(_ answer: JSONValue) throws -> JSONValue {
                let text = try #require(answer["content"].array?.first?["text"].string)
                return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            }
            let initialAnswer = try await handler.cycleCall("plan", initialArguments)
            #expect(initialAnswer["isError"].bool != true)
            let initial = try payload(initialAnswer)
            let memoryText = try #require(initial["memory"].string)
            // Take the selectable key from the actual model-facing delivery, not injected row state.
            let line = try #require(memoryText.split(separator: "\n").first {
                $0.hasPrefix("r1: ") && $0.contains("«")
            })
            let key = String(line.dropFirst("r1: ".count).prefix { !$0.isWhitespace })
            let offer = try #require(handler.deliveredOffers[row]?.first { $0.key == key })
            let binding = try #require(handler.rowMemory[row])
            let range = try #require(binding.parts[offer.partID])
            let task = try #require(handler.openTask)
            let (_, producer) = try handler.cycleMemory()
            let revision = try await TaskChannel.revision(task.revision, of: task.taskID,
                producer: producer, memory: memory)
            let choice = RecallChoice.Plan(proposalID: binding.proposal, needs: [
                .init(position: 0, tracts: [.init(key: range.source, first: range.first, last: range.last)],
                      declared: .all, uncovered: nil)
            ])
            let preview = try await RecallService.shared(for: memory).choose(choice,
                taskID: task.taskID, attemptID: task.attemptID, revision: task.revision,
                values: revision.content.inputs, constraints: revision.content.constraints,
                producer: producer, preview: true)
            #expect(preview.delivery.delivery == "delivered")
            #expect(!preview.recordedNow)
            #expect(handler.deliveredPlanParts[row] == nil)

            // Retire a real step of the offered range through the existing public repository API.
            let step = try await memory.perform { repositories in
                try await repositories.store.read { transaction in
                    try transaction.query("""
                        SELECT p.part_uuid FROM memory_procedure_parts p
                        JOIN memory_routes r ON r.route_id=p.route_id
                        WHERE r.route_uuid=? AND p.part_kind='step' AND p.first_position=?
                        """, [.text(routeID), .integer(Int64(range.first))]) { try $0.text(0) }.first ?? nil
                }
            }
            let retiredStep = try #require(step)
            _ = try await memory.perform {
                try await $0.procedures.setState(.retired, of: retiredStep,
                    reason: "Test retires an offered step before its first choice", by: "test",
                    at: memory.clock.calendarMS())
            }
            #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(30)))

            func snapshot() async throws -> [Int64] {
                try await memory.perform { repositories in
                    try await repositories.store.read { transaction in
                        let tables = ["memory_task_revisions", "memory_todo_revisions", "memory_todo_items",
                            "memory_todo_item_states", "memory_recall_choices", "memory_recall_selections",
                            "memory_call_steps", "memory_agent_actions"]
                        return try tables.map { table in
                            try transaction.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? -1 }.first ?? -1
                        }
                    }
                }
            }
            // The retirement above is intentional. Capture the atomicity boundary after that mutation.
            let beforeSQL = try await snapshot()
            let beforeTodo = try await TaskChannel.todo(of: task.taskID, memory: memory)
            let beforeOpenTask = handler.openTask
            let beforeGestures = session.gestures
            let chosenArguments: JSONValue = .object(["rows": .array([.object([
                "id": .string("r1"), "title": .string(title), "app": .string("com.apple.Preview"),
                "part": .string(key)
            ])])])
            let refused = try await handler.cycleCall("plan", chosenArguments)
            #expect(refused["isError"].bool == true)
            let refusedPayload = try payload(refused)
            #expect(refusedPayload["status"].string == "error")
            #expect(refusedPayload["memory"] == .null && refusedPayload["guidance"] == .null)
            #expect(try await snapshot() == beforeSQL)
            #expect(try await TaskChannel.todo(of: task.taskID, memory: memory) == beforeTodo)
            #expect(handler.todo == beforeTodo)
            #expect(handler.openTask == beforeOpenTask)
            #expect(handler.deliveredPlanParts[row] == nil)
            #expect(session.gestures == beforeGestures)

            // Automatic search without an explicit choice must keep its honest fallback, not reject a plan.
            let noChoice: JSONValue = .object(["rows": .array([.object([
                "id": .string("r1"), "title": .string("Do the new work"),
                "app": .string("Unknown app without a learned method")
            ])])])
            let fallback = try await handler.cycleCall("plan", noChoice)
            #expect(fallback["isError"].bool != true)
            #expect(try payload(fallback)["status"].string == "revised")
            await RecallLifecycleTests.close(session)
        } catch {
            await RecallLifecycleTests.close(session)
            throw error
        }
    }
}
