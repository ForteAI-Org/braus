//
//  RecallUseLinking.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallUseLinking finds, among the calls an attempt made after a selection was delivered, the ones that carried
/// out its steps. A call carries out the next step only when the facts show it did the same operation:
///
/// - the same tool, in the same application, and from the same functional state when both states are known;
/// - on the same element: the same functional identity when the Brain identified the element of both calls, else the
///   same label. The identity of a control (a key no other element of its capture had) is the element itself, so a
///   field labelled by its value is the same field under another value. An item template is what every row of a
///   collection offers: it says the call acted on such a row, and only the label says which, so the label is compared
///   too. A label that differs and no identity to prove it the same element is not that step, whatever the call's
///   own check says;
/// - on the object the task names, when the step's element is one of its values (a parameter or a template): the
///   call's element must be that value, bound and equal, whatever the identity says. A key tells the control apart,
///   never which record the task asked for;
/// - with the arguments that define the operation equal: the verb and the toggle's state, the item chosen, the
///   typed text, the key with its modifiers and count, the scroll's direction and amount, the drag's end or offset,
///   the menu path, the button;
/// - with every parameter of the step bound to a value, and the call using that value: an unresolved parameter is
///   no match for any value. A whole parameter of a number or a flag (`lines`, `count`, `dx`, `replace`) matches the
///   call's value its binding spells as that type, as D2 checks a use (`BrainArgument.Value.isSpelled(by:)`); a text
///   is compared as a text, digits or not.
///
/// Typed text and file names are compared as the person wrote them: only canonical Unicode equivalence is ignored,
/// never case or accents. Names the application shows (an item, a button, a menu path, a label) are compared
/// ignoring case and surrounding space, as the screen spells them. A call that matches a later step skips the ones
/// between, which stay not carried out; a call that matches none is the agent's own operation (a connector or a
/// deviation), unless it would carry out the next step were the facts it lacks to agree (its application not
/// recorded, the element's identity not derived while its label differs): that use is `undetermined`, neither a
/// confirmation nor a deviation. A step is confirmed when its call's own check passed. The rule reads facts only:
/// what the agent declares about its use is kept beside it, never in its place.
public enum RecallUseLinking {

    /// Call is one call of the attempt, as recorded: its tool and arguments, whether its check passed, the
    /// application it acted on, the functional state it started from and, when the Brain identified it, the
    /// functional identity of the element it acted on.
    public struct Call: Sendable {
        public let eventID: String
        public let request: AgentCallRequest
        public let checkPassed: Bool
        public let bundleID: String?
        public let entry: RecallSource.Entry
        public let elementKey: String?

        public init(eventID: String, request: AgentCallRequest, checkPassed: Bool, bundleID: String? = nil,
                    entry: RecallSource.Entry = .unknown, elementKey: String? = nil) {
            self.eventID    = eventID
            self.request    = request
            self.checkPassed = checkPassed
            self.bundleID   = bundleID
            self.entry      = entry
            self.elementKey = elementKey
        }
    }

    /// Link is a call and the step it carried out, or none; `undetermined` when the facts cannot tell whether it carried
    /// out the next step.
    public struct Link: Sendable, Equatable {
        public let callEventID: String
        public let stepPosition: Int?
        public let confirmed: Bool
        public var undetermined: Bool = false
    }

    /// How an argument's values are compared.
    enum Comparison {
        /// A name the application shows: case and surrounding space aside.
        case shown
        /// Text the person or the task wrote, or a file's name: canonical Unicode equivalence only.
        case written
        /// A number or a flag: equal values.
        case value
    }

    /// The arguments that define each tool's operation, with how they compare. The element arguments (`target`,
    /// `control`, `from`, `to`) are compared apart, as the element's identity.
    static let defining: [AgentTool: [String: Comparison]] = [
        .act: ["verb": .shown, "value": .shown], .select: ["item": .shown], .typeText: ["text": .written, "replace": .value],
        .insertText: ["text": .written, "expected_value": .written],
        .pressKey: ["key": .shown, "modifiers": .shown, "count": .value], .scroll: ["direction": .shown, "lines": .value],
        .drag: ["dx": .value, "dy": .value], .contextMenu: ["item": .shown], .menu: ["path": .shown], .press: ["button": .shown],
    ]

    /// The arguments that name the element an operation acts on: the first is the one the Brain identifies.
    static let elements: [AgentTool: [String]] = [
        .act: ["target"], .select: ["control"], .typeText: ["target"], .scroll: ["target"], .drag: ["from", "to"],
        .contextMenu: ["target"],
    ]

    /// The links of `calls`, in their order, to `steps` (the selection's steps in order), with `values` the textual
    /// binding each bound parameter took, by parameter id (a number's or a flag's spelled as text, as D2 binds it).
    public static func link(steps: [RecallSource.Step], calls: [Call], values: [String: String]) -> [Link] {
        var next = 0
        var links: [Link] = []
        for call in calls {
            if next < steps.count, let index = steps[next...].firstIndex(where: { matches($0, call, values: values) }) {
                links.append(Link(callEventID: call.eventID, stepPosition: steps[index].position, confirmed: call.checkPassed))
                next = index + 1
            } else {
                let undetermined = next < steps.count && matches(steps[next], call, values: values, factsMissing: true)
                links.append(Link(callEventID: call.eventID, stepPosition: nil, confirmed: false, undetermined: undetermined))
            }
        }
        return links
    }

