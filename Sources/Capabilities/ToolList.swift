import ChatCore

/// ToolList freezes the attendance and authority level chosen by a composition.
/// It describes the v2 surface without changing a transport, session or feature switch.
public struct ToolList: Sendable, Equatable {
    /// Attendance identifies who can answer a request for help.
    public enum Attendance: String, Sendable, Codable {
        case app, client, none
    }

    /// Level limits the capabilities a composition may discover and invoke.
    public enum Level: String, Sendable, Codable {
        case observe, act, actConnectors
    }

    public let attendance: Attendance
    public let level: Level

    public init(
        attendance: Attendance,
        level: Level
    ) {
        self.attendance = attendance
        self.level = level
    }

    /// The eleven core tools, in the order served to a conversation.
    public static let core: [CapabilityID] = [
        "open_session", "observe", "act", "type_text", "press_key", "menu", "batch", "plan", "end", "find", "call"
    ].map { CapabilityID(rawValue: $0) }

    /// Returns the fixed names for this composition. Human assistance is added by its owning feature later.
    /// Observe permits opening explicitly; the dispatcher must restrict delegated calls to read effects.
    public static func names(
        attendance: Attendance,
        level: Level,
        loading: ToolLoading = .upfront
    ) -> [CapabilityID] {
        let names = level == .observe
            ? core.filter { ["open_session", "observe", "find", "call"].contains($0.rawValue) }
            : core
        return loading == .harnessSearch
            ? names.filter { !["find", "call"].contains($0.rawValue) } : names
    }
}
