import Memory

/// TodoEvent reports a committed plan change, including buffered recorded gestures for row expansion.
public nonisolated struct TodoEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case drafted, revised, rowStarted, rowFinished, stopped }
    public enum Origin: Sendable, Equatable { case model, braus, person }
    public let taskID: String
    public let revision: Int
    public let kind: Kind
    public let rows: [TodoRow]
    public let changed: [TodoRowID]
    public let verdict: TodoRevision.RowVerdict?
    public let reason: String?
    public let origin: Origin
    public let gestures: [TodoGesture]

    public init(_ revision: TodoRevision, origin: Origin, gestures: [TodoGesture] = [], previousRows: [TodoRow] = []) {
        taskID = revision.taskID
        self.revision = revision.number
        rows = revision.rows
        self.origin = origin
        self.gestures = gestures
        switch revision.change {
        case .drafted: kind = .drafted; changed = rows.map(\.id); verdict = nil; reason = nil
        case .revised(let why):
            kind = .revised
            changed = rows.enumerated().compactMap { index, row in
                guard let oldIndex = previousRows.firstIndex(where: { $0.id == row.id }),
                      oldIndex == index, previousRows[oldIndex] == row else { return row.id }
                return nil
            }
            verdict = nil
            reason = why
        case .rowStarted(let row): kind = .rowStarted; changed = [row]; verdict = nil; reason = nil
        case .rowFinished(let row, let result): kind = .rowFinished; changed = [row]; verdict = result; reason = nil
        case .stopped: kind = .stopped; changed = rows.filter { row in
            row.status == .abandoned && previousRows.first(where: { $0.id == row.id })?.status != .abandoned
        }.map(\.id); verdict = nil; reason = nil
        }
    }
}

/// TodoGesture identifies an archived gesture and its bounded outcome, without a second level in the plan.
public nonisolated struct TodoGesture: Sendable, Equatable {
    public let eventID: String
    public let row: TodoRowID
    public let outcome: String
    public init(eventID: String, row: TodoRowID, outcome: String) {
        self.eventID = eventID
        self.row = row
        self.outcome = outcome
    }
}
