import Foundation

/// NativeAttributeReading preserves one native read without converting a missing value to off.
/// An empty string is a successful typed value. Unavailable results retain their distinct causes.
/// Numeric representation is diagnostic text; it never supplies a quantity or toggle state.
public enum NativeAttributeReading: Sendable, Equatable, Hashable, Codable {

    public enum Value: Sendable, Equatable, Hashable, Codable {
        case string(String)
        case boolean(Bool)
        case number(representation: String)
        case other(typeID: UInt64)
    }

    case value(Value)
    case noValue
    case unsupported
    case timedOut
    case emptyReply
    case failed(code: Int)
    case notRead

    /// Renders typed diagnostic facts on one scene line, escaping all string contents.
    public var diagnosticText: String {
        switch self {
            case .value(.string(let text)): "string:\(Self.displayText(text))"
            case .value(.boolean(let value)): "boolean:\(value)"
            case .value(.number(let text)): "number:\(Self.displayText(text))"
            case .value(.other(let typeID)): "other-type:\(typeID)"
            case .noValue: "no-value"
            case .unsupported: "unsupported"
            case .timedOut: "timeout"
            case .emptyReply: "empty-reply"
            case .failed(let code): "failed:\(code)"
            case .notRead: "not-read"
        }
    }
    /// Full, length-framed data for a stable scene token, independent of display truncation.
    var semanticKey: String {
        switch self {
            case .value(.string(let text)): "s\(text.utf8.count):\(text)"
            case .value(.boolean(let value)): value ? "b1" : "b0"
            case .value(.number(let text)): "n\(text.utf8.count):\(text)"
            case .value(.other(let typeID)): "t\(typeID)"
            case .noValue: "absent"
            case .unsupported: "unsupported"
            case .timedOut: "timeout"
            case .emptyReply: "empty-reply"
            case .failed(let code): "failed:\(code)"
            case .notRead: "not-read"
        }
    }

    private static func displayText(_ text: String) -> String {
        let prefix = String(String.UnicodeScalarView(text.unicodeScalars.prefix(64)))
        let omitted = text.unicodeScalars.count - prefix.unicodeScalars.count
        return String(reflecting: prefix) + (omitted > 0 ? "[truncated \(omitted) Unicode scalars]" : "")
    }

}
