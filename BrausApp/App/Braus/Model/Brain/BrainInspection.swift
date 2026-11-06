import EngineCore
import Foundation
import Memory
import PerceptionCore

/// BrainInspection indexes one saved snapshot for both diagnostic views. Screen labels identify
/// observed states in this snapshot, not stable screen types, document instances or reusable methods.
nonisolated struct BrainInspection {
    let brain: StoredBrain
    let names: [String: String]
    let elementsByScene: [String: [SceneElementRecord]]

    init(_ brain: StoredBrain) {
        self.brain = brain
        names = Dictionary(uniqueKeysWithValues: brain.scenes.enumerated().map { index, scene in
            (scene.id, String(localized: "Observed screen \(index + 1)"))
        })
        elementsByScene = Dictionary(grouping: brain.elements, by: \.sceneID)
    }

    func scene(_ id: String?) -> String {
        id.flatMap { names[$0] } ?? String(localized: "Screen not identified")
    }

    func stateDetails(_ id: String) -> String {
        let captions = Set(elementsByScene[id, default: []].filter {
            $0.scope == .control && ($0.labelOrigin == .title || $0.labelOrigin == .description)
        }.map(Self.element))
        let others = Set(brain.scenes.filter { $0.id != id }
            .flatMap { elementsByScene[$0.id, default: []] }
            .filter { $0.scope == .control && ($0.labelOrigin == .title || $0.labelOrigin == .description) }
            .map(Self.element))
        let distinct = captions.subtracting(others).sorted().prefix(6).joined(separator: ", ")
        return distinct.isEmpty ? "" : String(localized: "Controls seen only in this screen: \(distinct)")
    }

    func target(_ relation: BrainRelation) -> String {
        guard let key = relation.key.elementKey else { return String(localized: "No individual control recorded") }
        let matches = elementsByScene[relation.key.fromSceneID, default: []].filter { $0.elementKey == key }
        guard matches.count == 1, let element = matches.first else {
            return String(localized: "Control not identified in this snapshot")
        }
        return Self.element(element)
    }

    func description(_ relation: BrainRelation) -> String {
        [actionTitle(relation),
         String(localized: "Before the action") + ": " + scene(relation.key.fromSceneID),
         String(localized: "Observed result") + ": " + Self.outcome(relation),
         String(localized: "After the action") + ": " + scene(relation.key.toSceneID)].joined(separator: "\n")
    }

    /// Only a uniquely recorded control supplies a target caption. Focus is not inferred.
    func actionTitle(_ relation: BrainRelation) -> String {
        let action = Self.action(relation)
        guard relation.key.verb != .pressKey, relation.key.verb != .menu,
              relation.key.elementKey != nil else { return action }
        return action + ": " + target(relation)
    }

    func graphAction(_ relation: BrainRelation) -> String {
        relation.key.verb == .menu ? Self.graphAction(relation) : actionTitle(relation)
    }

    func evidence(_ relation: BrainRelation) -> String {
        Self.standing(relation.standing) + "\n"
            + String(localized: "Matching results") + ": " + relation.supports.formatted()
            + " · " + String(localized: "Conflicting results") + ": " + relation.contradictions.formatted()
    }

    /// An immutable scene element has an initial record count, not a running sighting count.
    /// Confirmed observation totals belong to the scene and are never inferred for each control.
    static func observations(_ scene: SceneDefinition) -> String {
        String(localized: "Saved readings of this screen") + ": " + scene.observationCount.formatted()
    }

    static func isUnnamedControl(_ element: SceneElementRecord) -> Bool {
        element.scope == .control && (element.label?.isEmpty != false
            || (element.labelOrigin != .title && element.labelOrigin != .description))
    }

    static func graphAction(_ relation: BrainRelation) -> String {
        guard relation.key.verb == .menu,
              let path = relation.key.argumentsKey.split(separator: ";").first(where: { $0.hasPrefix("path=") })
        else { return action(relation) }
        let command = path.dropFirst(5).split(separator: ">").last.map(String.init) ?? ""
        return command.isEmpty ? action(relation) : String(localized: "Menu") + " · " + command
    }

    static func element(_ element: SceneElementRecord) -> String {
        switch element.scope {
        case .container: return String(localized: "Container")
        case .collection: return String(localized: "Collection")
        case .itemTemplate: return String(localized: "Repeated item")
        case .control:
            if let label = element.label, !label.isEmpty {
                // Collections and unknown-origin labels are not promoted into stable method names.
                if element.labelOrigin == .title || element.labelOrigin == .description {
                    if case .instance(_, .fileName) = MethodText.admit(label, in: .init(role: element.role)) {
                        return String(localized: "Document control")
                    }
                    return label.replacingOccurrences(of: "[withheld]", with: String(localized: "Content omitted"))
                }
            }
            return String(localized: "Unnamed control")
        }
    }

    static func standing(_ value: BrainRelation.Standing) -> String {
        switch value {
        case .candidate: String(localized: "Awaiting confirmation; not available for reuse")
        case .exposed: String(localized: "Enough matching results; available for reuse")
        case .limited: String(localized: "Conflicting results; reuse is limited")
        }
    }

    static func action(_ relation: BrainRelation) -> String {
        let fields = Dictionary(relation.key.argumentsKey.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }, uniquingKeysWith: { first, _ in first })
        if relation.key.verb == .pressKey {
            let modifiers = fields["modifiers", default: ""].split(separator: "+").sorted {
                let order = ["ctrl": 0, "control": 0, "alt": 1, "option": 1, "shift": 2, "cmd": 3]
                return order[String($0), default: 4] < order[String($1), default: 4]
            }.map { modifier in
                switch modifier {
                case "cmd": "⌘"
                case "shift": "⇧"
                case "alt", "option": "⌥"
                case "ctrl", "control": "⌃"
                default: String(modifier)
                }
            }.joined()
            let rawKey = fields["key", default: ""]
            let key = rawKey == "return" || rawKey == "enter" ? String(localized: "Return key") : rawKey.uppercased()
            let count = fields["count"].flatMap(Int.init) ?? 1
            return String(localized: "Press key") + " " + modifiers + key
                + (count > 1 ? " ×\(count)" : "")
        }
        switch relation.key.verb {
        case .click: return String(localized: "Click")
        case .doubleClick: return String(localized: "Double-click")
        case .tripleClick: return String(localized: "Triple-click")
        case .rightClick: return String(localized: "Right-click")
        case .setToggle: return String(localized: "Set control state")
        case .select: return String(localized: "Select item")
        case .typeText, .insertText: return String(localized: "Enter text")
        case .scroll: return String(localized: "Scroll")
        case .drag: return String(localized: "Drag")
        case .contextMenu: return String(localized: "Choose context-menu command")
        case .menu:
            let path = fields["path", default: ""].split(separator: ">").map(String.init).joined(separator: " › ")
            return String(localized: "Choose menu command") + (path.isEmpty ? "" : ": " + path)
        case .press: return String(localized: "Press button")
        case .pressKey: return String(localized: "Press key")
        }
    }

    static func outcome(_ relation: BrainRelation) -> String {
        switch relation.key.outcome {
        case .stateSet: return String(localized: "Control state set")
        case .alreadySatisfied: return String(localized: "Already in the requested state")
        case .valueSet: return String(localized: "Value set")
        case .itemChosen: return String(localized: "Item chosen")
        case .windowSetChanged: return String(localized: "Window set changed")
        case .effect:
            switch relation.key.effectKind {
            case "elementsAppeared": return String(localized: "Elements appeared")
            case "elementsDisappeared": return String(localized: "Elements disappeared")
            case "menuOpened": return String(localized: "Menu opened")
            case "stateFlip": return String(localized: "Control state changed")
            case "windowTitleChanged": return String(localized: "Window title changed")
            default: return String(localized: "Observed structural change")
            }
        }
    }
}
