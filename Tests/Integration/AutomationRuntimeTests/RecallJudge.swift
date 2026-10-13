//
//  RecallJudge.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

@testable import AutomationRuntime
import Foundation
import LocalMCP
import Memory

/// RecallJudge compares what the Recall answered for a corpus query with the query's expectations, need by need.
/// A selection is right when it is one of the accepted intervals; it is incompatible when it is delivered from a
/// version the query excludes (a near method with another result, a superseded version) or holds a step the query
/// forbids (work already done); a complete coverage is false when the query does not accept complete, or the
/// selection is incompatible or not one of the accepted intervals.
/// Only delivered selections count: an ambiguity between alternatives delivers no detail of either.
nonisolated enum RecallJudge {

    /// Verdict is one need's (or one query's) judgement.
    struct Verdict: Sendable, Codable, Equatable {
        var coverageRight = true
        var selectionExpected = false
        var selectionRight = true
        var incompatible = false
        var falseComplete = false
        var completeWrong = false
        var absenceExpected = false
        var absenceRight = true
        var bindingsExpected = false
        var bindingsRight = true
        var conditionsExpected = false
        var conditionsRight = true
        var alternativesExpected = false
        var alternativesRight = true
        var excludedExpected = false
        var excludedRight = true
        /// Whether the query marks its needs critical: an incompatible delivery or a false complete misleads into harm.
        var critical = false

        var correct: Bool {
            coverageRight && selectionRight && !incompatible && absenceRight && bindingsRight && conditionsRight && alternativesRight
                && excludedRight
        }
    }

    /// Score sums verdicts: queries for correctness and overall coverage, needs for the rest.
    struct Score: Sendable, Codable, Equatable {
        var queries = 0
        var correct = 0
        var coverageRight = 0
        var needs = 0
        var selectionExpected = 0
        var selectionRight = 0
        var incompatible = 0
        var falseComplete = 0
        var completeWrong = 0
        var absenceExpected = 0
        var absenceRight = 0
        var bindingsExpected = 0
        var bindingsRight = 0
        var conditionsExpected = 0
        var conditionsRight = 0
        var alternativesExpected = 0
        var alternativesRight = 0
        var excludedExpected = 0
        var excludedRight = 0
        var criticalIncompatible = 0
        var criticalFalseComplete = 0

        /// The errors that mislead an agent: an incompatible delivery or a complete coverage that is false.
        var unsafe: Int { incompatible + falseComplete }
        /// Those errors on the needs a query marks critical.
        var criticalUnsafe: Int { criticalIncompatible + criticalFalseComplete }

        /// Two scores summed, as two conditions of one measure are.
        static func + (a: Score, b: Score) -> Score {
            var sum = a
            sum.queries += b.queries; sum.correct += b.correct; sum.coverageRight += b.coverageRight; sum.needs += b.needs
            sum.selectionExpected += b.selectionExpected; sum.selectionRight += b.selectionRight; sum.incompatible += b.incompatible
            sum.falseComplete += b.falseComplete; sum.completeWrong += b.completeWrong; sum.absenceExpected += b.absenceExpected
            sum.absenceRight += b.absenceRight; sum.bindingsExpected += b.bindingsExpected; sum.bindingsRight += b.bindingsRight
            sum.conditionsExpected += b.conditionsExpected; sum.conditionsRight += b.conditionsRight
            sum.alternativesExpected += b.alternativesExpected; sum.alternativesRight += b.alternativesRight
            sum.excludedExpected += b.excludedExpected; sum.excludedRight += b.excludedRight
            sum.criticalIncompatible += b.criticalIncompatible; sum.criticalFalseComplete += b.criticalFalseComplete
            return sum
        }

        mutating func add(query: Verdict, needs: [Verdict]) {
            queries += 1
            if query.correct { correct += 1 }
            if query.coverageRight { coverageRight += 1 }
            for need in needs {
                self.needs += 1
                if need.selectionExpected { selectionExpected += 1; if need.selectionRight { selectionRight += 1 } }
                if need.incompatible { incompatible += 1 }
                if need.falseComplete { falseComplete += 1 }
                if need.completeWrong { completeWrong += 1 }
                if need.absenceExpected { absenceExpected += 1; if need.absenceRight { absenceRight += 1 } }
                if need.bindingsExpected { bindingsExpected += 1; if need.bindingsRight { bindingsRight += 1 } }
                if need.conditionsExpected { conditionsExpected += 1; if need.conditionsRight { conditionsRight += 1 } }
                if need.alternativesExpected { alternativesExpected += 1; if need.alternativesRight { alternativesRight += 1 } }
                if need.excludedExpected { excludedExpected += 1; if need.excludedRight { excludedRight += 1 } }
                if need.critical && need.incompatible { criticalIncompatible += 1 }
                if need.critical && need.falseComplete { criticalFalseComplete += 1 }
            }
        }
    }

    static func strings(_ value: JSONValue) -> [String] {
        if let text = value.string { return [text] }
        return value.array?.compactMap(\.string) ?? []
    }

    static func number(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(exactly: number) }
        return nil
    }

    /// The query's verdict and its needs': a query naming needs is judged need by need and on its overall coverage.
    static func judge(_ query: JSONValue, outcomes: [NeedOutcome], sources: [String: RecallSource], values: [TaskValue],
                      learned: [String: RecallCorpus.Learned]) -> (query: Verdict, needs: [Verdict]) {
        let expect = query["expect"]
        let critical = query["critical"].bool == true
        guard let expectedNeeds = expect["needs"].array else {
            guard let outcome = outcomes.first else { return (Verdict(coverageRight: false), []) }
            var verdict = need(expect, outcome, sources: sources, values: values, learned: learned)
            verdict.critical = critical
            return (verdict, [verdict])
        }
        let needs = zip(expectedNeeds, outcomes).map { expected, outcome -> Verdict in
            var verdict = need(expected, outcome, sources: sources, values: values, learned: learned)
            verdict.critical = critical
            return verdict
        }
        var verdict = Verdict()
        verdict.coverageRight = strings(expect["coverage"]).contains(NeedOutcome.overall(outcomes).rawValue)
            && needs.count == expectedNeeds.count && needs.allSatisfy(\.coverageRight)
        verdict.selectionRight = needs.allSatisfy(\.selectionRight)
        verdict.incompatible = needs.contains(where: \.incompatible)
        verdict.absenceRight = needs.allSatisfy(\.absenceRight)
        verdict.bindingsRight = needs.allSatisfy(\.bindingsRight)
        verdict.conditionsRight = needs.allSatisfy(\.conditionsRight)
        verdict.alternativesRight = needs.allSatisfy(\.alternativesRight)
        verdict.excludedRight = needs.allSatisfy(\.excludedRight)
        verdict.critical = critical
        return (verdict, needs)
    }

    /// One need's verdict.
    static func need(_ expect: JSONValue, _ outcome: NeedOutcome, sources: [String: RecallSource], values: [TaskValue],
                     learned: [String: RecallCorpus.Learned]) -> Verdict {
        var verdict = Verdict()
        let coverages = strings(expect["coverage"])
        verdict.coverageRight = coverages.contains(outcome.coverage.rawValue)
        // What the need delivered: the one selection, or the agent's tracts with contiguous tracts of one version joined.
        var tracts: [RecallSelection] = []
        for tract in outcome.delivered {
            if let last = tracts.last, last.routeID == tract.routeID, last.lastPosition + 1 == tract.firstPosition {
                tracts[tracts.count - 1] = RecallSelection(role: .selected, routeID: last.routeID, firstPosition: last.firstPosition,
                                                           lastPosition: tract.lastPosition, wholePartID: nil, relevance: last.relevance,
                                                           preparations: last.preparations, requirements: last.requirements + tract.requirements)
            } else {
                tracts.append(tract)
            }
        }
        let selected = tracts.count == 1 ? tracts.first : nil
        let requirements = tracts.flatMap(\.requirements)
        func interval(_ value: JSONValue) -> ClosedRange<Int>? {
            guard let steps = value.array, steps.count == 2, let first = number(steps[0]), let last = number(steps[1]), first <= last else {
                return nil
            }
            return (first - 1)...(last - 1)
        }
        // For a need nothing learned does, a preparation the request needs (selecting the very item to work on), delivered as
        // partial with the action left uncovered, is as right as nothing (corpus v5's `preparations`); never complete.
        let preparations = (expect["preparations"].array ?? []).compactMap { item -> ([String], ClosedRange<Int>)? in
            guard let routes = learned[item["knowledge"].string ?? ""]?.revisions, let steps = interval(item["steps"]) else { return nil }
            return (routes, steps)
        }
        let prepared = !preparations.isEmpty && !tracts.isEmpty && outcome.coverage == .partial && tracts.allSatisfy { tract in
            preparations.contains { $0.0.contains(tract.routeID) && $0.1.contains(tract.firstPosition) && $0.1.contains(tract.lastPosition) }
        }
        if expect["accept"] != .null {
            let accepted = (expect["accept"].array ?? []).compactMap { item -> (String, ClosedRange<Int>)? in
                guard let route = RecallCorpus.Learned.route(item["knowledge"].string ?? "", in: learned),
                      let steps = interval(item["steps"]) else { return nil }
                return (route, steps)
            }
            if accepted.isEmpty && expect["accept_plans"] == .null {
                verdict.selectionRight = tracts.isEmpty || prepared
            } else {
                verdict.selectionExpected = true
                verdict.selectionRight = selected.map { chosen in
                    accepted.contains { $0.0 == chosen.routeID && $0.1 == chosen.positions }
                } ?? false
            }
        }
        // A plan of several tracts: any one of the listed plans, tract for tract in order.
        if let plans = expect["accept_plans"].array {
            verdict.selectionExpected = true
            let matches = plans.contains { plan in
                let wanted = (plan.array ?? []).compactMap { item -> (String, ClosedRange<Int>)? in
                    guard let route = RecallCorpus.Learned.route(item["knowledge"].string ?? "", in: learned),
                          let steps = interval(item["steps"]) else { return nil }
                    return (route, steps)
                }
                return wanted.count == tracts.count && zip(wanted, tracts).allSatisfy { $0.0 == $1.routeID && $0.1 == $1.positions }
            }
            verdict.selectionRight = expect["accept"] == .null ? matches : verdict.selectionRight || matches
        }
        for chosen in tracts {
            let excluded = strings(expect["exclude"]).flatMap { reference -> [String] in
                reference.contains("@") ? [RecallCorpus.Learned.route(reference, in: learned)].compactMap { $0 }
                    : learned[reference]?.revisions ?? []
            }
            if excluded.contains(chosen.routeID) { verdict.incompatible = true }
            for forbidden in expect["forbid_steps"].array ?? [] {
                let routes = learned[forbidden["knowledge"].string ?? ""]?.revisions ?? []
                let steps = (forbidden["steps"].array ?? []).compactMap(number).map { $0 - 1 }
                if routes.contains(chosen.routeID), steps.contains(where: chosen.positions.contains) { verdict.incompatible = true }
            }
        }
        verdict.completeWrong = outcome.coverage == .complete && verdict.selectionExpected && !verdict.selectionRight
        verdict.falseComplete = outcome.coverage == .complete
            && (!coverages.contains("complete") || verdict.incompatible || verdict.completeWrong)
        if coverages == ["absent"] || !preparations.isEmpty {
            verdict.absenceExpected = true
            verdict.absenceRight = outcome.coverage == .absent || prepared
            if prepared { verdict.coverageRight = true }
        }
        if let bindings = expect["bindings"].object {
            verdict.bindingsExpected = true
            let candidates = RecallBinding.candidates(values)
            let parameters = tracts.flatMap { sources[$0.routeID]?.parameters ?? [] }
            verdict.bindingsRight = !tracts.isEmpty && bindings.allSatisfy { name, value in
                requirements.contains { requirement in
                    requirement.kind == .parameterBound
                        && parameters.first { $0.parameterID == requirement.parameterID }?.name == name
                        && candidates.first { $0.name == requirement.taskValueName }?.text == value.string
                }
            }
        }
        if let conditions = expect["conditions"].array?.compactMap(\.string) {
            verdict.conditionsExpected = true
            verdict.conditionsRight = !tracts.isEmpty && conditions.allSatisfy { kind in requirements.contains { $0.kind.rawValue == kind } }
        }
        if let excluded = expect["excluded"].array?.compactMap(\.string) {
            verdict.excludedExpected = true
            let named = Set(outcome.excluded.map(\.routeID))
            verdict.excludedRight = excluded.allSatisfy { reference in
                let routes = reference.contains("@") ? [RecallCorpus.Learned.route(reference, in: learned)].compactMap { $0 }
                    : learned[reference]?.revisions ?? []
                return routes.isEmpty || !named.isDisjoint(with: routes)
            }
        }
        if let alternatives = expect["alternatives"].array?.compactMap(\.string) {
            verdict.alternativesExpected = true
            let named = Set(outcome.alternatives.map(\.routeID))
            verdict.alternativesRight = outcome.coverage == .ambiguous && alternatives.allSatisfy {
                RecallCorpus.Learned.route($0, in: learned).map(named.contains) ?? false
            }
        }
        return verdict
    }

    /// A short reading of what was selected, for the reports: the knowledge, the steps from 1, the coverage.
    static func describe(_ outcomes: [NeedOutcome], learned: [String: RecallCorpus.Learned]) -> String {
        outcomes.map { outcome in
            func name(_ route: String) -> String {
                guard let item = learned.values.first(where: { $0.revisions.contains(route) }) else { return route }
                let revision = (item.revisions.firstIndex(of: route) ?? 0) + 1
                return item.revisions.count > 1 ? "\(item.id)@\(revision)" : item.id
            }
            var text = outcome.coverage.rawValue + (outcome.reason.map { "(\($0.rawValue))" } ?? "")
            for (index, selected) in outcome.delivered.enumerated() {
                text += (index == 0 ? " " : " + ") + "\(name(selected.routeID)) \(selected.firstPosition + 1)-\(selected.lastPosition + 1)"
                let kinds = selected.requirements.map(\.kind.rawValue).filter { $0 != "parameter_bound" && $0 != "entry_state" }
                if !kinds.isEmpty { text += " [\(kinds.joined(separator: ","))]" }
            }
            if !outcome.excluded.isEmpty {
                text += " excluded: " + outcome.excluded.map { "\(name($0.routeID)) \($0.firstPosition + 1)-\($0.lastPosition + 1)" }
                    .joined(separator: " | ")
            }
            if !outcome.alternatives.isEmpty {
                text += " alternatives: " + outcome.alternatives.map { "\(name($0.routeID)) \($0.firstPosition + 1)-\($0.lastPosition + 1)" }
                    .joined(separator: " | ")
            }
            return text
        }.joined(separator: " ; ")
    }
}
