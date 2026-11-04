import AutomationMCP
import AutomationRuntime
import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Memory
import Testing

@Suite
@MainActor
struct PublicSurfaceTests {
    @Test
    func facadeRemainsPublic() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, channels: [], adapters: nil, offersWeb: false)
        let policy: AutomationTools.InterruptionPolicy = .readOnly
        #expect(AutomationTools.interruptionPolicy(for: "status") == policy)
        let form: AutomationTools.MCPInstructionsForm = .full
        #expect(!AutomationTools.mcpInstructions(form).isEmpty)
        #expect(tools.toolDefinitions == AutomationTools.definitions)
        #expect(AutomationTools.definitions == AutomationTools.definitions(for: []))
        #expect(AutomationTools.definitions(offeringAdapters: false, offeringWeb: false) == tools.toolDefinitions)
        #expect(tools.instructions == AutomationTools.instructions)
        #expect(AutomationTools.instructions == AutomationTools.instructions(for: []))
        #expect(AutomationTools.instructions(offeringAdapters: false, offeringWeb: false) == tools.instructions)
        #expect(!AutomationTools.closeChangedCopies.isEmpty)
        #expect(!AutomationTools.browserEngineProfile.isEmpty)
        #expect(!AutomationTools.bulkReading.isEmpty)
        #expect(AutomationTools.elementReference("id:'field'") == "field")
        tools.producer = CallProducer(source: .app, streamID: "public-surface")
        tools.record = { _ in }
        #expect(tools.producer.streamID == "public-surface")
        #expect(tools.adapters == nil)
        #expect(tools.router == nil)
        #expect(tools.record != nil)
        #expect(tools.channels.isEmpty)
        #expect(tools.session.id == session.id)
        #expect(!tools.offersWeb)
        #expect(tools.openTask == nil)
        #expect(tools.pendingCandidate == nil)
        #expect(tools.withheld("ordinary text") == "ordinary text")
        #expect(tools.takeInterpretationReminder() == nil)
        #expect(await tools.interpretLeftCandidate() == nil)
        tools.forgetConversation()
        tools.contextHolds(after: .compaction)
        tools.markTaskInterrupted()
        try await tools.finishInterruptedTask()
        #expect(tools.takeStoppedTaskNotice() == nil)
        let result = try await tools.call("observe", .object([:]))
        #expect(result["content"].array?.isEmpty == false)
    }
}
