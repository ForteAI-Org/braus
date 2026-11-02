import Foundation

/// AutomationFailure describes a refused setup or unavailable session without claiming an action succeeded.
public struct AutomationFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let cause: String?

    public init(_ description: String, cause: String? = nil) {
        self.description = description
        self.cause = cause
    }
}
