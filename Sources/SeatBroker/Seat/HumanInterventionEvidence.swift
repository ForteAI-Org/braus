//
//  HumanInterventionEvidence.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import Engine
import InteractionListener
import InteractionObservation
import PerceptionCore

/// HumanInterventionEvidence reduces minimized scenes to changed facts and merged, numbered steps.
/// Read effects remain attached to their steps; a covering read is evidence for the whole covered run.
nonisolated struct HumanInterventionEvidence: Sendable {
    struct Effect: Sendable {
        let window: Int
        let title: String
        let identity: String
        let attribute: String
        let label: String
        let text: String
        let atoms: [String]
        var container: String? = nil

        var key: String { "\(window):\(container ?? ""):\(identity):\(attribute)" }
        var embeddingText: String { "\(title) \(label) \(attribute) \(text)" }
    }

    struct Step: Sendable {
        var action: HumanRecordedInteraction.SummaryAction
        var text: String
        var sequences: [UInt64]
        var effects: [Effect]
        var isMenu: Bool
        var atoms: [String]
        /// What the reads covering this step observed changing, intermediate states included.
        var observed: [String] = []

        var embeddingText: String {
            "\(action.role ?? "") \(text) \(action.windowTitle ?? "")"
        }
    }

    var steps: [Step] = []
    var windows: [Int: String] = [:]
    var notice: String?

    var appName = ""
    var documentTitle = ""
    var hasFinalDocumentRead = false
    var threads = HumanInterventionThreads(actions: [], sequences: [], scenes: [:])
    var ledger = HumanInterventionEffects()
    var attribution = HumanInterventionAttribution()
    var failedSurfaces: Set<Int> = []

    /// Every command and every effect is embedded, for attribution only.
    var threadTexts: [String] { attribution.commandTexts }
    var embeddingActions: [String] { attribution.commandTexts }
    var embeddingEffects: [String] { attribution.effectTexts }

    /// Command vectors, then effect vectors, as the digest splits them.
    func threadVectors(_ result: HumanInterventionEmbeddings.Result) -> [[Float]] {
        result.actionVectors + result.effectVectors
    }

    init(_ review: HumanInterventionConsumer.Intervention.Review) {
        self.init(findings: review.findings, finalState: review.finalState)
    }

    init(findings: [HumanSceneFinding], finalState: HumanSceneFinding) {
        do {
            // Rows are named once, as their editable name field says, before any read is compared; the ledger also
            // names a row by its first text in reading order.
            func named(_ scenes: [Int: SceneSnapshot]) -> [Int: SceneSnapshot] {
                scenes.mapValues { HumanInterventionScene.namingRows($0, byFirstText: false) }
            }
            func titled(_ scenes: [Int: SceneSnapshot]) -> [Int: SceneSnapshot] { scenes.mapValues { HumanInterventionScene.namingRows($0) } }
            var final = try finalState.sceneEvidence()
            final.initialScenes = named(final.initialScenes)
            final.scenes = named(final.scenes)
            let decoded = try findings.map { finding in
                var read = try finding.sceneEvidence()
                read.scenes = named(read.scenes)
                return read
            }
            let actions = findings.compactMap(\.recordedAction)
            let sequences = findings.filter { $0.recordedAction != nil }.map(\.sequence)
            let actionIndexes = Dictionary(uniqueKeysWithValues: sequences.enumerated().map { ($0.element, $0.offset) })
            var scenes = final.initialScenes
            let surfaces = HumanInterventionThreads.Surfaces(initial: final.initialScenes, findings: findings,
                decoded: decoded, actions: actions, actionIndexes: actionIndexes)
            for read in decoded { scenes.merge(read.scenes) { _, latest in latest } }
            scenes.merge(final.scenes) { _, latest in latest }
            windows = scenes.mapValues(\.windowTitle)
            for action in actions {
                if let window = action.windowNumber, let title = action.windowTitle, windows[window] == nil {
                    windows[window] = title
                }
            }
            var closedBeforeAction: [Int: Set<Int>] = [:]
            var closed = Set<Int>()
            for (finding, read) in zip(findings, decoded) {
                if let index = actionIndexes[finding.sequence] {
                    closedBeforeAction[index] = closed
                    closed.removeAll()
                }
                closed.formUnion(read.closedWindowNumbers)
            }
            threads = HumanInterventionThreads(actions: actions, sequences: sequences, scenes: scenes,
                                                documentByAction: surfaces.documentByAction, closedBeforeAction: closedBeforeAction,
                                                immediateChoices: surfaces.choices)
            let covering = Dictionary(grouping: findings.filter { $0.recordedAction != nil }) {
                $0.coveredBySequence ?? $0.sequence
            }.mapValues { $0.compactMap { actionIndexes[$0.sequence] } }
            // Structural reads (archive version 3), by read index and window.
            func readWindows(_ structure: InteractionStructuralRead?) -> [Int: InteractionStructuralRead.Window] {
                var read: [Int: InteractionStructuralRead.Window] = [:]
                for window in structure?.windows ?? [] {
                    guard let number = window.number else { continue }
                    // Two accessibility windows can resolve to one window number (an editor and its frame).
                    guard var merged = read[number] else { read[number] = window; continue }
                    merged.collections += window.collections
                    merged.fields += window.fields
                    merged.hosted += window.hosted
                    read[number] = merged
                }
                return read
            }
            func structure(_ finding: HumanSceneFinding) -> [Int: InteractionStructuralRead.Window] {
                var result: [Int: InteractionStructuralRead.Window] = [:]
                for surface in finding.provenance?.surfaces ?? [] { result.merge(readWindows(surface.structure)) { _, latest in latest } }
                return result
            }
            var structures: [Int: [Int: InteractionStructuralRead.Window]] = [:]
            // The read taken when control passed is the "before" of every window it reached (read -1).
            if let initial = finalState.provenance?.initialStructure, !readWindows(initial).isEmpty { structures[-1] = readWindows(initial) }
            let settled = Dictionary((finalState.provenance?.settled ?? []).map { ($0.sequence, $0.structure) },
                                     uniquingKeysWith: { _, latest in latest })
            for (index, finding) in findings.enumerated() {
                var read = structure(finding)
                // A read taken when the person paused after this one shows what its windows drew after it.
                if finding.recordedAction != nil, let later = settled[finding.sequence] {
                    read.merge(readWindows(later)) { _, settled in settled }
                }
                if !read.isEmpty { structures[index] = read }
            }
            if !structure(finalState).isEmpty { structures[findings.count] = structure(finalState) }
            let unread = Set((findings + [finalState]).flatMap { $0.provenance?.surfaces.flatMap { $0.structure?.unread ?? [] } ?? [] })
            // Windows typed into whose last action was not a cancel (Escape, a cancel button).
            var editors = Set<Int>()
            for action in actions {
                guard let window = action.windowNumber else { continue }
                if action.kind == .typing { editors.insert(window) }
                if action.windowButton == .cancel || action.kind == .shortcut && action.commandName == "Escape" { editors.remove(window) }
            }
            ledger = HumanInterventionEffects(structures: structures, unread: unread, editors: editors, actions: actions, reads:
                [(.init(index: -1, sequence: UInt64.max, actions: [], overlapped: false), titled(final.initialScenes))]
                + zip(findings, decoded).enumerated().map { index, pair in
                    (.init(index: index, sequence: pair.0.sequence, actions: covering[pair.0.sequence] ?? [],
                           overlapped: pair.0.inputDuringRead), titled(pair.1.scenes))
                }
                + [(.init(index: findings.count, sequence: 0, actions: [], overlapped: finalState.inputDuringRead), titled(final.scenes))])
            var previous = final.initialScenes
            var stepEffects: [UInt64: [Effect]] = [:]
            var scrolling = Set<Int>()
            var previousAX: [Int: InteractionSemanticSnapshot.Interval] = [:]
            for (finding, read) in zip(findings, decoded) {
                let coveredIndexes = covering[finding.sequence] ?? []
                var indexes = coveredIndexes
                let intervals = finding.provenance.flatMap { $0.version == 1 ? $0.surfaces : nil }?
                    .filter { !$0.failed && $0.accessibility?.isValid == true } ?? []
                if !intervals.isEmpty {
                    indexes = actions.indices.filter { index in
                        guard let provenance = actions[index].provenance, provenance.version == 1,
                              provenance.interval.isValid else {
                            return coveredIndexes.contains(index)
                        }
                        let time = provenance.interval
                        return intervals.contains { surface in
                            guard let ax = surface.accessibility, surface.processID == actions[index].processID else { return false }
                            let start = previousAX[surface.windowNumber]?.start
                                ?? surface.capture?.start ?? ax.start
                            let occurredSinceBaseline = time.end >= start && time.start <= ax.end
                            // A covered action can precede capture, but input wholly after AX cannot contribute.
                            return time.start <= ax.end && (occurredSinceBaseline || coveredIndexes.contains(index))
                        }
                    }
                    for surface in intervals { previousAX[surface.windowNumber] = surface.accessibility }
                }
                for (window, scene) in read.scenes {
                    if let baseline = previous[window] {
                        let coveredActions = indexes.map { actions[$0] }
                        let passive = !coveredActions.isEmpty && coveredActions.allSatisfy {
                            $0.windowNumber == window && ($0.kind == .scroll
                                || ($0.kind == .click && ($0.role == nil || $0.role == "AXWindow")))
                        }
                        if !passive { scrolling.remove(window) }
                        if passive && coveredActions.contains(where: { $0.kind == .scroll }) { scrolling.insert(window) }
                        let changes = Self.difference(baseline, scene, window: window)
                        // Preserve the existing lazy-step numbering without treating visibility as a domain effect.
                        stepEffects[finding.sequence, default: []] += scrolling.contains(window)
                            ? changes.filter { !["added", "removed"].contains($0.attribute) } : changes
                    }
                    previous[window] = scene
                }
            }
            ledger.resolve(dialogs: Set(actions.filter { $0.windowButton != nil }.compactMap(\.windowNumber)))
            attribution = HumanInterventionAttribution(threads: threads, effects: ledger.effects + ledger.intermediate,
                                                       windows: windows)
            ledger.attribute(attribution.links.map { Set($0.preferred) })
            // The document is where the commands that caused effects worked, or committed what no read shows; else
            // where the first command did.
            let causes = attribution.deterministicCauses
            let document = threads.roots.filter { causes.contains($0.id) || $0.isOpaqueCommit }.compactMap(\.document).first
                ?? threads.roots.compactMap(\.document).first
                ?? scenes.keys.sorted().first { scenes[$0].map { !HumanInterventionScene.isTransient($0) } == true }
            if let document, let scene = scenes[document] {
                appName = scene.appName
                documentTitle = scene.windowTitle
                hasFinalDocumentRead = final.scenes[document] != nil
            }
            for finding in findings {
                guard let action = finding.recordedAction else { continue }
                append(action, sequence: finding.sequence,
                       effects: stepEffects[finding.coveredBySequence ?? finding.sequence] ?? [])
            }
            // Keep suppressed actions reachable without renumbering existing detail steps.
            var stepBySequence: [UInt64: Int] = [:]
            for (index, step) in steps.enumerated() {
                for sequence in step.sequences { stepBySequence[sequence] = index }
            }
            for root in threads.roots {
                let owned = root.actions.map { sequences[$0] }
                let first = owned.compactMap { stepBySequence[$0] }.min()
                let missing = owned.filter { stepBySequence[$0] == nil }
                if let first {
                    steps[first].sequences = Array(Set(steps[first].sequences).union(missing)).sorted()
                    for sequence in missing { stepBySequence[sequence] = first }
                } else if let index = root.actions.first {
                    let action = actions[index]
                    for sequence in owned { stepBySequence[sequence] = steps.count }
                    steps.append(Step(action: action, text: Self.action(action), sequences: owned.sorted(),
                                      effects: [], isMenu: false, atoms: []))
                }
            }
            // A step lists what the reads covering its actions observed, once per read.
            let readOf = Dictionary(uniqueKeysWithValues: findings.map { ($0.sequence, $0.coveredBySequence ?? $0.sequence) })
            for index in steps.indices {
                var seen = Set<UInt64>()
                for sequence in steps[index].sequences {
                    guard let read = readOf[sequence], seen.insert(read).inserted else { continue }
                    steps[index].observed += ledger.observed[read] ?? []
                }
            }
            if final.scenes.isEmpty, let reason = finalState.reason { notice = reason.rawValue + "." }
            failedSurfaces.formUnion(finalState.provenance?.surfaces.filter(\.failed).map(\.windowNumber) ?? [])
            // Version 1 retains the per-surface failure inventory only in diagnostic text.
            let finalText = try finalState.text()
            for line in finalText.components(separatedBy: .newlines) where line.hasPrefix("window #") && line.contains(": read failed:") {
                if let number = Int(line.dropFirst(8).prefix(while: \.isNumber)) { failedSurfaces.insert(number) }
            }
            for index in threads.roots.indices {
                threads.roots[index].unreadableSurfaces = threads.roots[index].surfaces.intersection(failedSurfaces)
            }
        } catch {
            notice = "Scene evidence unavailable."
        }
    }

    /// Applies the UI owner's withholding policy before values cross back to concurrent rendering.
    /// The callback may be actor-bound; no callback or owner is retained by the returned snapshot.
    func withholding(_ transform: (String) -> String) -> Self {
        var cache: [String: String] = [:]
        func safe(_ text: String) -> String {
            if let value = cache[text] { return value }
            let value = transform(text)
            cache[text] = value
            return value
        }
        func effect(_ value: Effect) -> Effect {
            Effect(window: value.window, title: safe(value.title), identity: value.identity,
                   attribute: value.attribute, label: safe(value.label), text: safe(value.text),
                   atoms: value.atoms.map(safe), container: value.container.map(safe))
        }
        func action(_ value: HumanRecordedInteraction.SummaryAction) -> HumanRecordedInteraction.SummaryAction {
            .init(kind: value.kind, processID: value.processID, windowNumber: value.windowNumber,
                  windowTitle: value.windowTitle.map(safe), role: value.role, label: value.label.map(safe),
                  isProtected: value.isProtected, destination: value.destination.map(safe),
                  commandName: value.commandName.map(safe), lostCritical: value.lostCritical,
                  provenance: value.provenance.map {
                      var provenance = $0
                      provenance.semantics = provenance.semantics?.withholding(safe)
                      provenance.beforeSemantics = provenance.beforeSemantics?.withholding(safe)
                      return provenance
                  })
        }
        var result = self
        result.threads.actions = threads.actions.map(action)
        result.steps = steps.map { step in
            var step = step
            step.text = safe(step.text)
            step.atoms = step.atoms.map(safe)
            step.observed = step.observed.map(safe)
            step.effects = step.effects.map(effect)
            step.action = action(step.action)
            return step
        }
        result.windows = windows.mapValues(safe)
        result.notice = notice.map(safe)
        result.appName = safe(appName)
        result.documentTitle = safe(documentTitle)
        for index in result.threads.roots.indices {
            result.threads.roots[index].affected = result.threads.roots[index].affected.map(safe)
            result.threads.roots[index].selectedIn = result.threads.roots[index].selectedIn.map(safe)
            result.threads.roots[index].selectedObjects = result.threads.roots[index].selectedObjects.map(safe)
            result.threads.roots[index].focusedRow = result.threads.roots[index].focusedRow.map(safe)
            result.threads.roots[index].actionContexts = result.threads.roots[index].actionContexts.map(safe)
            result.threads.roots[index].conclusions = result.threads.roots[index].conclusions.map {
                .init(action: $0.action, kind: $0.kind, label: safe($0.label), commitLike: $0.commitLike,
                      observability: $0.observability,
                      evidence: safe($0.evidence))
            }
            result.threads.roots[index].path = result.threads.roots[index].path.map(safe)
            result.threads.roots[index].dialogTitle = result.threads.roots[index].dialogTitle.map(safe)
            result.threads.roots[index].selection = result.threads.roots[index].selection.map(safe)
            result.threads.roots[index].parameterRoles = Dictionary(result.threads.roots[index].parameterRoles.map {
                (safe($0.key), $0.value)
            }, uniquingKeysWith: { first, _ in first })
            result.threads.roots[index].parameters = Dictionary(result.threads.roots[index].parameters.map {
                (safe($0.key), safe($0.value))
            }, uniquingKeysWith: { first, _ in first })
        }
        result.ledger = ledger.withholding(safe)
        result.attribution = attribution.withholding(safe)
        return result
    }

    private mutating func append(
        _ action: HumanRecordedInteraction.SummaryAction,
        sequence: UInt64,
        effects: [Effect]
    ) {
        if [.scroll, .hover, .focus].contains(action.kind), effects.isEmpty { return }
        if action.kind == .click, action.isUnknown, effects.isEmpty { return }
        if let last = steps.last {
            let same = last.action.sameTarget(as: action)
            let typing = same && action.kind == .typing
                && (last.action.kind == .typing || (last.action.kind == .click && action.isField))
            let enter = same && action.kind == .shortcut && last.action.kind == .typing
                && ["Return", "Enter"].contains(action.commandName ?? "")
            let repeatClick = same && action.kind == .click && last.action.kind == .click
            let menu = last.isMenu && action.kind == .click && !action.isUnknown && !action.isProtected
                && last.action.processID == action.processID && (action.isMenu || action.role == "AXButton")
            if typing || enter || repeatClick || menu {
                let index = steps.count - 1
                steps[index].sequences.append(sequence)
                steps[index].effects = Self.merging(last.effects, with: effects)
                if typing {
                    var typing = action
                    typing.windowTitle = typing.windowTitle ?? last.action.windowTitle
                    steps[index].text = Self.action(typing)
                    steps[index].action = typing
                } else if menu {
                    steps[index].text += " ▸ " + action.target
                    steps[index].action = action
                    steps[index].isMenu = action.isMenu
                } else if enter { steps[index].action = action }
                steps[index].atoms = Array(Set(last.atoms + [action.target, action.windowTitle].compactMap { $0 }))
                return
            }
        }
        steps.append(Step(action: action, text: action.isMenu ? action.target : Self.action(action),
            sequences: [sequence], effects: effects, isMenu: action.isMenu,
            atoms: [action.target, action.windowTitle].compactMap { $0 }))
    }

    private static func merging(
        _ earlier: [Effect],
        with later: [Effect]
    ) -> [Effect] {
        var result = earlier
        var indexes: [String: Int] = [:]
        for (index, effect) in result.enumerated() { indexes[effect.key] = index }
        for effect in later {
            if let index = indexes[effect.key] { result[index] = effect }
            else {
                indexes[effect.key] = result.count
                result.append(effect)
            }
        }
        return result
    }

    static func action(_ action: HumanRecordedInteraction.SummaryAction) -> String {
        switch action.kind {
        case .typing:
            let target = action.isUnknown && action.isField
                ? (action.role == "AXTextArea" ? "text area" : "text field") : action.target
            return "typed in \(target)" + (action.windowTitle.map { " (\($0))" } ?? "")
        case .shortcut:
            let command = action.commandName ?? "unknown shortcut"
            guard let state = action.provenance?.attestedState, state.processID == action.processID,
                  action.windowNumber == nil || state.focusedElement?.window == action.windowNumber else { return command }
            if action.isProtected { return command + " in protected field" }
            let role = action.role == "AXTextField" ? "text field"
                : action.role == "AXTextArea" ? "text area" : action.role ?? "unknown focus"
            return command + " in " + role + (action.label.map { " '\($0)'" } ?? "")
                + (action.windowTitle.map { " (\($0))" } ?? "")
        case .click: return "click \(action.target)"
        case .rightClick: return "right-click \(action.target)"
        case .drag: return "drag \(action.target) → \(action.destination ?? "unknown target")"
        case .gap: return "input gap: \(action.lostCritical) events missing"
        default: return "\(action.kind.rawValue) \(action.target)"
        }
    }

    static func difference(
        _ before: SceneSnapshot,
        _ after: SceneSnapshot,
        window: Int,
        allowsLocationMatching: Bool = true
    ) -> [Effect] {
        var result: [Effect] = []
        func add(_ id: String, _ attribute: String, _ label: String, _ text: String, _ atoms: [String],
                 container: String? = nil) {
            result.append(Effect(window: window, title: after.windowTitle, identity: id,
                attribute: attribute, label: label, text: text, atoms: atoms + [after.windowTitle], container: container))
        }
        for change in HumanInterventionChanges.pairs(before, after, allowsLocationMatching: allowsLocationMatching) {
            guard let element = change.after ?? change.before else { continue }
            let label = element.label
            switch (change.before, change.after) {
            case (nil, let new?):
                add(new.id, "added", label, "+ \(label)", [label], container: new.container)
            case (let old?, nil): add(old.id, "removed", label, "− \(label)", [label], container: old.container)
            case (let old?, let new?):
                // Repeated controls in different virtual rows do not attest a value change.
                if !allowsLocationMatching, old.container != new.container { continue }
                let namedValue = old.label != new.label && old.value?.isEmpty == false && new.value?.isEmpty == false
                    && old.label.contains(old.value ?? "") && new.label.contains(new.value ?? "")
                if old.label != new.label {
                    let previous = namedValue ? (old.value ?? old.label) : old.label
                    let current = namedValue ? (new.value ?? label) : label
                    add(new.id, "name", label, "\(previous) → \(current)", [previous, current], container: new.container)
                }
                if !namedValue, old.value != new.value, HumanInterventionChanges.hasRelevantValue(new) {
                    let oldParts = Set((old.value ?? "").components(separatedBy: ";").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    })
                    let parts = (new.value ?? "").components(separatedBy: ";").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty && !oldParts.contains($0) }
                    let value = parts.isEmpty ? (new.value ?? "empty") : parts.joined(separator: "; ")
                    add(new.id, "value", label, "\(value) on \(label)", [value, label], container: new.container)
                }
                if old.state != new.state {
                    add(new.id, "state", label, "\(label): \(new.state?.rawValue ?? "no state")", [label], container: new.container)
                }
                if old.isEnabled != new.isEnabled {
                    add(new.id, "enabled", label, "\(label): \(new.isEnabled == false ? "disabled" : "enabled")", [label], container: new.container)
                }
            default: break
            }
        }
        if before.windowTitle != after.windowTitle {
            add("window", "title", after.windowTitle, "Window: \(before.windowTitle) → \(after.windowTitle)",
                [before.windowTitle, after.windowTitle])
        }
        let oldFields = Dictionary(
            grouping: before.outOfViewFields,
            by: { "\($0.role):\($0.container ?? ""):\($0.label)" }
        )
        for field in after.outOfViewFields {
            let key = "\(field.role):\(field.container ?? ""):\(field.label)"
            let element = PerceptionCore.SceneElement(id: key, kind: .text, label: field.label,
                bounds: .init(x: 0, y: 0, width: 0, height: 0), role: field.role, value: field.value)
            if HumanInterventionChanges.isRelevant(element), HumanInterventionChanges.hasRelevantValue(element),
               oldFields[key]?.first?.value != field.value {
                add(key, "field", field.label, "\(field.value) on \(field.label)", [field.label, field.value], container: field.container)
            }
        }
        return result
    }
}
