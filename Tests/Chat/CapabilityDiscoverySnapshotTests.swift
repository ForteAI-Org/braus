import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

@MainActor
struct CapabilityDiscoverySnapshotTests {
    @Test
    func readingMetadataDoesNotSearchOrChangeTheServedSurface() throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        let before = tools.configurationEvidence
        let snapshot = tools.capabilityDefinitions
        let expected = tools.dispatcher.entries.map { $0.contract.id.rawValue }
        let names = snapshot.compactMap { $0["name"].string }
        #expect(names == expected)
        #expect(names.count == Set(names).count)
        #expect(Set(names).isDisjoint(with: ToolList.core.map(\.rawValue)))
        #expect(Set(names).isDisjoint(with: ["memory_task", "human_step", "app_call", "app_capabilities", "read_guide"]))
        for entry in tools.dispatcher.entries {
            let definition = try #require(snapshot.first { $0["name"].string == entry.contract.id.rawValue })
            #expect(definition["inputSchema"] == entry.contract.inputSchema)
            #expect(definition["annotations"]["readOnlyHint"].bool == (entry.contract.effect == .read))
        }
        #expect(tools.configurationEvidence == before)
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ToolList.core.map(\.rawValue))
        #expect(session.calls.isEmpty && session.inputs.isEmpty)
    }

    @Test
    func observeMetadataDoesNotAuthorizeAWritingCapability() async throws {
        let session = ToolResultSession()
        let profile = SessionProfile(attendance: .none, level: .observe, memory: .off,
                                     catalogue: .open, takeover: false, options: .init(), name: "observer")
        let tools = AutomationTools(session: session, profile: profile)
        let names = tools.capabilityDefinitions.compactMap { $0["name"].string }
        #expect(names.contains("status"))
        #expect(!names.contains("select") && !names.contains("reconcile_call"))
        #expect(tools.capabilityDefinitions.allSatisfy { $0["annotations"]["readOnlyHint"].bool == true })
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("call", .object(["name": .string("select"),
                "arguments": .object(["control": .string("Choice"), "item": .string("Blue")])]))
        }
        #expect(session.calls.isEmpty && session.inputs.isEmpty)
    }

    @Test
    func openAndPrivateCompositionsRemainIsolated() {
        let provider = MetadataReadProvider()
        let privateTools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        let open = SessionProfile(attendance: .none, level: .actConnectors, memory: .off,
                                  catalogue: .open, takeover: false, options: .init(), name: "open")
        let openTools = AutomationTools(session: ToolResultSession(), capabilities: [provider], profile: open)
        #expect(privateTools.capabilityDefinitions.contains { $0["name"].string == "metadata.read" })
        #expect(!openTools.capabilityDefinitions.contains { $0["name"].string == "metadata.read" })
        #expect(!openTools.capabilityDefinitions.contains { ($0["name"].string ?? "").contains("guide") })
        #expect(privateTools.capabilityDefinitions.contains { $0["name"].string == "metadata.read" })
    }

    @Test
    func changingTheReturnedValueCannotChangeTheComposition() throws {
        let tools = AutomationTools(session: ToolResultSession())
        let before = tools.capabilityDefinitions
        var snapshot = before
        var first = try #require(snapshot.first?.object)
        first["name"] = .string("different")
        snapshot[0] = .object(first)
        #expect(snapshot != before)
        #expect(tools.capabilityDefinitions == before)
    }
}

private struct MetadataReadProvider: CapabilityProviding {
    let family = "metadata"
    var contracts: [CapabilityContract] {
        [CapabilityContract(id: .init(rawValue: "metadata.read"), group: "metadata",
            description: "Read synthetic state.", inputSchema: .object(["type": .string("object"),
                "properties": .object([:]), "additionalProperties": .bool(false)]),
            effect: .read, interruption: .readOnly, verification: .resultCheck,
            channel: .braus, origin: .registered(provider: "metadata"), memory: .capabilityStep,
            takesSession: false)]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        .object(["state": .string("synthetic")])
    }
}
