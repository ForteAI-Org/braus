//
//  TypingGesture.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

/// TypingGesture retains one activity span per recipient, without key identity, content or count.
/// The tap's existing timer settles it after quiet time; other input flushes it immediately.
struct TypingGesture {
    static let quiet = 2.0
    private var pending: InputRecord?

    var deadline: Double? { pending.map { $0.endedAt + Self.quiet } }

    mutating func append(_ record: InputRecord) -> InputRecord? {
        precondition(record.kind == .typing)
        guard var previous = pending else {
            pending = record
            return nil
        }
        guard previous.targetPID == record.targetPID,
              record.startedAt - previous.endedAt < Self.quiet else {
            pending = record
            return previous
        }
        previous.timestamp = record.timestamp
        previous.revision = record.revision
        pending = previous
        return nil
    }

    mutating func settled(at now: Double) -> InputRecord? {
        guard let deadline, now >= deadline else { return nil }
        return take()
    }

    mutating func take() -> InputRecord? {
        defer { pending = nil }
        return pending
    }
}
