import AutomationMCP

/// TaskStateSection is a tagged block of net facts, with call provenance and explicit observation limits.
public nonisolated struct TaskStateSection: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case request, facts, decisions, failedAttempts, loaded, todo, lastOutcome, scene, goal
        case personIntervention
    }

    public enum Token: Sendable, Equatable {
        case literal(String), operand(String)

        var text: String {
            switch self {
            case .literal(let text), .operand(let text): text
            }
        }
    }

    public let kind: Kind
    public let lines: [[Token]]
    public let unobserved: [String]
    public let provenance: [Int]

    public init(kind: Kind, lines: [[Token]], unobserved: [String] = [], provenance: [Int] = []) {
        self.kind = kind
        self.lines = lines
        self.unobserved = unobserved
        self.provenance = provenance
    }

    static func empty(_ kind: Kind) -> Self {
        Self(kind: kind, lines: [], unobserved: [text("noEvidence")])
    }

    static func text(_ name: String) -> String {
        ModelText.text(.init(rawValue: "task_state.\(name)"))
    }

    static func provenance(_ sequence: Int) -> String {
        ModelText.render(.init(rawValue: "task_state.provenance"), ["count": .count(sequence)])
    }

    func rendered() -> String {
        let prefix = "\(kind.rawValue)."
        return ([Self.text(prefix + "open"), Self.text(prefix + "heading")]
            + lines.map { $0.map(\.text).joined() }
            + unobserved.map { Self.text("unobserved") + $0 }
            + [Self.text(prefix + "close")]).joined(separator: "\n")
    }
}
