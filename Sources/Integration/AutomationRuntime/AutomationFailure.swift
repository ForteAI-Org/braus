import Foundation
import LocalMCP

/// AutomationFailure describes a refused setup or unavailable session without claiming an action succeeded.
public struct AutomationFailure: Error, CustomStringConvertible, Sendable, MCPFailureContext {
    public let description: String
    public let cause: String?
    public let isBeforeDispatch: Bool

    public init(_ description: String, cause: String? = nil, beforeDispatch: Bool = false) {
        self.description = description
        self.cause = cause
        self.isBeforeDispatch = beforeDispatch
    }
}
