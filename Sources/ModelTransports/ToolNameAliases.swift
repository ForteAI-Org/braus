import CryptoKit
import Foundation

/// ToolNameAliases keeps capability IDs inside Braus and provider-safe names
/// on the wire. Valid ASCII names up to 64 bytes stay unchanged. Other names
/// use a stable SHA-256 alias, independent of tool order or the current subset.
/// A collision, including one with an unchanged name, refuses the request.
/// Provider records remain in their original wire form, signatures included.
struct ToolNameAliases: Sendable {
    private let originals: [String: String]

    init(tools: [ToolDefinition], messages: [TurnMessage]) throws {
        let names = tools.map(\.name) + messages.flatMap { message in
            message.toolCalls.map(\.name) + (message.call.map { [$0.name] } ?? [])
        }
        var originals: [String: String] = [:]
        for name in Set(names) {
            let alias = Self.wireName(name)
            if let original = originals[alias], original != name {
                throw ProviderError.badResponse("tool names have conflicting provider aliases")
            }
            originals[alias] = name
        }
        self.originals = originals
    }

    static func wireName(_ name: String) -> String {
        let bytes = name.utf8
        let allowed = !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 95 || byte == 45
        }
        guard !allowed else { return name }
        let canonical = name.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "tool_" + digest.prefix(59)
    }

    func restoring(_ call: ToolCall) -> ToolCall {
        ToolCall(id: call.id, name: originals[call.name] ?? call.name, arguments: call.arguments)
    }

    /// Only the name changes. Arguments can contain canonical IDs of their own.
    func sending(_ message: TurnMessage) -> TurnMessage {
        func sending(_ call: ToolCall) -> ToolCall {
            ToolCall(id: call.id, name: Self.wireName(call.name), arguments: call.arguments)
        }
        if let call = message.call {
            return TurnMessage(result: message.text, of: sending(call), isError: message.isError)
        }
        return TurnMessage(role: message.role, text: message.text,
                           toolCalls: message.toolCalls.map(sending), record: message.record)
    }
}
