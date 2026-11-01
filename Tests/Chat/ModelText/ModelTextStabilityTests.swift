import AutomationRuntime
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

@MainActor
struct ModelTextStabilityTests {
    static func canonicalBytes() throws -> Data {
        var rows: [JSONValue] = ModelText.catalogue.map {
            .object(["key": .string($0.key.rawValue), "text": .string($0.text)])
        }
        for bits in 0..<8 {
            var channels: AutomationChannels = []
            if bits & 1 != 0 { channels.insert(.native) }
            if bits & 2 != 0 { channels.insert(.web) }
            if bits & 4 != 0 { channels.insert(.adapters) }
            rows.append(.object([
                "instructions": .string(AutomationTools.instructions(for: channels)),
                "definitions": .array(AutomationTools.definitions(for: channels)),
                "mcp": .string(AutomationTools.mcpInstructions(.full))
            ]))
        }
        return try JSONValue.canonicalEncoder().encode(JSONValue.array(rows))
    }

    @Test
    func childBytes() throws {
        guard let path = ProcessInfo.processInfo.environment["BRAUS_MODEL_TEXT_CHILD"] else { return }
        try Self.canonicalBytes().write(to: URL(fileURLWithPath: path))
    }

    @Test
    func separateProcesses() throws {
        guard ProcessInfo.processInfo.environment["BRAUS_MODEL_TEXT_CHILD"] == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "model-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        var results: [Data] = []
        for index in 0..<2 {
            let output = directory.appending(path: "\(index).json")
            let log = directory.appending(path: "\(index).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer {
                do { try handle.close() }
                catch { Issue.record(error) }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--testing-library", "swift-testing", "--filter", "ModelTextStabilityTests/childBytes"]
            var environment = ProcessInfo.processInfo.environment
            environment["BRAUS_MODEL_TEXT_CHILD"] = output.path
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            let diagnostics = try String(contentsOf: log, encoding: .utf8)
            try #require(process.terminationStatus == 0, "\(diagnostics)")
            results.append(try Data(contentsOf: output))
        }
        #expect(results[0] == results[1])
        #expect(results[0] == (try Self.canonicalBytes()))
    }

    @Test
    func instructionFormsAreValues() async {
        let forms = await Task.detached {
            Set<AutomationTools.MCPInstructionsForm>([.firstLine, .full, .firstLine])
        }.value
        #expect(forms.count == 2)
        #expect(forms.contains(.firstLine))
        #expect(forms.contains(.full))
    }

    @Test
    func uniqueOrderedKeys() {
        let keys = ModelText.catalogue.map { $0.key.rawValue }
        #expect(Set(keys).count == keys.count)
        #expect(!keys.isEmpty)
        #expect(keys.first == "tool_catalogue.routes.v1")
    }
}
