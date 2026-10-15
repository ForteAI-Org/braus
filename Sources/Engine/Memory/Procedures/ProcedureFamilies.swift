//
//  ProcedureFamilies.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

/// ProcedureFamilies groups the parts of different procedures that hold one method (`ProcedureMethod`): the phases
/// that open a file, save a copy or close a window in fifteen procedures are one subprocedure learned fifteen times,
/// and the steps that press the same button are one step. A family is what a consolidation would keep once, with the
/// labels its members were given and the one most of them share. Nothing here changes a procedure: it is the
/// deterministic measure of what the memory could share, and the source of the labels Braus offers an agent for a
/// phase it learned before (14 October 2026).
public enum ProcedureFamilies {

    /// Member is one part of one version: a subprocedure, a step or a whole procedure, with its label and its method.
    public struct Member: Sendable, Equatable {
        public let routeID: String
        public let partID: String
        public let kind: PartKind
        public let label: String?
        public let firstPosition: Int
        public let lastPosition: Int
        /// One signature per step of the part.
        public let method: [String]

        public init(routeID: String, partID: String, kind: PartKind, label: String?, firstPosition: Int, lastPosition: Int,
                    method: [String]) {
            self.routeID       = routeID
            self.partID        = partID
            self.kind          = kind
            self.label         = label
            self.firstPosition = firstPosition
            self.lastPosition  = lastPosition
            self.method        = method
        }
    }

    /// Family is the parts that hold one method, the first member's method standing for them.
    public struct Family: Sendable, Equatable {
        public let kind: PartKind
        public let method: [String]
        public let members: [Member]

        /// The labels the members were given, with how many members each, most given first.
        public var labels: [(label: String, count: Int)] {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for label in members.compactMap(\.label) {
                if counts[label] == nil { order.append(label) }
                counts[label, default: 0] += 1
            }
            return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.count > $1.count }
        }

        /// The label most members share, the earliest given among equals: the one to offer for a new member.
        public var label: String? { labels.first?.label }

        /// How many versions hold the family.
        public var procedures: Int { Set(members.map(\.routeID)).count }
    }

    /// The families of `members`, each kind apart, in the order their first member came: a member joins the first family
    /// of its kind whose method is the same as its own (`ProcedureMethod.same`).
    public static func families(of members: [Member]) -> [Family] {
        var grouped: [(kind: PartKind, method: [String], members: [Member])] = []
        for member in members where !member.method.isEmpty {
            if let index = grouped.firstIndex(where: { $0.kind == member.kind && ProcedureMethod.same($0.method, member.method) }) {
                grouped[index].members.append(member)
            } else {
                grouped.append((member.kind, member.method, [member]))
            }
        }
        return grouped.map { Family(kind: $0.kind, method: $0.method, members: $0.members) }
    }

    /// KnownPhase is a run of a candidate's steps that holds the method of a phase learned in other procedures.
    public struct KnownPhase: Sendable, Equatable {
        public let firstPosition: Int
        public let lastPosition: Int
        public let label: String
        public let procedures: Int

        public init(firstPosition: Int, lastPosition: Int, label: String, procedures: Int) {
            self.firstPosition = firstPosition
            self.lastPosition  = lastPosition
            self.label         = label
            self.procedures    = procedures
        }
    }

    /// The runs of `steps` (one signature per candidate step, in order) that hold the method of a family of phases, longest
    /// families first and never overlapping, in the candidate's order. A family of one step is no phase to offer.
    public static func knownPhases(in steps: [String], families: [Family]) -> [KnownPhase] {
        var taken = Set<Int>()
        var found: [KnownPhase] = []
        let phases = families.filter { $0.kind == .subprocedure && $0.method.count > 1 && $0.label != nil }
            .sorted { ($0.method.count, $0.members.count) > ($1.method.count, $1.members.count) }
        for family in phases {
            let length = family.method.count
            guard length <= steps.count else { continue }
            var start = 0
            while start + length <= steps.count {
                let range = start..<(start + length)
                if !range.contains(where: taken.contains), ProcedureMethod.same(Array(steps[range]), family.method) {
                    found.append(KnownPhase(firstPosition: range.lowerBound, lastPosition: range.upperBound - 1,
                                            label: family.label ?? "", procedures: family.procedures))
                    taken.formUnion(range)
                    start += length
                } else {
                    start += 1
                }
            }
        }
        return found.sorted { $0.firstPosition < $1.firstPosition }
    }

    /// Adaptation is a current version made by a task that chose a learned source and did the work another way: the two
    /// are one goal reached by two methods, a variant of the source in all but its record (14 October 2026). `declared` is
    /// what the agent reported of the selection (followed, adapted, abandoned, not executed), nil when it reported nothing.
    public struct Adaptation: Sendable, Equatable {
        public let routeID: String
        public let sourceRouteID: String
        public let declared: String?

        public init(routeID: String, sourceRouteID: String, declared: String?) {
            self.routeID       = routeID
            self.sourceRouteID = sourceRouteID
            self.declared      = declared
        }
    }
}
