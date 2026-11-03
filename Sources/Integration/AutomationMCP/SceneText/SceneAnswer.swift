import Foundation
import LocalMCP
import PerceptionCore

/// SceneAnswer is one model reading, including its minimized scene, base and text provenance.
nonisolated public struct SceneAnswer: Sendable, Equatable {
    public enum Form: Sendable, Equatable {
        case whole(because: SceneContextReset?)
        case changes(since: Int, base: Base)
        case unchanged(since: Int)
    }
    public enum Base: String, Sendable, Equatable { case anchor, last }
    public let revision: Int
    public let form: Form
    public let window: SceneWindowKey
    public let scene: SceneSnapshot
    public let text: String
    public let parts: [SceneTextPart]

    /// Preserves the existing tool envelope; the policy has already decided and written its text.
    func observation(nested: Bool) -> JSONValue {
        var values: [String: JSONValue] = ["revision": .number(Double(revision))]
        if !nested {
            values["session"] = window.session.map { .string($0.uuidString) } ?? .null
            values["observedAt"] = .string(Date().ISO8601Format())
        }
        switch form {
        case .whole: values["scene"] = .string(text)
        case .changes(let since, _), .unchanged(let since):
            values["changes"] = .string(text)
            values["since"] = .number(Double(since))
        }
        return .object(values)
    }
}
