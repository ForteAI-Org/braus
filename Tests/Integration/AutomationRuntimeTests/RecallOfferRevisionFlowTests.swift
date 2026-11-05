@testable import AutomationMCP
@testable import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
@Suite(.serialized, .automaticSelection)
struct RecallOfferRevisionFlowTests {
    @MainActor
    private final class Fixture {
        let session: LearningSession
        let memory: MemoryService
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter: ResultFormatter
        let handler: TaskCycleHandler
        let row = TodoRowID(rawValue: "r1")
        let title = "Rotate <file> and export it as <name>.<extension> in <format>"

        init() async throws {
            session = ProcedureLearningTests.photoSession(try W.directory())
            memory = MemoryService.shared(for: session.directory)
            _ = try await RecallLifecycleTests.learnPhoto(session)
            formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
            handler.availableRecallChannels = { Set(AgentTool.allCases.map(\.rawValue)) }
        }
        func values(output: String = "new_photo") -> JSONValue {
            .array([("criterion", "foto_demo"), ("output_name", output),
                ("output_extension", "jpg"), ("output_format", "JPEG")].map {
                .object(["name": .string($0.0), "value": .string($0.1)])
            })
        }
        func plan(_ fields: [String: JSONValue], error: Bool = false) async throws -> JSONValue {
            let answer = try await handler.cycleCall("plan", .object(fields))
            #expect((answer["isError"].bool == true) == error, "\(answer)")
            let text = try #require(answer["content"].array?.first?["text"].string)
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        func key(in payload: JSONValue) -> String? {
            guard let line = payload["memory"].string?.split(separator: "\n").first(where: {
                $0.hasPrefix("r1: ") && $0.contains("«")
            }) else { return nil }
            return String(line.dropFirst("r1: ".count).prefix { !$0.isWhitespace })
        }
        func choices() throws -> [String] {
            try ProcedureLearningTests.rows("SELECT count(*) FROM memory_recall_choices", in: session)
        }
        func close() async { await RecallLifecycleTests.close(session) }
    }

    @Test(arguments: ["app", "title", "inputs", "unchanged"])
    func realOfferRevisionUsesOnlyCurrentBindings(_ change: String) async throws {
        let fixture = try await Fixture()
        do {
            var row: [String: JSONValue] = ["title": .string(fixture.title), "app": .string("com.apple.Preview")]
            let initial = try await fixture.plan(["request": .string("Rotate and export the photo as JPEG"),
                "inputs": fixture.values(), "rows": .array([.object(row)])])
            let key = try #require(fixture.key(in: initial), "\(initial)")
            let offer = try #require(fixture.handler.deliveredOffers[fixture.row]?.first { $0.key == key })
            let originalProposal = try #require(fixture.handler.rowMemory[fixture.row]?.proposal)
            row["id"] = .string("r1")
            row["part"] = .string(key)
            _ = try await fixture.plan(["rows": .array([.object(row)])])
            #expect(fixture.handler.deliveredPlanParts[fixture.row] == offer.partID)
            let beforeTask = try #require(fixture.handler.openTask)
            let beforeTodo = try await TaskChannel.todo(of: beforeTask.taskID, memory: fixture.memory)
            let beforeChoices = try fixture.choices()
            let beforeGestures = fixture.session.gestures
            if change == "app" { row["app"] = .string("Unknown replacement app") }
            if change == "title" { row["title"] = .string("Prepare an unrelated task") }
            var fields: [String: JSONValue] = ["rows": .array([.object(row)])]
            if change == "inputs" { fields["inputs"] = fixture.values(output: "new_photo_v2") }
            _ = try await fixture.plan(fields, error: change != "unchanged")
            #expect(fixture.handler.openTask == beforeTask)
            #expect(try fixture.choices() == beforeChoices)
            #expect(fixture.session.gestures == beforeGestures)
            if change == "unchanged" {
                #expect(fixture.handler.rowMemory[fixture.row]?.proposal == originalProposal)
                #expect(fixture.handler.deliveredPlanParts[fixture.row] == offer.partID)
            } else {
                #expect(try await TaskChannel.todo(of: beforeTask.taskID, memory: fixture.memory) == beforeTodo)
                row.removeValue(forKey: "part")
                fields["rows"] = .array([.object(row)])
                let revision = try await fixture.plan(fields)
                #expect(revision["status"].string == "revised")
                #expect(fixture.handler.deliveredPlanParts[fixture.row] == nil)
                #expect(fixture.handler.rowMemory[fixture.row]?.proposal != originalProposal)
                #expect(fixture.handler.todo?.rows.first?.part == nil)
                if change == "inputs" { _ = try #require(fixture.key(in: revision), "Input-only revision must re-offer the method") }
                if let currentKey = fixture.key(in: revision) {
                    // The same local key can be offered again with a new proposal and current values.
                    row["part"] = .string(currentKey)
                    let choice = try await fixture.plan(["rows": .array([.object(row)])])
                    #expect(fixture.handler.deliveredPlanParts[fixture.row] != nil)
                    if change == "inputs" {
                        #expect(choice["memory"].string?.contains("new_photo_v2") == true)
                        #expect(choice["memory"].string?.contains("new_photo.jpg") != true)
                        #expect(fixture.handler.openTask?.revision == beforeTask.revision + 1)
                    }
                } else {
                    row["part"] = .string(key)
                    let before = try await TaskChannel.todo(of: beforeTask.taskID, memory: fixture.memory)
                    _ = try await fixture.plan(["rows": .array([.object(row)])], error: true)
                    #expect(try await TaskChannel.todo(of: beforeTask.taskID, memory: fixture.memory) == before)
                }
            }
            #expect(fixture.session.gestures == beforeGestures)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
