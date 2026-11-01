import Foundation
import Synchronization

/// SwitchBoard holds process switch values, with task-scoped overrides for tests.
public struct SwitchBoard: Sendable, Equatable {
    public let values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    private struct State {
        var installed: SwitchBoard?
        var invalid: [String: String] = [:]
    }

    private static let state = Mutex(State())
    private static let environment = fromEnvironment(ProcessInfo.processInfo.environment)

    @TaskLocal
    public static var testing: SwitchBoard?

    /// Reads comma-separated name=value pairs. Unrecognized arms are reported when read.
    public static func fromEnvironment(_ environment: [String: String]) -> SwitchBoard {
        var values: [String: String] = [:]
        for entry in (environment["BRAUS_SWITCHES"] ?? "").split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            values[name] = pair.count == 2 ? String(pair[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        return SwitchBoard(values: values)
    }

    /// Installs the process board once; later installation is a programming error.
    public static func install(_ board: SwitchBoard) {
        state.withLock {
            precondition($0.installed == nil, "SwitchBoard can only be installed once")
            $0.installed = board
        }
    }

    /// Uses the task override, installed board, or the environment read once for this process.
    public static var current: SwitchBoard {
        testing ?? state.withLock { $0.installed } ?? environment
    }

    /// Returns the selected arm, recording an unknown value before using the fallback.
    public func arm<Arm: RawRepresentable & Sendable>(
        _ name: String,
        default fallback: Arm
    ) -> Arm where Arm.RawValue == String {
        guard let value = values[name] else { return fallback }
        guard let arm = Arm(rawValue: value) else {
            Self.state.withLock { $0.invalid[name] = value }
            return fallback
        }
        return arm
    }

    /// Values refused by an arm reader during this process.
    public static var invalid: [String: String] { state.withLock { $0.invalid } }

    /// Writes refused names and values on one line, escaping control characters from the environment.
    public static func reportInvalidValues(write: (String) -> Void = {
        FileHandle.standardError.write(Data($0.utf8))
    }) {
        let values = invalid
        guard !values.isEmpty else { return }
        write(values.keys.sorted().map { "\(String(reflecting: $0))=\(String(reflecting: values[$0] ?? ""))" }
            .joined(separator: ",") + "\n")
    }
}
