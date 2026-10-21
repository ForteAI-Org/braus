//
//  CallReconciliation.swift
//  Braus
//

import EngineCore
import Foundation

/// ExecutorRecord is the process that ran a call (P2-06): an instance identifier made at its start, its source and its
/// process identifier. Whether it still runs is no fact of the archive: its lock says it (`MemoryExecutor`).
public struct ExecutorRecord: Sendable, Equatable {
    public let executorID: String
    public let source: String
    public let processID: Int32
    public let startedAtMS: Int64

    public init(executorID: String, source: String, processID: Int32, startedAtMS: Int64) {
        self.executorID  = executorID
        self.source      = source
        self.processID   = processID
        self.startedAtMS = startedAtMS
    }
}

/// CallReconciliation is what later evidence says of an earlier call (P2-06), appended in order and never rewriting the
/// call's own end: its executor ended while it was started, a result came after it concluded, a later completed call
/// read whether its effect happened (with that call as evidence), or the person acknowledged it. A finding is its
/// declarer's: Braus's, the agent's or the person's.
public struct CallReconciliation: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case executorTerminated = "executor_terminated"
        case lateResult         = "late_result"
        case observed, acknowledged
    }

    public enum Finding: String, Sendable, Equatable, CaseIterable {
        case happened
        case notHappened = "not_happened"
        case unknown
    }

    public enum Declarer: String, Sendable, Equatable, CaseIterable {
        case braus, agent, person
    }

    public let callEventID: String
    public let kind: Kind
    public let finding: Finding?
    public let evidenceEventID: String?
    public let declaredBy: Declarer
    public let recordedAtMS: Int64
    public let detail: String?

    public init(callEventID: String, kind: Kind, finding: Finding? = nil, evidenceEventID: String? = nil,
                declaredBy: Declarer, recordedAtMS: Int64, detail: String? = nil) throws {
        func refuse(_ field: String) -> OperationFactError { .invalid(.emptyText(field: field)) }
        guard !callEventID.isEmpty else { throw refuse("call") }
        guard (kind == .observed) == (evidenceEventID != nil), kind != .observed || finding != nil else { throw refuse("evidence") }
        guard kind == .observed || kind == .acknowledged || finding == nil else { throw refuse("finding") }
        guard kind != .executorTerminated || declaredBy == .braus else { throw refuse("declarer") }
        self.callEventID     = callEventID
        self.kind            = kind
        self.finding         = finding
        self.evidenceEventID = evidenceEventID
        self.declaredBy      = declaredBy
        self.recordedAtMS    = recordedAtMS
        self.detail          = detail.map { String($0.prefix(256)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the call is resolved by this fact: the effect was found to have happened or not, or the person
    /// acknowledged it. An executor's end, a late result or an unknown finding resolve nothing.
    public var resolves: Bool {
        switch kind {
            case .observed    : finding == .happened || finding == .notHappened
            case .acknowledged: true
            case .executorTerminated, .lateResult: false
        }
    }
}

/// UnresolvedCall is a call of a producer whose effect is not known and no later fact resolved (P2-06): one started that
/// never ended and whose executor is not the asking one, or one that concluded with its effect uncertain. A repeat of it,
/// or a call that names the resource it reached, is blocked until it is reconciled; a refusal blocks more (`ActionBarrier`).
public struct UnresolvedCall: Sendable {

    public enum Reason: String, Sendable, Equatable {
        case neverEnded      = "never_ended"
        case effectUncertain = "effect_uncertain"
    }

    public let eventID: String
    public let request: AgentCallRequest
    public let reason: Reason
    public let resource: String?

    public init(eventID: String, request: AgentCallRequest, reason: Reason, resource: String?) {
        self.eventID  = eventID
        self.request  = request
        self.reason   = reason
        self.resource = resource
    }

    /// Whether `other` would repeat this call: the same tool with the same arguments, a value the record withheld
    /// (`ValueMinimization.marker`) matching any, since it cannot be told apart.
    public func isRepeated(by other: AgentCallRequest) -> Bool {
        guard request.tool == other.tool else { return false }
        let stored = request.arguments, offered = other.arguments
        guard stored.count == offered.count else { return false }
        return zip(stored, offered).allSatisfy { kept, asked in
            guard kept.name == asked.name, kept.position == asked.position else { return false }
            if case .text(let text) = kept.value, text.contains(ValueMinimization.marker) {
                guard case .text(let offered) = asked.value else { return false }
                return Self.matches(offered, withheldAs: text)
            }
            return kept.value == asked.value
        }
    }

    /// Whether `offered` is what the kept text could have been: each marker stands for any text in its own place, and
    /// everything around the markers is the same, so an object with one field withheld matches only the objects whose
    /// other fields are equal.
    static func matches(_ offered: String, withheldAs kept: String) -> Bool {
        let pieces = kept.components(separatedBy: ValueMinimization.marker)
        guard let first = pieces.first, let last = pieces.last, offered.hasPrefix(first), offered.hasSuffix(last),
              offered.count >= first.count + last.count else { return false }
        var rest = offered.dropFirst(first.count).dropLast(last.count)
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            guard let found = rest.range(of: piece) else { return false }
            rest = rest[found.upperBound...]
        }
        return true
    }

    /// Whether `other` depends on this call's possible effect: it names the resource the call reached.
    public func isDepended(on other: AgentCallRequest) -> Bool {
        guard let resource, resource.count >= 3 else { return false }
        return other.arguments.contains { argument in
            if case .text(let text) = argument.value { return text.contains(resource) }
            return false
        }
    }
}
