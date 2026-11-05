import AutomationMCP
import AutomationRuntime
import Capabilities
import LocalMCP
import Testing

@MainActor
struct BaseFileCapabilitiesTests {
    @Test func filesAreDiscoverableWithoutAddingInitialTools() {
        let tools = AutomationTools(session: ToolResultSession())
        let names = tools.capabilityDefinitions.compactMap { $0["name"].string }
        #expect(names.contains("files.read"))
        #expect(names.filter { $0 == "files.read" }.count == 1)
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ToolList.core.map(\.rawValue))
        #expect(tools.instructions.contains("files adapter"))
    }

    @Test func observationAuthorityCannotDelegateAFileWrite() async throws {
        let profile = SessionProfile(attendance: .client, level: .observe, memory: .read,
            catalogue: .open, takeover: false, options: .init(), name: "client")
        let tools = AutomationTools(session: ToolResultSession(), profile: profile)
        let names = tools.capabilityDefinitions.compactMap { $0["name"].string }
        #expect(names.contains("files.read"))
        #expect(!names.contains("files.write"))
        do {
            _ = try await tools.call("call", .object([
                "name": .string("files.write"),
                "arguments": .object(["path": .string("\0"), "text": .string("public fixture")])
            ]))
            Issue.record("Observation authority admitted a file write")
        } catch let failure as AutomationFailure {
            #expect(failure.description.contains("observation only"))
        }
    }
}
