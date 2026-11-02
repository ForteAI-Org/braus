import EngineCore
import Foundation
import LocalMCP
import Testing

@MainActor
struct HostPermissionGoldenTests {
    @Test(arguments: 0..<8)
    func statusPermissionsAreHostIndependent(_ bits: Int) throws {
        let permissions: JSONValue = .object([
            "accessibility": .bool(bits & 1 != 0),
            "postEvent": .bool(bits & 2 != 0),
            "screenRecording": .bool(bits & 4 != 0)
        ])
        let payload: JSONValue = .object(["permissions": permissions, "unchanged": .bool(false)])
        let encoder = JSONEncoder()
        let text = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let result: JSONValue = .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": payload
        ])
        let normalized = try JSONDecoder().decode(JSONValue.self, from: ToolGolden.normalized(result))
        let embedded = try JSONDecoder().decode(JSONValue.self,
            from: Data(try #require(normalized["content"].array?.first?["text"].string).utf8))
        for object in [embedded, normalized["structuredContent"]] {
            for key in ["accessibility", "postEvent", "screenRecording"] {
                #expect(object["permissions"][key] == .string("<permission>"))
            }
            #expect(object["unchanged"] == .bool(false))
        }
        let transcript = try ToolGolden.normalized(.array([.string("status " + text)]))
        #expect(String(decoding: transcript, as: UTF8.self).contains("<permission>"))
    }
}
