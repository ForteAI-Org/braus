import Foundation
import Testing
@testable import AutomationMCP

struct ModelTextCensusTests {
    @Test
    func frozenExceptions() throws {
        let source = try String(contentsOf: modelTextRoot.appending(path: "Tools/Lint/model-text-exceptions.txt"), encoding: .utf8)
        let rows = source.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(rows.count <= 884)
        #expect(rows.count + legacyKeys.count <= 1324)
        let baseline = try JSONDecoder().decode([String].self, from: Data(contentsOf:
            modelTextRoot.appending(path: "Tests/Chat/Fixtures/model-text-exception-identities.json")))
        let allowed = Set(baseline)
        var identities: Set<String> = []
        for row in rows {
            let fields = row.components(separatedBy: " | ")
            try #require(fields.count == 5)
            let location = fields[0].split(separator: ":")
            try #require(location.count == 2)
            let file = modelTextRoot.appending(path: String(location[0]))
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(Int(location[1]).map { $0 > 0 } == true)
            #expect(!fields[3].isEmpty)
            #expect(!fields[4].isEmpty)
            let identity = [String(location[0]), fields[1], fields[2]].joined(separator: "|")
            #expect(allowed.contains(identity))
            #expect(identities.insert(identity).inserted)
        }
    }

    @Test
    func lintAndTokenizerFixtures() throws {
        for script in ["check-model-text", "test_check_model_text.py"] {
            let output = FileManager.default.temporaryDirectory.appending(path: "model-text-lint-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer {
                do {
                    try handle.close()
                    try FileManager.default.removeItem(at: output)
                } catch { Issue.record(error) }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", modelTextRoot.appending(path: "Tools/Lint/\(script)").path]
            process.currentDirectoryURL = modelTextRoot
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            let diagnostics = try String(contentsOf: output, encoding: .utf8)
            #expect(process.terminationStatus == 0, "\(diagnostics)")
        }
    }
}
