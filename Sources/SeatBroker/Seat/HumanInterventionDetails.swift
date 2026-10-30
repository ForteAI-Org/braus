//
//  HumanInterventionDetails.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import Foundation
import Engine
import InteractionObservation
import InteractionListener
import Memory

/// HumanInterventionDetails owns one bounded review during the resumed turn only.
/// Invalidating it drops all payloads and pictures before releasing the intervention's own history.
@MainActor
final class HumanInterventionDetails {
    private var review: HumanInterventionConsumer.Intervention.Review?
    private var digest: HumanInterventionSummary.Digest?
    private let intervention: HumanInterventionConsumer.Intervention
    private let withholding: (String) -> String

    init(
        review: HumanInterventionConsumer.Intervention.Review,
        digest: HumanInterventionSummary.Digest,
        intervention: HumanInterventionConsumer.Intervention,
        withholding: @escaping (String) -> String
    ) {
        self.review = review
        self.digest = digest
        self.intervention = intervention
        self.withholding = withholding
    }

    func finish() async {
        review = nil
        digest = nil
        await intervention.finishResumedTurn()
    }

    func result(_ request: HumanStepRequest) -> HumanStepResult {
        guard let review, let digest else { return .unavailable }
        let evidence = digest.evidence
        var lines: [String] = []
        switch request {
        case .steps(let range):
            guard range.lowerBound > 0, range.upperBound <= evidence.steps.count,
                  range.upperBound - range.lowerBound < 20 else {
                return HumanStepResult(text: "Step range unavailable.", isError: true)
            }
            var describedThreads = Set<Int>()
            // The model that ranked causes, or why none did, so a reader can check the floor's calibration.
            if let model = digest.attribution.model { lines.append("Causes ranked with \(model).") }
            if let skipped = digest.attribution.skipped { lines.append("Causes unranked: \(skipped).") }
            for index in range {
                let step = evidence.steps[index - 1]
                lines.append("\(index): \(step.text)")
                for observed in step.observed { lines.append("  Observed: " + observed) }
                let actions = evidence.threads.sequences.indices.filter { step.sequences.contains(evidence.threads.sequences[$0]) }
                for actionIndex in actions {
                    let action = evidence.threads.actions[actionIndex]
                    if let provenance = action.provenance {
                        lines.append("  Action \(actionIndex + 1) monotonic: " + interval(provenance.interval)
                            + (provenance.targetInferred ? "; target inferred from click." : "."))
                        if let state = provenance.semantics {
                            lines.append("  AX after delivery " + interval(state.interval) + ": focus "
                                + answer(state.focused) { _ in state.focusedElement?.label ?? "unlabelled" }
                                + (provenance.attestedState == nil ? "; recipient unattested." : "; focus continuous across action."))
                            for element in state.elements where element.isProtected || element.selected != .unsupported
                                || element.selectedRows != .unsupported || element.selectedChildren != .unsupported {
                                if element.isProtected {
                                    lines.append("    Selection: protected.")
                                } else {
                                    lines.append("    \(element.label ?? element.role ?? "Element"): selected "
                                        + answer(element.selected) { $0 ? "true" : "false" }
                                        + "; rows " + selection(element.selectedRows, in: state)
                                        + "; children " + selection(element.selectedChildren, in: state) + ".")
                                }
                            }
                        }
                    }
                }
                for finding in review.findings where step.sequences.contains(finding.sequence)
                    || step.sequences.contains(where: { sequence in
                        review.findings.first { $0.sequence == sequence }?.coveredBySequence == finding.sequence
                    }) {
                    for surface in finding.provenance?.surfaces ?? [] {
                        lines.append("  Read \(finding.sequence) window #\(surface.windowNumber): capture "
                            + interval(surface.capture) + "; AX " + interval(surface.accessibility)
                            + (surface.failed ? "; failed." : "."))
                    }
                }
                let roots = Set(actions.map { evidence.threads.owners[$0] }).sorted()
                for rootID in roots where describedThreads.insert(rootID).inserted {
                    let root = evidence.threads.roots[rootID]
                    let causes = digest.attribution.deterministicCauses
                    let status = causes.contains(rootID) ? "caused observed effects"
                        : root.isOpaqueCommit ? "committed, effect unobserved" : "no observed effect"
                    lines.append("  Thread T\(rootID + 1): \(status).")
                    lines.append("  Actions: " + root.actions.map { String($0 + 1) }.joined(separator: ", "))
                    for conclusion in root.conclusions {
                        lines.append("  \(conclusion.kind.rawValue): \(conclusion.label); \(conclusion.evidence).")
                    }
                    // Each effect this command may have caused, with the cause attribution chose and how sure it is.
                    let effects = evidence.ledger.effects + evidence.ledger.intermediate
                    for (index, link) in digest.attribution.links.enumerated()
                        where link.candidates.contains(rootID) && effects.indices.contains(index) {
                        let effect = HumanInterventionEffects.describe(effects[index])
                            + (index >= evidence.ledger.effects.count ? " (not in the final state)" : "")
                        let similarity = link.similarity.map { String(format: " %.2f", $0) } ?? ""
                        let status = link.cause == rootID
                            ? "cause, \(link.confidence.rawValue)\(similarity)" + (link.alternative.map { "; closer: T\($0 + 1)" } ?? "")
                            : link.cause.map { "candidate; cause T\($0 + 1)" } ?? "candidate; \(link.reason)"
                        lines.append("  Effect \(effect): \(status).")
                    }
                    for task in digest.attribution.tasks where task.contains(where: { digest.attribution.links[$0].cause == rootID }) {
                        let kinds = Dictionary(grouping: task.compactMap { effects.indices.contains($0) ? effects[$0].kind.rawValue : nil }) { $0 }
                        lines.append("  Task: " + kinds.keys.sorted().map { "\(kinds[$0]?.count ?? 0) \($0)" }.joined(separator: ", ")
                            + " (" + task.compactMap { effects.indices.contains($0) ? effects[$0].label : nil }.joined(separator: ", ") + ").")
                    }
                }
            }
        case .diff(let window):
            let number = Int(window)
                ?? Optional(digest.strings.value(window) ?? window).flatMap { title in
                    let matches = evidence.windows.filter { $0.value == title }
                    return matches.count == 1 ? matches.first?.key : nil
                }
            guard let number, evidence.windows[number] != nil else {
                return HumanStepResult(text: "Window unavailable; use its number.", isError: true)
            }
            lines = evidence.ledger.effects.filter { $0.window == number }.map(HumanInterventionEffects.describe)
                + evidence.ledger.intermediate.filter { $0.window == number }
                    .map { HumanInterventionEffects.describe($0) + " (not in the final state)" }
            if lines.isEmpty { lines = ["No changes."] }
            let causes = digest.attribution.deterministicCauses
            for root in evidence.threads.roots where root.surfaces.contains(number) && !causes.contains(root.id) {
                lines.append("Thread T\(root.id + 1): no observed effect.")
                for index in root.actions {
                    lines.append("  Action \(index + 1): " + HumanInterventionEvidence.action(evidence.threads.actions[index]))
                }
            }
        case .picture(let number):
            guard number > 0, evidence.steps.indices.contains(number - 1) else {
                return HumanStepResult(text: "Step unavailable.", isError: true)
            }
            let step = evidence.steps[number - 1]
            let indexes = review.findings.indices.filter { step.sequences.contains(review.findings[$0].sequence) }
            for index in indexes.reversed() where review.payloads.indices.contains(index) {
                let payload = review.payloads[index]
                guard let picture = payload.picture else { continue }
                // Reconstruction happens after pixel capture, so its redactions cannot attest these pixels.
                let description = compact([
                    "\(number): \(step.text)",
                    "Retained picture: \(Int(picture.encodedSize.width))×\(Int(picture.encodedSize.height)) HEIC; pixels withheld (privacy unverified)."
                ], strings: digest.strings)
                return HumanStepResult(text: description)
            }
            lines = ["\(number): \(step.text)", "No retained picture."]
        }
        return HumanStepResult(text: compact(lines, strings: digest.strings))
    }

