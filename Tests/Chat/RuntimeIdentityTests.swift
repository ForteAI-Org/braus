import AutomationMCP
import AutomationRuntime
import CryptoKit
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
@Suite("Host runtime identity", .serialized)
struct RuntimeIdentityTests {
    @Test func hostReadsIdentityWithoutTheRemovedModelTool() async throws {
        let directory = URL.temporaryDirectory.appending(path: "runtime-identity-\(UUID().uuidString)")
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session, profile: .cli)
        let identity = try await tools.runtimeIdentity()
        #expect(identity["archive"].string == directory.appending(path: "memory.sqlite").path)
        #expect(identity["profile"]["attended"].bool == false)
        #expect(identity["runtime"]["contract"].string == "braus-t2-single-path")
        let names = try #require(identity["runtime"]["served_tools"].array).compactMap(\.string)
        #expect(names.count == 11)
        #expect(names.contains("plan") && names.contains("end") && names.contains("find"))
        #expect(!names.contains("memory_task"))
        #expect(identity["configuration"] == .null && identity["switches"] == .null)
        #expect(identity["runtime"]["pending_experiments"] == .array([]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(JSONValue.array(tools.toolDefinitions)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(identity["runtime"]["tool_schema_sha256"].string == digest)
        await #expect(throws: (any Error).self) {
            _ = try await tools.call("memory_task", .object(["operation": .string("status")]))
        }
        #expect(tools.configurationEvidence["tool_attempts"]["memory_task"] == .number(1))
        #expect(session.calls.isEmpty)
        await MemoryService.shared(for: directory).close()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    @Test func nestedAndLaterCallsKeepTheReceivingProfilesAuthority() async throws {
        let session = ToolResultSession()
        let observer = AutomationTools(session: session, profile: SessionProfile(attendance: .none, level: .observe, memory: .readLearn, catalogue: .open, takeover: false, options: .init(), name: "observer"))
        let actor = AutomationTools(session: ToolResultSession(), profile: .cli)
        try await actor.withRuntimeConfiguration {
            await #expect(throws: (any Error).self) {
                _ = try await observer.call("act", .object(["target": .string("Apply")]))
            }
            await Task.yield()
            #expect(observer.profile.level == .observe)
        }
        await #expect(throws: (any Error).self) {
            _ = try await observer.call("act", .object(["target": .string("Apply")]))
        }
        #expect(observer.profile.level == .observe && actor.profile.level == .actConnectors)
        #expect(session.calls.isEmpty)
        #expect(observer.configurationEvidence["tool_attempts"]["<unlisted>"] == .number(2))
    }

    @Test func openProfileNeverLoadsInjectedGuidePaths() async throws {
        var options = SessionProfile.cli.options
        options.guides = [URL(filePath: "/definitely-not-an-installed-guide")]
        let tools = AutomationTools(session: ToolResultSession(),
            profile: SessionProfile(attendance: .none, level: .actConnectors, memory: .readLearn, catalogue: .open, takeover: false, options: options, name: "open"))
        try await tools.prepareGuides()
        #expect(!tools.guidesEnabled)
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "read_guide" })
        #expect(!tools.groupIndex.contains("read_guide"))
    }
}
