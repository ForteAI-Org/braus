import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
@Suite("Independent acceptance checks for plans 1 and 2", .serialized)
struct IndependentPlanAuditTests {

    @Test("P2-06: reading the affected resource must remain possible for reconciliation")
    func reconciliationReadMustRemainPossible() async throws {
        let folder = StructuredCallFactsTests.knowledge()
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = ReconciliationTests.RemindersFake()
        let tools = ReconciliationTests.tools(folder, adapter)
        _ = try await ReconciliationTests.complete(tools, "r-1")
        var problem: String?
        do {
            _ = try await tools.call("call", .object([
                "name": .string("reminders.find_reminders"),
                "arguments": .object(["query": .string("r-1")])]))
        } catch { problem = String(describing: error) }
        #expect(problem == nil, "a read-only operation must not be blocked: \(problem ?? "")")
        _ = try await tools.call("end", .object(["outcome": .string("completed")]))
        await MemoryService.closeAll()
    }

    @Test("P1-06: confidential content in the first adapter error stays out of persistent destinations")
    func firstConfidentialErrorMustBeWithheld() async throws {
        let folder = StructuredCallFactsTests.knowledge()
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = ConfidentialSurfaceTests.MailFake()
        let tools = AutomationTools(session: CallDispatchRecordTests.RouteFake(.desktop, memory: folder), adapters: AppAdapters([adapter]))
        tools.producer = CallProducer(source: .app, streamID: "audit-error", traceID: "audit")
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let transcript = Lines()
        tools.record = { transcript.all.append($0) }
        _ = try? await tools.call("call", .object([
            "name": .string("mail.boom"),
            "arguments": .object(["id": .string("msg-1")])]))
        #expect(adapter.failedReads == 1, "the first confidential error came from the provider")
        _ = await MemoryService.shared(for: folder).flush(within: .seconds(5))
        await MemoryService.closeAll()
        let bytes = try ConfidentialSurfaceTests.archiveBytes(folder)
        for content in [ConfidentialSurfaceTests.subject, ConfidentialSurfaceTests.person] {
            let archiveContainsContent = bytes.contains(content)
            let transcriptContainsContent = transcript.all.contains(where: { $0.contains(content) })
            #expect(archiveContainsContent == false, "confidential error content persisted in the archive")
            #expect(transcriptContainsContent == false, "confidential error content persisted in transcript")
        }
    }

}
