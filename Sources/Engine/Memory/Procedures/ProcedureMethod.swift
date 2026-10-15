//
//  ProcedureMethod.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import EngineCore
import PerceptionCore

/// ProcedureMethod tells whether two versions hold the same method: the same operations, in the same order,
/// on the same applications, whatever the values of one run. A completed task that repeats the method of a
/// current version of another task is a new run of it, not a new procedure: its version replaces that one in
/// the catalogue and inherits its verified steps (`QualificationPolicy` version B). Before, every run made a
/// procedure of its own: Invert three times and Grayscale three times on PhotoCraft left six (14 October 2026).
///
/// A step's signature keeps what decides what the operation does and leaves out what one run supplies:
/// - the application and the tool, and the arguments a relation of the Brain keeps fixed (a menu's path, a
///   key with its modifiers and count, an item chosen, a button, a toggle's value, replace or append);
/// - an argument the interpretation made a parameter or a template, as a parameter, whatever its value;
/// - a typed or inserted text, always as a parameter: a new value repeats the method;
/// - an element by its label, unless the label names a file (`SceneSkeleton.isContentCaption`), as a row of a
///   file list does: then by its role only. A pop-up a selection is made in is read by its role only, since its
///   title is often its current value;
/// - never the section an element was looked for in, which is a search hint.
///
/// Since the test runs of 14 October 2026, which left five of fifteen repeated tasks unmerged for no difference of
/// method, three more things are the same method: an element argument the interpretation made a parameter and the same
/// content item named literally (a file's row); `press` on a dialog's button and a click on that button; and the fields
/// of one dialog set in another order (consecutive steps that type, insert, select or set a switch). A fixed argument
/// made a parameter covers any value at it.
public enum ProcedureMethod {

    /// The signature of one definition step. `target` is the element its call resolved, as its check named it,
    /// when known: its label decides whether the element is content.
    public static func signature(of step: ProcedureStep, target: OperationCheck.Target?) -> String {
        guard let operation = step.operations.first else { return "\(step.bundleID ?? "?")|empty" }
        // A dialog's button pressed by its title is the click on it.
        if operation.tool == .press, let button = operation.arguments.first(where: { $0.name == "button" }),
           case .literal(let value) = button.value {
            return [step.bundleID ?? "?", AgentTool.act.rawValue, "target#0=\(LabelText.normalize(spelled(value)))", "verb#0=click"]
                .joined(separator: "|")
        }
        var parts = [step.bundleID ?? "?", operation.tool.rawValue]
        for argument in operation.arguments.sorted(by: { ($0.name, $0.position) < ($1.name, $1.position) }) {
            let name = "\(argument.name)#\(argument.position)"
            let role = role(of: argument.name, in: operation.tool)
            switch argument.value {
                case .parameter, .template:
                    switch role {
                        case .hint: continue
                        case .text: parts.append("\(name)=text")
                        // An element named by the task's value is a content item, as its literal name is.
                        case .element: parts.append("\(name)=item:\(target?.role ?? "element")")
                        case .control: parts.append("\(name)=\(target?.role ?? "control")")
                        case .fixed: parts.append("\(name)=\(parameter)")
                    }
                case .anchor(let id):
                    parts.append("\(name)=anchor:\(id)")
                case .menu(let id):
                    parts.append("\(name)=menu:\(id)")
                case .literal(let value):
                    switch role {
                        case .hint: continue
                        case .text: parts.append("\(name)=text")
                        case .control: parts.append("\(name)=\(target?.role ?? "control")")
                        case .element:
                            let label = target?.label ?? spelled(value)
                            parts.append(SceneSkeleton.isContentCaption(label) || SceneSkeleton.isContentCaption(spelled(value))
                                         ? "\(name)=item:\(target?.role ?? "element")" : "\(name)=\(LabelText.normalize(spelled(value)))")
                        case .fixed: parts.append("\(name)=\(LabelText.normalize(spelled(value)))")
                    }
            }
        }
        return parts.joined(separator: "|")
    }

    /// The value a fixed argument made a parameter takes in a signature: it covers any value at that argument.
    static let parameter = "parameter"

    /// Whether two versions' steps are one method: as many steps, each with a signature that matches the other's, where a
    /// run of consecutive steps that set fields (`setsAField`) may match in any order.
    public static func same(_ one: [String], _ other: [String]) -> Bool {
        guard one.count == other.count, !one.isEmpty else { return false }
        var index = 0
        while index < one.count {
            guard setsAField(one[index]) else {
                guard matches(one[index], other[index]) else { return false }
                index += 1
                continue
            }
            var end = index
            while end < one.count, setsAField(one[end]) { end += 1 }
            var unused = Array(other[index..<end])
            for signature in one[index..<end] {
                guard let found = unused.firstIndex(where: { matches(signature, $0) }) else { return false }
                unused.remove(at: found)
            }
            index = end
        }
        return true
    }

    /// Whether two step signatures are the same operation: the same tokens, a fixed argument made a parameter matching any
    /// value at the same argument.
    public static func matches(_ one: String, _ other: String) -> Bool {
        if one.utf8.elementsEqual(other.utf8) { return true }
        let left = one.split(separator: "|", omittingEmptySubsequences: false), right = other.split(separator: "|", omittingEmptySubsequences: false)
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { a, b in
            guard a != b else { return true }
            guard let equalsA = a.firstIndex(of: "="), let equalsB = b.firstIndex(of: "="), a[..<equalsA] == b[..<equalsB] else { return false }
            return a[a.index(after: equalsA)...] == Substring(parameter) || b[b.index(after: equalsB)...] == Substring(parameter)
        }
    }

    /// Whether a step's signature sets a field of a form or a dialog: types or inserts a text, chooses an item of a pop-up,
    /// sets a switch. Such steps of one form may be done in any order.
    static func setsAField(_ signature: String) -> Bool {
        let tokens = signature.split(separator: "|")
        guard tokens.count > 1 else { return false }
        switch tokens[1] {
            case Substring(AgentTool.typeText.rawValue), Substring(AgentTool.insertText.rawValue), Substring(AgentTool.select.rawValue): return true
            case Substring(AgentTool.act.rawValue): return tokens.contains("verb#0=settoggle") || tokens.contains("verb#0=set_toggle")
            default: return false
        }
    }

    /// What an argument is to a method's identity.
    enum Role { case fixed, element, control, text, hint }

    static func role(of argument: String, in tool: AgentTool) -> Role {
        switch (tool, argument) {
            case (_, "section"): .hint
            case (.typeText, "text"), (.insertText, "text"), (.insertText, "expected_value"), (.scroll, "lines"), (.drag, "distance"): .text
            case (.select, "control"): .control
            case (_, "target"), (_, "from"), (.drag, "to"): .element
            default: .fixed
        }
    }

    /// An argument's value as text.
    static func spelled(_ value: BrainArgument.Value) -> String {
        switch value {
            case .text(let text): text
            case .integer(let number): String(number)
            case .real(let number): String(number)
            case .boolean(let flag): flag ? "true" : "false"
        }
    }
}
