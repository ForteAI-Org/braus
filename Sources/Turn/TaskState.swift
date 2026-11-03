import AutomationRuntime
import EngineCore
import Memory

/// TaskState keeps the open task from typed inputs, independently of storage, tools and model messages.
/// It retains the latest 128 failures and 2,048 input keys, counting older entries dropped from each.
/// Idempotence covers retained keys; the latest fact per tool and subject, todo and whole scene remain net state.
public nonisolated struct TaskState: Sendable, Equatable {
    public private(set) var sections: [TaskStateSection.Kind: TaskStateSection]
    private var appliedKeys: Set<String> = []
    private var appliedKeyOrder: [String] = []
    public private(set) var droppedFailures = 0
    public private(set) var droppedInputKeys = 0
    var retainedInputKeyCount: Int { appliedKeys.count }
    private var sectionCharacters: [TaskStateSection.Kind: Int] = [:]
    private var renderedCharacters = 0
    private var todoRows: [TodoRow] = []
    private var taskID: String?
    private var sceneRevision: Int?
    private var facts: [FactKey: Record] = [:]
    private var failures: [Record] = []
    private var loaded: [LoadKey: Record] = [:]

    private struct FactKey: Sendable, Equatable, Hashable {
        let tool: String
        let subject: String?
    }

    private enum LoadKey: Sendable, Equatable, Hashable {
        case schema(String), guide(String, String)
    }

    private struct Record: Sendable, Equatable {
        let line: [TaskStateSection.Token]
        let sequence: Int?
        var unobserved: [String] = []
    }

    public init() {
        sections = Dictionary(uniqueKeysWithValues: TaskStateSection.Kind.allCases.map { ($0, .empty($0)) })
        sectionCharacters = sections.mapValues { $0.rendered().count }
        renderedCharacters = sectionCharacters.values.reduce(0, +) + max(0, sections.count - 1) * 2
    }

    /// Applies a producer fact exactly once, in arrival order, without examining rendered log messages.
    public mutating func apply(_ input: TaskStateInput) {
        guard appliedKeys.insert(input.key).inserted else { return }
        appliedKeyOrder.append(input.key)
        if appliedKeyOrder.count > 2048 {
            appliedKeys.remove(appliedKeyOrder.removeFirst())
            droppedInputKeys += 1
        }
        switch input.fact {
        case .request(let text):
            replaceSection(.init(kind: .request, lines: [[.operand(text)]]))
            updateGoal()
        case .personIntervention(let digest): setPersonIntervention(digest: digest)
        case .todo(let event):
            if let taskID, taskID != event.taskID { clearTaskEvidence() }
            taskID = event.taskID
            todoRows = event.rows
            replaceSection(.init(kind: .todo, lines: todoRows.map(Self.todoLine)))
            if event.kind == .revised || event.kind == .stopped {
                let line: [TaskStateSection.Token] = event.kind == .stopped
                    ? [.literal(TaskStateSection.text("stopped"))]
                    : [.literal(TaskStateSection.text("revised")),
                       .operand(event.reason ?? TaskStateSection.text("reasonUnobserved"))]
                replaceSection(.init(kind: .decisions, lines: (sections[.decisions]?.lines ?? []) + [line]))
            }
            updateGoal()
        case .callFinished(let tool, let subject, let outcome):
            let line = Self.callLine(
                tool: tool,
                subject: subject,
                result: .literal(outcome?.row ?? TaskStateSection.text("finished")),
                sequence: input.sequence
            )
            var record = Record(line: line, sequence: input.sequence)
            if let outcome {
                if case .unknown = outcome.effect {
                    record.unobserved = [subject ?? tool]
                }
                facts[FactKey(tool: tool, subject: subject)] = record
                let records = facts.keys.sorted {
                    if $0.tool != $1.tool { return $0.tool < $1.tool }
                    if $0.subject == nil { return $1.subject != nil }
                    return ($0.subject ?? "") < ($1.subject ?? "")
                }.compactMap { facts[$0] }
                set(.facts, records: records)
                if outcome.effect == .absent || outcome.gesture == .notSent { appendFailure(record) }
            } else { record.unobserved = [TaskStateSection.text("noOutcome")] }
            set(.lastOutcome, records: [record])
        case .callFailed(let tool, let reason):
            let record = Record(line: Self.callLine(tool: tool, subject: nil, result: .operand(reason),
                                                    sequence: input.sequence), sequence: input.sequence)
            appendFailure(record)
            set(.lastOutcome, records: [record])
        case .loaded(let item):
            let key: LoadKey
            let line: [TaskStateSection.Token]
            switch item {
            case .schema(let capability):
                key = .schema(capability)
                line = [.literal(TaskStateSection.text("schema")), .operand(capability)]
            case .guide(let id, let section):
                key = .guide(id, section)
                line = [.literal(TaskStateSection.text("guide")), .operand(id), .literal(TaskStateSection.text("pathSeparator")), .operand(section)]
            }
            loaded[key] = Record(line: line + Self.provenance(input.sequence), sequence: input.sequence)
            set(.loaded, records: loaded.values.sorted { $0.line.map(\.text).joined() < $1.line.map(\.text).joined() })
        }
    }

    /// Retains only a newer whole scene. Equal and older revisions cannot replace the current base.
    public mutating func setScene(_ scene: TaskStateScene) {
        guard sceneRevision.map({ scene.revision > $0 }) ?? true else { return }
        sceneRevision = scene.revision
        replaceSection(.init(kind: .scene, lines: [[.operand(scene.text)]]))
    }

    /// Preserves the digest as an operand; observations absent from that digest remain explicitly unknown.
    public mutating func setPersonIntervention(digest text: String) {
        replaceSection(.init(kind: .personIntervention, lines: [[.operand(text)]],
            unobserved: [TaskStateSection.text("digestUnobserved")]))
    }

    public func rendered() -> String {
        TaskStateSection.Kind.allCases.map { (sections[$0] ?? .empty($0)).rendered() }.joined(separator: "\n\n")
    }

    /// Checks completeness, the whole scene revision and the token ceiling. A small state is valid.
    public func check(ceilingTokens: Int = 3000, latestSceneRevision: Int?) -> [TaskStateProblem] {
        var problems = checkSections(sections)
        if let latestSceneRevision, (sceneRevision ?? 0) < latestSceneRevision {
            problems.append(.staleScene(revision: sceneRevision ?? 0))
        }
        let tokens = TokenEstimate.tokens(characterCount: renderedCharacters)
        if tokens > ceilingTokens { problems.append(.overBudget(tokens: tokens)) }
        return problems
    }

    /// Checks a section projection against the retained typed todo and failure records.
    func checkSections(_ candidate: [TaskStateSection.Kind: TaskStateSection]) -> [TaskStateProblem] {
        var problems: [TaskStateProblem] = []
        for row in todoRows {
            let prefix = Array(Self.todoLine(row).prefix(3))
            if candidate[.todo]?.lines.contains(where: { Array($0.prefix(3)) == prefix }) != true {
                problems.append(.todoItemWithoutState(row.id))
            }
        }
        for failure in failures.sorted(by: { ($0.sequence ?? 0) < ($1.sequence ?? 0) }) {
            guard let call = failure.sequence else { continue }
            if candidate[.failedAttempts]?.lines.contains(failure.line) != true
                || candidate[.failedAttempts]?.provenance.contains(call) != true {
                problems.append(.missingFailure(call: call))
            }
        }
        return problems
    }

    /// Flags only an exact row title or ID match for a delivered first gesture, without interpreting task prose.
    public func redoneClosedItem(firstAction: TaskStateInput) -> TodoRowID? {
        guard case .callFinished(_, let subject?, let outcome?) = firstAction.fact,
              outcome.gesture != .notSent else { return nil }
        return todoRows.first {
            ($0.status == .done || $0.status == .abandoned) && ($0.title == subject || $0.id.rawValue == subject)
        }?.id
    }

    private mutating func appendFailure(_ record: Record) {
        failures.append(record)
        if failures.count > 128 {
            failures.removeFirst()
            droppedFailures += 1
        }
        set(.failedAttempts, records: failures)
    }

    private mutating func clearTaskEvidence() {
        facts.removeAll()
        failures.removeAll()
        loaded.removeAll()
        for kind in TaskStateSection.Kind.allCases where kind != .request && kind != .scene {
            replaceSection(.empty(kind))
        }
    }

    private mutating func set(_ kind: TaskStateSection.Kind, records: [Record]) {
        replaceSection(.init(kind: kind, lines: records.map(\.line),
            unobserved: records.flatMap(\.unobserved), provenance: Array(Set(records.compactMap(\.sequence))).sorted()))
    }

    private mutating func replaceSection(_ section: TaskStateSection) {
        let count = section.rendered().count
        renderedCharacters += count - (sectionCharacters[section.kind] ?? 0)
        sectionCharacters[section.kind] = count
        sections[section.kind] = section
    }

    private mutating func updateGoal() {
        var lines: [[TaskStateSection.Token]] = []
        if let request = sections[.request]?.lines.first?.first?.text {
            let excerpt = request.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            lines.append([.literal(TaskStateSection.text("goal")),
                          .operand(String(excerpt.prefix(160)) + (excerpt.count > 160 ? TaskStateSection.text("ellipsis") : ""))])
        }
        if let next = todoRows.first(where: { $0.status == .inProgress })
            ?? todoRows.first(where: { $0.status == .pending }) {
            lines.append([.literal(TaskStateSection.text("next")), .operand(next.id.rawValue),
                          .literal(TaskStateSection.text("separator")), .operand(next.title)])
        }
        replaceSection(lines.isEmpty ? .empty(.goal) : .init(kind: .goal, lines: lines))
    }

    private static func todoLine(_ row: TodoRow) -> [TaskStateSection.Token] {
        [.operand(row.id.rawValue), .literal(TaskStateSection.text("separator")), .literal(row.status.rawValue),
         .literal(TaskStateSection.text("separator")), .operand(row.title)]
    }

    private static func callLine(
        tool: String,
        subject: String?,
        result: TaskStateSection.Token,
        sequence: Int?
    ) -> [TaskStateSection.Token] {
        [.operand(tool)] + (subject.map { [.literal(" "), .operand($0)] } ?? [])
            + [.literal(": "), result] + provenance(sequence)
    }

    private static func provenance(_ sequence: Int?) -> [TaskStateSection.Token] {
        sequence.map { [.literal(TaskStateSection.provenance($0))] } ?? []
    }
}

/// TaskStateScene is the latest whole scene sent, with its owner's revision; it carries no scene policy behavior.
public nonisolated struct TaskStateScene: Sendable, Equatable {
    public let revision: Int
    public let text: String

    public init(revision: Int, text: String) {
        self.revision = revision
        self.text = text
    }
}

/// LatestSceneProviding borrows the scene owner's latest whole answer on the main actor. Nil until connected.
public typealias LatestSceneProviding = @MainActor () -> TaskStateScene?

public nonisolated enum TaskStateProblem: Sendable, Equatable {
    case todoItemWithoutState(TodoRowID)
    case missingFailure(call: Int)
    case staleScene(revision: Int)
    case overBudget(tokens: Int)
}