    private func interval(_ value: InteractionSemanticSnapshot.Interval?) -> String {
        guard let value, value.isValid else { return "unknown" }
        return String(format: "%.6f…%.6f s", value.start, value.end)
    }

    private func answer<Value>(_ value: InteractionSemanticSnapshot.Answer<Value>,
                               render: (Value) -> String) -> String {
        switch value {
        case .value(let value): render(value)
        case .unsupported: "unsupported"
        case .unread: "unread"
        case .protected: "protected"
        }
    }

    private func selection(_ value: InteractionSemanticSnapshot.Answer<[Int]>,
                           in state: InteractionSemanticSnapshot) -> String {
        answer(value) { ids in
            if ids.isEmpty { return "none" }
            return ids.map { id in
                guard let element = state.elements.first(where: { $0.id == id }) else { return "unread" }
                return element.isProtected ? "protected" : element.label ?? "unlabelled"
            }.joined(separator: ", ")
        }
    }

    private func compact(_ lines: [String], strings: HumanInterventionStrings) -> String {
        // Reserve the complete table once; the renderer emits only definitions used by accepted lines.
        let definitions = strings.entries.enumerated().reduce(0) {
            $0 + "§\($1.offset + 1)=\(String(reflecting: $1.element))\n".utf8.count
        }
        var bytes = definitions + 40
        var accepted: [String] = []
        var omitted = 0
        for line in lines {
            let safe = withholding(ValueMinimization().minimize(text: line).0)
                .components(separatedBy: .newlines).joined(separator: " ")
            let size = safe.utf8.count + 1
            if bytes + size <= 2048 {
                accepted.append(safe)
                bytes += size
            } else { omitted += 1 }
        }
        if omitted > 0 { accepted.append("\(omitted) lines omitted") }
        return withholding(ValueMinimization().minimize(text: strings.render(accepted)).0)
    }
}
