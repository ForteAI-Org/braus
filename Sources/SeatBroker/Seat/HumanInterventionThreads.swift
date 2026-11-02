import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore

/// HumanInterventionThreads partitions all recorded actions into commands: a menu path, a dialog and its controls, a
/// choice, typing in one field, a shortcut. Conclusions describe how a command ended, never whether it succeeded.
nonisolated struct HumanInterventionThreads: Sendable {
    enum Operation: String, Sendable {
        case context, menu, create, edit, save, choice, other
    }

    enum Resolution: String, Sendable {
        case commit, apply, cancel, failure, close, implicit, unknown
    }

    enum Observability: String, Sendable {
        case represented, unrepresented, unknown
    }

    struct Conclusion: Sendable {
        let action: Int
        let kind: Resolution
        let label: String
        let commitLike: Bool
        var observability: Observability = .unknown
        var evidence: String = "recorded target and operation context"
    }

    struct Root: Sendable {
        let id: Int
        let processID: Int32
        var document: Int?
        var surface: Int?
        var actions: [Int] = []
        var surfaces: Set<Int> = []
        var childSurfaces: Set<Int> = []
        var operation: Operation
        var path: [String] = []
        var conclusions: [Conclusion] = []
        var parameters: [String: String] = [:]
        var parameterRoles: [String: String] = [:]
        var dialogTitle: String?
        var selection: String?
        var affected: [String] = []
        /// A selection read around a choice by probes that could not certify every collection of the window.
        var selectedIn: String?
        var selectedObjects: [String] = []
        var focusedRow: String?
        var actionContexts: [String] = []
        /// A secondary-click menu awaiting its command; it concludes at that command.
        var contextMenu = false

        var unreadableSurfaces: Set<Int> = []

        var requestedCount: Int? {
            let counts = parameters.compactMap { key, value -> Int? in
                guard ["AXTextField", "AXTextArea", "AXStepper"].contains(parameterRoles[key] ?? ""),
                      let count = Int(value), count > 0 else { return nil }
                return count
            }
            return counts.count == 1 ? counts.first : nil
        }

        var requestedNames: [String] {
            parameters.compactMap { key, value in
                guard ["AXTextField", "AXTextArea"].contains(parameterRoles[key] ?? ""),
                      Int(value) == nil else { return nil }
                return value
            }
        }
        var endAction: Int { actions.last ?? -1 }
        var terminal: Conclusion? { conclusions.last }
        /// A command that committed a choice or command whose result no reading represents (a palette colour, ⌘S):
        /// unobserved unless an effect is attributed to it.
        var isOpaqueCommit: Bool {
            terminal.map { [.commit, .apply].contains($0.kind) && $0.commitLike && $0.observability == .unrepresented } ?? false
        }
        var isPending: Bool {
            operation != .context && (terminal == nil || terminal?.kind == .apply)
        }
        /// Grouping and ranking text only: operation, surface, focus, selection and parameter context.
        var embeddingText: String {
            ([operation.rawValue] + path + [terminal?.label ?? "", dialogTitle ?? "", selection ?? "",
                focusedRow ?? "", affected.joined(separator: ", ")]
                + actionContexts + parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" })
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    var roots: [Root] = []
    var owners: [Int] = []

    /// Whether command `id` means `meaning` (create, delete): a creation operation, the Delete key, or a menu path
    /// whose leading word means it. The vocabulary refines a fact's type or ranks a cause, never decides a fact.
    func means(_ id: Int, _ meaning: HumanInterventionVocabulary.Meaning) -> Bool {
        guard roots.indices.contains(id) else { return false }
        let root = roots[id]
        if meaning == .create, root.operation == .create { return true }
        if meaning == .delete, root.actions.contains(where: {
            ["Delete", "ForwardDelete"].contains(actions[$0].commandName.map { String($0.drop { "⌃⌥⇧⌘".contains($0) }) } ?? "")
        }) { return true }
        return root.path.contains { HumanInterventionVocabulary.meaning(of: $0, leadingWord: true) == meaning }
    }
    var actions: [HumanRecordedInteraction.SummaryAction]
    let sequences: [UInt64]

    init(actions: [HumanRecordedInteraction.SummaryAction], sequences: [UInt64],
         scenes: [Int: SceneSnapshot], documentByAction: [Int: Int] = [:],
         closedBeforeAction: [Int: Set<Int>] = [:], immediateChoices: [Int: String] = [:],
         rowAliases: [Int: [String: String]] = [:]) {
        self.actions = actions
        self.sequences = sequences
        var document: Int?
        var active: Int?
        var pendingRoots: [Int] = []
        var popUpValue: [Int: (action: Int, label: String)] = [:]
        for index in actions.indices {
            let closed = closedBeforeAction[index] ?? []
            for root in pendingRoots {
                roots[root].childSurfaces.subtract(closed)
                if let surface = roots[root].surface, closed.contains(surface) {
                    // A dialog closed right after a click on a button of its own that no evidence names as cancel or
                    // close committed implicitly; only a compatible observed outcome confirms it.
                    let last = roots[root].actions.last.map { actions[$0] }
                    let implicit = last.map { $0.kind == .click && $0.role == "AXButton" && $0.windowNumber == surface
                        && $0.windowButton != .cancel && ![.cancel, .close].contains(HumanInterventionVocabulary.meaning(of: $0.label)) } == true
                    roots[root].conclusions.append(implicit
                        ? Conclusion(action: max(0, index - 1), kind: .implicit, label: last?.label ?? "", commitLike: false,
                                     observability: .represented, evidence: "dialog closed by one of its buttons; requires compatible observed outcome")
                        : Conclusion(action: max(0, index - 1), kind: .close,
                                     label: "Closed", commitLike: false, evidence: "observed surface closure"))
                    if active == root { active = nil }
                }
            }
            pendingRoots.removeAll { !roots[$0].isPending }
            let action = actions[index]
            if index > 0, actions[index - 1].provenance?.version == 1, action.provenance?.version == 1,
               let before = actions[index - 1].provenance?.interval,
               let after = action.provenance?.interval, before.isValid, after.isValid,
               after.start - before.end >= 15 {
                active = nil
                pendingRoots.removeAll()
            }
            let state = action.provenance?.attestedState.flatMap { $0.processID == action.processID ? $0 : nil }
            let focus = state?.focusedElement.flatMap {
                action.windowNumber == nil || $0.window == action.windowNumber ? $0 : nil
            }
            let focusedRow = focus.flatMap { state?.row(containing: $0) }
            let window = action.windowNumber
            let title = action.windowTitle ?? window.flatMap { scenes[$0]?.windowTitle } ?? ""
            if let observed = documentByAction[index] { document = observed }
            // A secondary-click menu dismissed without a command does not absorb later input. Pointer
            // motion and scrolling cannot dismiss an open menu, so they leave it waiting for its command.
            if let current = active, roots[current].contextMenu, roots[current].path.isEmpty, !action.isMenu,
               ![.scroll, .hover, .focus].contains(action.kind) {
                roots[current].conclusions.append(Conclusion(action: max(0, index - 1), kind: .close,
                    label: "Dismissed", commitLike: false, evidence: "secondary-click menu left without a command"))
                active = nil
            }
            let menuStart = action.isMenu && action.role == "AXMenuBarItem"
            let contextStart = action.kind == .rightClick
            let save = action.kind == .shortcut && action.commandName == "⌘S"
            // A choice on a surface owned by a pending operation is a parameter of that operation,
            // which still awaits its commit or cancel control; it is not the operation's conclusion.
            let hosted = window.map { surface in
                pendingRoots.contains { candidate in
                    let root = roots[candidate]
                    return root.isPending && root.processID == action.processID && root.operation != .context
                        && (root.surface == surface || root.childSurfaces.contains(surface))
                }
            } ?? false
            // A secondary-click menu awaiting its command takes the next menu item, even when its menu window was read.
            let awaitedCommand = action.isMenu && active.map {
                roots[$0].contextMenu && roots[$0].path.isEmpty && roots[$0].processID == action.processID
            } == true
            // A menu item no pending operation owns, such as a pop-up menu's, is a choice made at once.
            let looseMenuItem = action.kind == .click && action.role == "AXMenuItem"
                && !pendingRoots.contains { roots[$0].isPending && roots[$0].processID == action.processID }
            let choice = (immediateChoices[index] != nil || looseMenuItem) && !hosted && !awaitedCommand
            let editing = action.kind == .typing || (action.isField && action.kind == .click) || (action.isField && action.kind == .shortcut
                && !["⌘S", "Escape", "Esc"].contains(action.commandName ?? ""))
            // What a clicked button does: its dialog's default or cancel button by its window, else what its caption hints.
            let caption = action.kind == .click && action.role == "AXButton" ? HumanInterventionVocabulary.meaning(of: action.label) : nil
            let button: HumanInterventionVocabulary.Meaning? = action.kind == .click && action.role == "AXButton"
                ? action.windowButton.map { $0 == .cancel ? .cancel : .commit } ?? caption : nil
            let explicitCreate = caption == .create
            if !menuStart && !save && !choice,
               let resumed = pendingRoots.last(where: {
                   roots[$0].isPending && roots[$0].processID == action.processID && roots[$0].surface == window
               }) { active = resumed }
            let sameProcess = active.map { roots[$0].processID == action.processID } == true
            let pending = active.map { roots[$0].isPending } == true && sameProcess
            let sameScope = active.map { roots[$0].surface == window || window == nil } == true && sameProcess
            var chosen = active
            if save || choice || menuStart || contextStart {
                chosen = nil
            } else if pending {
                let root = roots[active ?? 0]
                let childMenu = action.isMenu
                let dialog = root.operation == .menu || root.operation == .create || root.operation == .other
                let awaitingDialog = dialog && root.dialogTitle == nil
                    && root.actions.contains { actions[$0].role == "AXMenuBarItem" }
                let sameDialog = sameScope || window.map(root.childSurfaces.contains) == true
                    || childMenu || awaitingDialog
                if !sameDialog { chosen = nil }
            } else if !sameScope || active.map({ roots[$0].operation != .context }) == true || explicitCreate {
                chosen = nil
            }
            // A choice in a menu the click just before opened continues that click's operation: a menu or pop-up
            // button names the menu, and an item whose submenu this is names one more level of it.
            var openedBy: [String] = []
            if choice, index > 0, owners.count == index, case let previous = actions[index - 1], previous.kind == .click,
               previous.processID == action.processID, previous.windowNumber != action.windowNumber,
               let label = previous.label, !label.isEmpty {
                let opener = owners[index - 1]
                if ["AXMenuButton", "AXPopUpButton"].contains(previous.role ?? "") {
                    openedBy = [label]
                    // A click that only opened the menu belongs to its choice.
                    if roots[opener].actions == [index - 1] {
                        chosen = opener
                        roots[opener].operation = .choice
                    }
                } else if previous.role == "AXMenuItem", roots[opener].operation == .choice {
                    openedBy = roots[opener].path + [label]
                    chosen = opener
                }
            }
            if editing, let focusedRow, let current = chosen, roots[current].operation == .create,
               let document = roots[current].document, focusedRow.window == document {
                chosen = nil
            }
            if chosen == nil {
                let operation: Operation = save ? .save : choice ? .choice : menuStart || contextStart ? .menu
                    : explicitCreate ? .create : editing ? .edit : .context
                var root = Root(id: roots.count, processID: action.processID, document: document,
                                surface: window, operation: operation)
                root.contextMenu = contextStart
                roots.append(root)
                chosen = roots.count - 1
            }
            guard let rootIndex = chosen else { continue }
            if editing && roots[rootIndex].operation == .context {
                roots[rootIndex].operation = .edit
            }
            // Focus, field and window context for grouping text only; typing never carries characters.
            if action.provenance != nil && (action.kind == .shortcut || action.kind == .typing),
               !roots[rootIndex].actionContexts.contains(HumanInterventionEvidence.action(action)) {
                roots[rootIndex].actionContexts.append(HumanInterventionEvidence.action(action))
            }
            if let focusedRow, editing {
                roots[rootIndex].focusedRow = focusedRow.label
            }
            if choice, let document = roots[rootIndex].document {
                roots[rootIndex].affected = action.provenance?.affectedObjects(in: document, processID: action.processID, actionWindow: action.windowNumber) ?? []
                if roots[rootIndex].affected.isEmpty,
                   let observed = Self.selection(around: index, in: document, actions: actions, scenes: scenes,
                                                 aliases: rowAliases[document] ?? [:]) {
                    roots[rootIndex].selectedIn = observed.collection
                    roots[rootIndex].selectedObjects = observed.names
                }
            }
            roots[rootIndex].actions.append(index)
            if let window { roots[rootIndex].surfaces.insert(window) }
            owners.append(rootIndex)
            if action.isMenu {
                let label = action.label ?? ""
                if roots[rootIndex].operation == .menu {
                    roots[rootIndex].path.append(label)
                    if HumanInterventionVocabulary.meaning(of: label, leadingWord: true) == .create { roots[rootIndex].operation = .create }
                    else if action.role == "AXMenuItem" { roots[rootIndex].operation = .other }
                    // A secondary-click command without an ellipsis acts at once; one with an ellipsis
                    // opens a surface that carries the operation to its own commit or cancel.
                    if roots[rootIndex].contextMenu, action.role == "AXMenuItem",
                       !label.hasSuffix("..."), !label.hasSuffix("…") {
                        roots[rootIndex].conclusions.append(Conclusion(action: index, kind: .commit, label: label,
                            commitLike: false, observability: .represented, evidence: "secondary-click menu command"))
                    }
                } else if action.role == "AXMenuItem", !choice {
                    if let window, window != roots[rootIndex].surface { roots[rootIndex].childSurfaces.insert(window) }
                    // Every distinct choice made inside the operation is one of its parameters. An item on the
                    // operation's own surface that opens a menu at once was its pop-up's current value, not a choice.
                    var chosen = (roots[rootIndex].selection?.components(separatedBy: ", ") ?? [])
                    if let opener = popUpValue[rootIndex], opener.action == index - 1,
                       window != nil, window != roots[rootIndex].surface {
                        chosen.removeAll { $0 == opener.label }
                    }
                    popUpValue[rootIndex] = nil
                    if !chosen.contains(label) {
                        chosen.append(label)
                        if window != nil, window == roots[rootIndex].surface { popUpValue[rootIndex] = (index, label) }
                    }
                    roots[rootIndex].selection = chosen.isEmpty ? nil : chosen.joined(separator: ", ")
                }
            }
            // An untitled dialog, as an alert, is the operation's surface too, though it gives no title.
            if pending, !action.isMenu, roots[rootIndex].dialogTitle == nil, roots[rootIndex].operation != .edit,
               !title.isEmpty || window != nil && window != roots[rootIndex].document {
                roots[rootIndex].surface = window
                if !title.isEmpty { roots[rootIndex].dialogTitle = title }
            }
            if save {
                roots[rootIndex].path = ["⌘S"]
                roots[rootIndex].conclusions.append(Conclusion(action: index, kind: .commit, label: "⌘S",
                    commitLike: true, observability: .unrepresented, evidence: "Save shortcut; storage persistence is not AX state"))
            } else if choice {
                // An untitled surface or a loose menu gives no path; the choice is named by its label alone.
                roots[rootIndex].path = openedBy + [immediateChoices[index] ?? ""].filter { !$0.isEmpty }
                roots[rootIndex].conclusions.append(Conclusion(action: index, kind: .apply,
                    label: action.label ?? "", commitLike: true, observability: .unrepresented,
                    evidence: immediateChoices[index] != nil ? "labelled choice on an auxiliary surface opened by an earlier action"
                        : "menu item that no pending operation owns"))
            } else if let button, button != .close {
                let child = window.map { roots[rootIndex].childSurfaces.contains($0) } == true
                let contextual = roots[rootIndex].operation != .context && !child
                if child && button == .cancel, let window { roots[rootIndex].childSurfaces.remove(window) }
                if contextual {
                    if roots[rootIndex].operation == .menu { roots[rootIndex].operation = .other }
                    let kind: Resolution = button == .cancel ? .cancel : button == .apply ? .apply : .commit
                    roots[rootIndex].conclusions.append(Conclusion(action: index, kind: kind, label: action.label ?? "",
                        commitLike: kind != .cancel, observability: .represented))
                }
            } else if action.kind == .shortcut, action.commandName == "Escape", window != nil,
                      window != roots[rootIndex].document, [.create, .other].contains(roots[rootIndex].operation) {
                roots[rootIndex].conclusions.append(Conclusion(action: index, kind: .cancel, label: "Escape",
                    commitLike: false, observability: .represented, evidence: "Escape in a dialog"))
            } else if action.kind == .shortcut, ["Return", "Enter"].contains(action.commandName ?? ""),
                      [.create, .edit, .other].contains(roots[rootIndex].operation) {
                roots[rootIndex].conclusions.append(Conclusion(action: index, kind: .implicit,
                    label: action.commandName ?? "Return", commitLike: false, observability: .represented,
                    evidence: "Return in operation; requires compatible observed outcome"))
            }
            if roots[rootIndex].operation == .other,
               action.role == "AXMenuItem" || roots[rootIndex].terminal?.action == index,
               roots[rootIndex].terminal?.kind != .cancel, let document = roots[rootIndex].document {
                roots[rootIndex].affected = action.provenance?.affectedObjects(in: document, processID: action.processID, actionWindow: action.windowNumber) ?? []
            }
            if roots[rootIndex].isPending && !save && !choice && !pendingRoots.contains(rootIndex) {
                pendingRoots.append(rootIndex)
                if pendingRoots.count > 16 { pendingRoots.removeFirst() }
            }
            pendingRoots.removeAll { !roots[$0].isPending }
            active = (save || choice) ? nil : rootIndex
        }
    }

    /// The document selection around an action on another surface: the nearest earlier probe is required, a later one
    /// must agree, only input on other surfaces may intervene, and exactly one collection may show a selection.
    static func selection(around index: Int, in document: Int,
                          actions: [HumanRecordedInteraction.SummaryAction],
                          scenes: [Int: SceneSnapshot], aliases: [String: String] = [:]) -> (collection: String, names: [String])? {
        let action = actions[index]
        guard action.windowNumber.map({ $0 != document }) == true,
              let time = action.provenance?.interval, time.isValid else { return nil }
        let members = scenes[document].map(HumanInterventionScene.members) ?? [:]
        enum Reading { case unread, ambiguous, selected(String, [String]) }
        func reading(_ snapshot: InteractionSemanticSnapshot?, before: Bool) -> Reading {
            guard let snapshot, snapshot.processID == action.processID, snapshot.interval.isValid,
                  before ? snapshot.interval.end <= time.start && time.start - snapshot.interval.end <= 15
                         : snapshot.interval.start >= time.end && snapshot.interval.start - time.end <= 15
            else { return .unread }
            switch selected(in: snapshot, window: document) {
            case .unread: return .unread
            case .ambiguous: return .ambiguous
            case .rows(let title, let objects):
                // A row's accessible label decorates its name; the longest member name it contains is the name.
                let known = members[title] ?? []
                let names = objects.compactMap(\.label).map { aliases[$0] ?? $0 }.map { label in
                    known.filter { label.contains($0) }.max { $0.count < $1.count } ?? label
                }
                return .selected(title, names)
            }
        }
        func admissible(_ other: HumanRecordedInteraction.SummaryAction) -> Bool {
            other.processID == action.processID && other.windowNumber.map { $0 != document } == true
        }
        // Earlier probes: this action's own, then each earlier action's later and earlier probes.
        var earlier: Reading = reading(action.provenance?.beforeSemantics, before: true)
        var cursor = index - 1
        while case .unread = earlier, cursor >= 0 {
            earlier = reading(actions[cursor].provenance?.semantics, before: true)
            if case .unread = earlier, admissible(actions[cursor]) {
                earlier = reading(actions[cursor].provenance?.beforeSemantics, before: true)
            } else if case .unread = earlier { break }
            cursor -= 1
        }
        guard case .selected(let collection, let names) = earlier else { return nil }
        var later: Reading = reading(action.provenance?.semantics, before: false)
        cursor = index + 1
        while case .unread = later, cursor < actions.count {
            later = reading(actions[cursor].provenance?.beforeSemantics, before: false)
            if case .unread = later, admissible(actions[cursor]) {
                later = reading(actions[cursor].provenance?.semantics, before: false)
            } else if case .unread = later { break }
            cursor += 1
        }
        switch later {
        case .unread: return (collection, names)
        case .ambiguous: return nil
        case .selected(let other, let otherNames):
            return other == collection && Set(otherNames) == Set(names) ? (collection, names) : nil
        }
    }

    enum Selected { case unread, ambiguous, rows(String, [InteractionSemanticSnapshot.Element]) }

    /// What one probe read selected in a window: nothing read, more than one candidate collection, or the
    /// labelled rows of exactly one titled collection.
    static func selected(in snapshot: InteractionSemanticSnapshot, window: Int) -> Selected {
        let tables: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"]
        let read = snapshot.elements.filter {
            $0.window == window && tables.contains($0.role ?? "") && !$0.isProtected
                && ($0.selectedRows.value != nil || $0.selectedChildren.value != nil)
        }
        guard !read.isEmpty else { return .unread }
        let holding = read.filter { !(($0.selectedRows.value ?? []) + ($0.selectedChildren.value ?? [])).isEmpty }
        guard holding.count == 1, let collection = holding.first, !collection.selectionIncomplete,
              let title = collection.label, !title.isEmpty else { return .ambiguous }
        let ids = Set((collection.selectedRows.value ?? []) + (collection.selectedChildren.value ?? []))
        let objects = snapshot.elements.filter { ids.contains($0.id) }
        guard objects.count == ids.count, objects.allSatisfy({ !$0.isProtected && $0.label?.isEmpty == false })
        else { return .ambiguous }
        return .rows(title, objects)
    }

    /// The rows some actions acted on: the selection that every probe around them read in one collection of the
    /// document, with each row's index. Probes after `end` read what it left. Disagreeing probes, or none, attest nothing.
    static func targets(of indexes: [Int], in document: Int, actions: [HumanRecordedInteraction.SummaryAction],
                        until end: Int? = nil) -> (collection: String, rows: [(label: String, index: Int?)])? {
        var found: (title: String, rows: [InteractionSemanticSnapshot.Element])?
        for index in indexes where end.map({ index <= $0 }) ?? true {
            guard let provenance = actions[index].provenance, provenance.interval.isValid else { continue }
            let probes = [provenance.beforeSemantics.flatMap {
                $0.interval.isValid && provenance.interval.start - $0.interval.end <= 15 ? $0 : nil
            }, index == end ? nil : provenance.semantics]
            for snapshot in probes.compactMap({ $0 }) where snapshot.processID == actions[index].processID {
                switch selected(in: snapshot, window: document) {
                case .unread: continue
                case .ambiguous: return nil
                case .rows(let title, let rows):
                    if let found, found.title != title
                        || Set(found.rows.compactMap(\.label)) != Set(rows.compactMap(\.label)) { return nil }
                    found = (title, rows)
                }
            }
        }
        return found.map { ($0.title, $0.rows.map { ($0.label ?? "", $0.index.value) }) }
    }

    /// Every row label a probe read, by the title of its collection. What rows share is decoration.
    static func rowLabels(_ actions: [HumanRecordedInteraction.SummaryAction]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for action in actions {
            for snapshot in [action.provenance?.beforeSemantics, action.provenance?.semantics].compactMap({ $0 }) {
                for row in snapshot.elements where row.role == "AXRow" {
                    guard let label = row.label, let parent = row.parent,
                          let title = snapshot.elements.first(where: { $0.id == parent })?.label else { continue }
                    result[title, default: []].insert(label)
                }
            }
        }
        return result
    }
}

extension HumanInterventionThreads {
    /// Which window each action worked on as its document, and which actions were choices on an auxiliary surface
    /// an earlier action opened (a palette, a sheet of options): the windows a command is about.
    struct Surfaces {
        var documentByAction: [Int: Int] = [:]
        var choices: [Int: String] = [:]

        init(initial: [Int: SceneSnapshot], findings: [HumanSceneFinding],
             decoded: [HumanSceneFinding.SceneEvidence], actions: [HumanRecordedInteraction.SummaryAction],
             actionIndexes: [UInt64: Int]) {
            var scenes = initial
            var documents: [Int32: Int] = [:]
            var auxiliary: [Int: (document: Int, process: Int32, opener: Int)] = [:]
            var lifetimeStart: [Int: Int] = [:]
            var closures: [Int: [Int]] = [:]
            var lastIndex = -1
            for (finding, read) in zip(findings, decoded) {
                let index = actionIndexes[finding.sequence]
                if let index { lastIndex = index }
                guard actions.indices.contains(lastIndex) else { continue }
                let action = actions[lastIndex]
                let process = action.processID
                if documents[process] == nil {
                    let baseline = action.windowNumber.flatMap { initial[$0] != nil ? $0 : nil }
                        ?? initial.keys.sorted().first { initial[$0]?.bundleID == read.scenes.values.first?.bundleID }
                    documents[process] = baseline
                }
                for window in read.scenes.keys.sorted() {
                    guard let scene = read.scenes[window] else { continue }
                    if scenes[window] == nil, let document = documents[process], window != document,
                       let parent = scenes[document], scene.bundleID == parent.bundleID {
                        let smaller = scene.viewportPixelSize.width < parent.viewportPixelSize.width
                            && scene.viewportPixelSize.height < parent.viewportPixelSize.height
                        let firstAction = actions.indices.first {
                            $0 >= (lifetimeStart[window] ?? 0) && $0 <= lastIndex && actions[$0].windowNumber == window
                        } ?? (lastIndex + 1)
                        let opener = actions.indices.prefix(firstAction).last {
                            $0 >= (lifetimeStart[window] ?? 0)
                                && actions[$0].processID == process && actions[$0].windowNumber != window
                                && (actions[$0].windowNumber == document || actions[$0].isMenu)
                                && [.click, .shortcut].contains(actions[$0].kind)
                        }
                        // A window as large as the document is another document, whatever its title.
                        if smaller || HumanInterventionScene.isTransient(scene), let opener {
                            auxiliary[window] = (document, process, opener)
                        }
                    }
                    scenes[window] = scene
                    if auxiliary[window] == nil, !HumanInterventionScene.isTransient(scene) {
                        documents[process] = window
                    }
                    if let surface = auxiliary[window], surface.process == process,
                       !HumanInterventionScene.isTransient(scene) {
                        // A covering read can arrive after the choice and supply its missing native role.
                        for candidate in (surface.opener + 1)..<(lastIndex + 1) where actions[candidate].windowNumber == window {
                            if choices[candidate] == nil, Self.isChoice(actions[candidate], in: scene),
                               actions[candidate].processID == surface.process {
                                choices[candidate] = scene.windowTitle
                                documentByAction[candidate] = surface.document
                            }
                        }
                    }
                }
                if let index {
                    if let window = action.windowNumber, let surface = auxiliary[window],
                       surface.process == process, index > surface.opener, let scene = scenes[window],
                       !HumanInterventionScene.isTransient(scene), Self.isChoice(action, in: scene) {
                        choices[index] = scene.windowTitle
                    }
                    documentByAction[index] = documents[process]
                }
                for window in read.closedWindowNumbers {
                    scenes[window] = nil
                    auxiliary[window] = nil
                    lifetimeStart[window] = lastIndex + 1
                    closures[window, default: []].append(lastIndex + 1)
                    documents = documents.filter { $0.value != window }
                }
            }
            dropUnlabelledBesideLabelled(actions, closures: closures)
        }

        /// A surface that labels its choices does not hide one behind an unlabelled control: during a
        /// lifetime with a labelled choice, unlabelled clicks there are handling, not further choices.
        private mutating func dropUnlabelledBesideLabelled(_ actions: [HumanRecordedInteraction.SummaryAction],
                                                           closures: [Int: [Int]]) {
            func labelled(_ index: Int) -> Bool { actions[index].label?.isEmpty == false }
            for index in Array(choices.keys) where !labelled(index) {
                guard let window = actions[index].windowNumber else { continue }
                let sameLifetime = choices.keys.contains { other in
                    labelled(other) && actions[other].windowNumber == window
                        && !(closures[window] ?? []).contains { $0 > min(index, other) && $0 <= max(index, other) }
                }
                if sameLifetime { choices[index] = nil }
            }
        }

        private static func isChoice(_ action: HumanRecordedInteraction.SummaryAction, in scene: SceneSnapshot) -> Bool {
            let roles: Set<String> = ["AXButton", "AXCell", "AXRadioButton", "AXMenuItem", "AXRow"]
            // A button its window names as default or cancel concludes a dialog; it is never a choice.
            guard action.kind == .click, !action.isProtected, action.windowButton == nil else { return false }
            guard let label = action.label, !label.isEmpty else {
                // An unlabelled control is a choice only on a surface made of many controls of its own role,
                // such as a swatch grid; its identity stays unknown and is reported as such.
                guard let role = action.role, roles.contains(role) else { return false }
                return scene.elements.filter { $0.role == role }.count >= 4
            }
            guard HumanInterventionVocabulary.meaning(of: label) == nil else { return false }
            if let role = action.role { return roles.contains(role) }
            let matches = scene.elements.filter { $0.label == label && roles.contains($0.role ?? "") }
            return matches.count == 1
        }
    }
}
