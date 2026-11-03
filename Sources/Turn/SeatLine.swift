import AutomationMCP
import AutomationRuntime
import Foundation

/// SeatLine writes the pre-turn text for both hosts, with instructions outside the bounded facts block.
nonisolated public struct SeatLine: Sendable {
    public enum Piece: Sendable, Equatable {
        case stoppedTask
        case reviewAfterPerson
    }

    /// Budget limits characters after escaping, including separators and data tags.
    public struct Budget: Sendable, Equatable {
        public let instructions: Int
        public let facts: Int
        public static let standard = Budget(instructions: 600, facts: 400)

        public init(
            instructions: Int,
            facts: Int
        ) {
            self.instructions = instructions
            self.facts = facts
        }
    }

    public static let dataTag = "braus_state"

    /// Preserves the original notice, seat and review order byte for byte.
    @MainActor
    public static func legacy(
        notice: String?,
        seat: SeatFacts?,
        reviewing: Bool
    ) -> String? {
        let pieces = [notice, seat?.legacyText, reviewing ? TurnInstructions.humanInterventionInstructions : nil]
            .compactMap { $0 }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    /// Renders complete instructions followed by complete facts, or throws before any provider call.
    public static func render(
        pieces: [Piece],
        seat: SeatFacts?,
        task: SeatTaskFacts?,
        budget: Budget = .standard
    ) throws -> String? {
        var instructions: [String] = []
        if pieces.contains(.stoppedTask) {
            instructions.append(ModelText.text(.init(rawValue: TaskCycleArm.current == .v2
                ? "task_cycle.stopped.v2" : "seat_line.stopped.v2")))
        }
        if pieces.contains(.reviewAfterPerson) {
            instructions.append(ModelText.text(.init(rawValue: "seat_line.review.v2")))
        }
        guard instructions.joined(separator: "\n\n").count <= budget.instructions else {
            throw SeatLineError.instructionsOverBudget
        }

        var required: [String] = []
        var app: String?
        if let seat {
            required.append(text(seat.session ? "seat_line.session.open.v2" : "seat_line.session.closed.v2"))
            if let application = seat.application,
               application.name.count <= 80, application.bundleID.count <= 160 {
                app = text("seat_line.app.label.v2")
                    + "{\"name\":\(try quote(application.name)),\"bundle\":\(try quote(application.bundleID)),"
                    + "\"state\":\(try quote(text(seat.session ? "seat_line.current.v2" : "seat_line.last.v2")))}"
            }
            let missing = Permission.allCases.filter { seat.missingPermissions.contains(text($0.textKey)) }
            if !missing.isEmpty {
                required.append(text("seat_line.permissions.v2") + (try missing.map { try quote(text($0.textKey)) })
                    .joined(separator: ", "))
            }
        }
        if let task {
            var line = text(task.isOpen ? "seat_line.task.open.v2" : "seat_line.task.none.v2")
            if task.isOpen, let done = task.rowsDone, let total = task.rowsTotal {
                line += ModelText.render(.init(rawValue: "seat_line.rows.v2"),
                    ["done": .count(done), "total": .count(total)])
            }
            required.append(line)
        }
        var learned = task?.learnedForApp.map {
            ModelText.render(.init(rawValue: "seat_line.learned.v2"), ["count": .count($0)])
        }
        func block() -> String? {
            var lines = required
            if let app { lines.insert(app, at: seat == nil ? 0 : 1) }
            if let learned { lines.append(learned) }
            guard !lines.isEmpty else { return nil }
            return "<\(dataTag)>\n" + lines.joined(separator: "\n") + "\n</\(dataTag)>"
        }
        if let text = block(), text.count > budget.facts { learned = nil }
        if let text = block(), text.count > budget.facts { app = nil }
        if let text = block() {
            guard text.count <= budget.facts else { throw SeatLineError.factsOverBudget }
            instructions.append(text)
        }
        return instructions.isEmpty ? nil : instructions.joined(separator: "\n\n")
    }

    private enum Permission: CaseIterable {
        case accessibility
        case keyboardAndMouse
        case screenRecording

        var textKey: String {
            switch self {
            case .accessibility: "seat_line.accessibility.v2"
            case .keyboardAndMouse: "seat_line.keyboard.v2"
            case .screenRecording: "seat_line.screen.v2"
            }
        }
    }

    private static func text(_ key: String) -> String {
        ModelText.text(.init(rawValue: key))
    }

    private static func quote(_ value: String) throws -> String {
        let encoded = try JSONEncoder().encode(value)
        return String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}

/// SeatLineError rejects an insufficient budget or an incompatible tool surface before a turn is sent.
nonisolated public enum SeatLineError: Error, Sendable, Equatable {
    case instructionsOverBudget
    case factsOverBudget
    case incompatibleSurface
}
