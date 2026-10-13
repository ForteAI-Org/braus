//
//  TransitionEffectRecord.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import PerceptionCore

/// TransitionEffectRecord is a learned transition's effect in the columns the living memory keeps,
/// and the way back to the exact string `LearnedTransition.effect` holds. The string itself is
/// never stored: `kind` is the effect's family, `text` the title of a navigation, the two state
/// columns a flip's direction, `label` and `value` the field and the text a value change names, and
/// the ordered `items` the labels of the three list effects, one row each in
/// `brain_transition_menu_items`. A selection change carries nothing but its family. The string is
/// rebuilt in memory only, for the current consumers, and it is rebuilt exactly: an effect string
/// the vocabulary cannot decode, or one whose decoding does not encode back to the same string (a
/// label that is empty beside another, so the separator loses it), is refused as unrepresentable
/// rather than stored as a different fact.
public struct TransitionEffectRecord: Sendable, Equatable {

    /// The seven families the vocabulary knows, as `SceneEffect.family` names them.
    public static let kinds: Set<String> = [
        "windowTitleChanged", "stateFlip", "menuOpened", "elementsAppeared", "elementsDisappeared",
        "textSelectionChanged", "valueChanged",
    ]

    public let kind: String
    public let text: String?
    public let requiredState: ControlState?
    public let resultingState: ControlState?
    public let label: String?
    public let value: String?
    public let items: [String]

    /// The record of an effect string, or the reason it cannot be one.
    public init(effect: String) throws {
        guard let decoded = SceneEffect(encoded: effect) else {
            throw BrainProjectionError.unrepresentableEffect(effect, .undecodable)
        }
        guard decoded.encoded == effect else {
            throw BrainProjectionError.unrepresentableEffect(effect, .notCanonical)
        }
        switch decoded {
            case .windowTitleChanged(let title):
                self.init(decoded.family, text: title, required: nil, resulting: nil, items: [])
            case .stateFlip(let from, let to):
                self.init(decoded.family, text: nil, required: from, resulting: to, items: [])
            case .menuOpened(let labels), .elementsAppeared(let labels), .elementsDisappeared(let labels):
                self.init(decoded.family, text: nil, required: nil, resulting: nil, items: labels)
            case .textSelectionChanged:
                self.init(decoded.family, text: nil, required: nil, resulting: nil, items: [])
            case .valueChanged(let label, let value):
                self.init(
                    decoded.family,
                    text     : nil,
                    required : nil,
                    resulting: nil,
                    label    : label,
                    value    : value,
                    items    : []
                )
        }
    }

    /// The record read back from its columns, refusing a shape the family does not have: a
    /// navigation without its title, a flip without both states or a value change without its label
    /// and value, a value in a column the family leaves NULL, items under a scalar family (a
    /// selection change and a value change are), or a family the vocabulary does not know.
    public init(
        kind          : String,
        text          : String?,
        requiredState : String?,
        resultingState: String?,
        label         : String?,
        value         : String?,
        items         : [String]
    ) throws {
        guard Self.kinds.contains(kind) else { throw BrainProjectionError.unknownEffectKind(kind) }
        func state(_ code: String?) throws -> ControlState? {
            guard let code else { return nil }
            guard let known = ControlState(rawValue: code) else { throw BrainProjectionError.unknownControlState(code) }
            return known
        }
        let required = try state(requiredState), resulting = try state(resultingState)
        if kind != "valueChanged", label != nil || value != nil {
            throw BrainProjectionError.malformedEffect(kind, .forbiddenValue)
        }
        switch kind {
            case "windowTitleChanged":
                guard let text else { throw BrainProjectionError.malformedEffect(kind, .missingText) }
                guard required == nil, resulting == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenState) }
                guard items.isEmpty else { throw BrainProjectionError.malformedEffect(kind, .forbiddenItems) }
                self.init(kind, text: text, required: nil, resulting: nil, items: [])
            case "stateFlip":
                guard text == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenText) }
                guard let required, let resulting else { throw BrainProjectionError.malformedEffect(kind, .missingState) }
                guard items.isEmpty else { throw BrainProjectionError.malformedEffect(kind, .forbiddenItems) }
                self.init(kind, text: nil, required: required, resulting: resulting, items: [])
            case "menuOpened", "elementsAppeared", "elementsDisappeared":
                guard text == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenText) }
                guard required == nil, resulting == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenState) }
                self.init(kind, text: nil, required: nil, resulting: nil, items: items)
            case "textSelectionChanged":
                guard text == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenText) }
                guard required == nil, resulting == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenState) }
                guard items.isEmpty else { throw BrainProjectionError.malformedEffect(kind, .forbiddenItems) }
                self.init(kind, text: nil, required: nil, resulting: nil, items: [])
            case "valueChanged":
                guard text == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenText) }
                guard let label, let value else { throw BrainProjectionError.malformedEffect(kind, .missingValue) }
                guard required == nil, resulting == nil else { throw BrainProjectionError.malformedEffect(kind, .forbiddenState) }
                guard items.isEmpty else { throw BrainProjectionError.malformedEffect(kind, .forbiddenItems) }
                self.init(kind, text: nil, required: nil, resulting: nil, label: label, value: value, items: [])
            default:
                throw BrainProjectionError.unknownEffectKind(kind)
        }
        // The columns must rebuild a string the vocabulary would have produced, or a reader would
        // hand the brain a fact the writer could not have written.
        guard SceneEffect(encoded: effect)?.encoded == effect else {
            throw BrainProjectionError.malformedEffect(kind, .notCanonical)
        }
    }

    private init(
        _ kind   : String,
        text     : String?,
        required : ControlState?,
        resulting: ControlState?,
        label    : String? = nil,
        value    : String? = nil,
        items    : [String]
    ) {
        self.kind           = kind
        self.text           = text
        self.requiredState  = required
        self.resultingState = resulting
        self.label          = label
        self.value          = value
        self.items          = items
    }

    /// The decoded effect. Every construction validates `kind` against `kinds`, so no other family
    /// can reach here.
    public var sceneEffect: SceneEffect {
        switch kind {
            case "windowTitleChanged"  : .windowTitleChanged(title: text ?? "")
            case "stateFlip"           : .stateFlip(from: requiredState ?? .unknown, to: resultingState ?? .unknown)
            case "menuOpened"          : .menuOpened(labels: items)
            case "elementsAppeared"    : .elementsAppeared(labels: items)
            case "elementsDisappeared" : .elementsDisappeared(labels: items)
            case "textSelectionChanged": .textSelectionChanged
            case "valueChanged"        : .valueChanged(label: label ?? "", value: value ?? "")
            default                    : preconditionFailure("an effect family outside the validated vocabulary")
        }
    }

    /// The exact string `LearnedTransition.effect` holds for this effect.
    public var effect: String { sceneEffect.encoded }
}