    /// Whether a call carries out a step. With `factsMissing`, whether it would were the facts the call lacks (its
    /// application, the identity of the element it acted on) to agree: the test of an undetermined use.
    public static func matches(_ step: RecallSource.Step, _ call: Call, values: [String: String], factsMissing: Bool = false) -> Bool {
        let request = call.request
        guard step.tool == request.tool, let defining = defining[step.tool] else { return false }
        // The application: a call on another application, or on one the facts do not name, is not this step.
        if let bundle = step.bundleID {
            if let called = call.bundleID {
                guard called == bundle else { return false }
            } else if !factsMissing {
                return false
            }
        }
        // The functional context, when both are known.
        if case .state(let wanted) = step.entry, case .state(let found) = call.entry, wanted != found { return false }
        let recorded = request.arguments
        func given(_ name: String) -> [BrainArgument] { recorded.filter { $0.name == name }.sorted { $0.position < $1.position } }
        func expected(_ name: String) -> [OperationArgument] { step.arguments.filter { $0.name == name }.sorted { $0.position < $1.position } }

        // The element: its functional identity when both calls have one, else its name; and its name as well when the
        // identity is a row template, or when the name is the task's value.
        for (index, name) in (elements[step.tool] ?? []).enumerated() {
            let want = expected(name), got = given(name)
            if index == 0 {
                let named = want.contains { $0.value.isBound }
                if let mine = step.elementKey, let theirs = call.elementKey {
                    guard mine == theirs else { return false }
                    if !named, !SceneElementKey.isItemTemplate(mine) { continue }
                } else if factsMissing, let mine = step.elementKey, call.elementKey == nil, !named, !SceneElementKey.isItemTemplate(mine) {
                    continue
                }
            }
            guard want.count == got.count else { return false }
            for (argument, value) in zip(want, got) {
                guard same(argument.value, value.value, as: argument.value.isBound ? .written : .shown, values: values) else { return false }
            }
        }
        // The section names the panel an element is in: when both name one, it must be the same.
        if let mine = expected("section").first, let theirs = given("section").first,
           !same(mine.value, theirs.value, as: .shown, values: values) {
            return false
        }
        // The arguments that define the operation: the same set, the same values.
        for (name, comparison) in defining {
            let want = expected(name), got = given(name)
            guard want.count == got.count else { return false }
            if name == "modifiers" {
                guard Set(want.compactMap { resolved($0.value, values: values).map(shownKey) })
                        == Set(got.compactMap { text(of: $0.value).map(shownKey) }),
                      want.allSatisfy({ resolved($0.value, values: values) != nil }) else { return false }
                continue
            }
            for (argument, value) in zip(want, got) {
                guard same(argument.value, value.value, as: comparison, values: values) else { return false }
            }
        }
        return true
    }

    /// Whether a step's argument and a call's value are the same, under the comparison; a parameter or a template
    /// whose value is not bound is never the same as anything.
    static func same(_ step: OperationValue, _ call: BrainArgument.Value, as comparison: Comparison, values: [String: String]) -> Bool {
        switch step {
            case .literal(let value):
                switch (value, call) {
                    case (.text(let a), .text(let b)): return equal(a, b, comparison == .written ? .written : .shown)
                    case (.integer(let a), .integer(let b)): return a == b
                    case (.real(let a), .real(let b)): return a == b
                    case (.boolean(let a), .boolean(let b)): return a == b
                    default: return false
                }
            case .menu(let path):
                guard case .text(let b) = call else { return false }
                return equal(path, b, .shown)
            case .parameter(let id):
                guard let binding = values[id] else { return false }
                guard case .text(let b) = call else { return call.isSpelled(by: binding) }
                return equal(binding, b, comparison == .shown ? .shown : .written)
            case .template:
                guard let wanted = resolved(step, values: values), case .text(let b) = call else { return false }
                return equal(wanted, b, comparison == .shown ? .shown : .written)
            case .anchor:
                return false
        }
    }

    /// The text a step's argument stands for: its literal, or its parameters' bound values; nil when unbound.
    static func resolved(_ value: OperationValue, values: [String: String]) -> String? {
        switch value {
            case .literal(.text(let text)), .menu(let text): return text
            case .literal: return nil
            case .parameter(let id): return values[id]
            case .template(let segments):
                var rendered = ""
                for segment in segments {
                    switch segment {
                        case .literal(let text): rendered += text
                        case .parameter(let id):
                            guard let value = values[id] else { return nil }
                            rendered += value
                    }
                }
                return rendered
            case .anchor: return nil
        }
    }

    static func text(of value: BrainArgument.Value) -> String? {
        if case .text(let text) = value { return text } else { return nil }
    }

    static func equal(_ a: String, _ b: String, _ comparison: Comparison) -> Bool {
        switch comparison {
            case .written, .value: return a == b
            case .shown          : return shownKey(a) == shownKey(b)
        }
    }

    /// A name as the screen shows it, compared without case or surrounding space; accents and width stay.
    static func shownKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension OperationValue {
    /// Whether the value is the task's (a parameter or a template), not the source's literal.
    var isBound: Bool {
        switch self {
            case .parameter, .template: true
            default                   : false
        }
    }
}
