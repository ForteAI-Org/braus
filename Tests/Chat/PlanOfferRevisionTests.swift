@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
struct PlanOfferRevisionTests {
    @Test(arguments: ["app", "title", "inputs", "unchanged"])
    func retainedRowInvalidatesIncompatibleMemory(_ change: String) async throws {
        let directory = URL.temporaryDirectory.appending(path: "public-plan-revision-\(UUID().uuidString)")
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let secrets = ProducerSecrets()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: SceneTextPolicy())
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        let row: JSONValue = .object(["title": .string("Prepare"), "app": .string("App A")])
        let initial: JSONValue = .object(["request": .string("Public task"), "rows": .array([row])])
        _ = try await handler.cycleCall("plan", initial)
        #expect(handler.openTask != nil)
        let id = TodoRowID(rawValue: "r1")
        handler.rowMemory[id] = .init(proposal: "STALE_PUBLIC_OFFER", need: 0, parts: [:])
        handler.deliveredPlanParts[id] = "STALE_PUBLIC_PART"
        var revision: [String: JSONValue] = ["rows": .array([.object(["id": .string("r1"),
            "title": .string(change == "title" ? "Different outcome" : "Prepare"),
            "app": .string(change == "app" ? "App B" : "App A")])])]
        if change == "inputs" { revision["inputs"] = .array([.object(["name": .string("topic"), "value": .string("NEW_PUBLIC_TOPIC")])]) }
        _ = try await handler.cycleCall("plan", .object(revision))
        if change == "unchanged" {
            #expect(handler.rowMemory[id]?.proposal == "STALE_PUBLIC_OFFER")
            #expect(handler.deliveredPlanParts[id] == "STALE_PUBLIC_PART")
        } else {
            #expect(handler.rowMemory[id]?.proposal != "STALE_PUBLIC_OFFER")
            #expect(handler.deliveredPlanParts[id] != "STALE_PUBLIC_PART")
        }
        let memory = MemoryService.shared(for: directory)
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }
}
