import Foundation
import Switches

extension ModelText {
    nonisolated static let outcomeTexts: [Entry] = [
        Entry(key: .init(rawValue: "outcome.legend.v2"), owner: "AutomationMCP", delivery: .legend,
              budgetCharacters: 700,
              text: "\nAction results start with gesture · effect · recovery, for example sent · confirmed · continue. "
                + "Gesture says whether input was sent; effect says what was confirmed, absent, unknown or inapplicable. "
                + "Recovery is the single next step: continue, observe, avoid repeating, change target, ask the person or retry. "
                + "Read any attached observation before deciding. An unknown effect is not proof of completion.\n",
              legacy: false),
        Entry(key: .init(rawValue: "outcome.uncertain.v2"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "an action with an unknown effect", legacy: false),
        Entry(key: .init(rawValue: "outcome.act.v2"), owner: "AutomationMCP", delivery: .toolDescription(tool: "act"),
              budgetCharacters: 120,
              text: "acting. set_toggle requires value on/off. Follow recovery when the effect is unknown. ", legacy: false),
        Entry(key: .init(rawValue: "outcome.insert.v2"), owner: "AutomationMCP", delivery: .toolDescription(tool: "type_text"),
              budgetCharacters: 120,
              text: "Checked by reading the field's value back. When its effect is unknown, read the observation; ", legacy: false),
        Entry(key: .init(rawValue: "outcome.shortcut.v2"), owner: "AutomationMCP", delivery: .toolDescription(tool: "press_key"),
              budgetCharacters: 120,
              text: "Check the intended effect after a shortcut; follow recovery when the effect is unknown.", legacy: false),
        Entry(key: .init(rawValue: "outcome.toggle.v2"), owner: "AutomationMCP", delivery: .toolDescription(tool: "act"),
              budgetCharacters: 120,
              text: "an absent or unknown effect when it did not; follow recovery. No input is needed ", legacy: false),
    ]

    /// Selects outcome wording at the existing delivery point; the default arm preserves its bytes.
    nonisolated static func outcomeText(_ key: Key, fallback: String) -> String {
        guard SwitchBoard.current.arm("outcome", default: ResultFormatter.OutcomeArm.v1) == .v2 else { return fallback }
        let replacement: String? = switch key.rawValue {
        case "tool_catalogue.step.v1.23": "outcome.act.v2"
        case "tool_catalogue.step.v1.28": "outcome.insert.v2"
        default: nil
        }
        if let replacement { return entriesForOutcome(replacement) }
        if fallback == "Verify the intended effect after a shortcut; never repeat acted_unverified blindly." {
            return entriesForOutcome("outcome.shortcut.v2")
        }
        if fallback.hasPrefix("Verified by reading the field's value back. On acted_unverified") {
            return entriesForOutcome("outcome.insert.v2")
        }
        if fallback.hasPrefix("acted_unverified when it did not") { return entriesForOutcome("outcome.toggle.v2") }
        var text = fallback.replacingOccurrences(of: "an\nacted_unverified action", with: "an\naction with an unknown effect")
            .replacingOccurrences(of: "An acted_unverified operation", with: "An operation with an unknown effect")
            .replacingOccurrences(of: "remains acted_unverified", with: "has an unknown effect")
            .replacingOccurrences(of: "acted_unverified", with: "an unknown effect")
            .replacingOccurrences(of: "found_acted", with: "a confirmed effect")
            .replacingOccurrences(of: "acted_noop", with: "no requested input")
        if key.rawValue == "tool_catalogue.baseInstructions.v1.5" { text += entriesForOutcome("outcome.legend.v2") }
        return text
    }

    private nonisolated static func entriesForOutcome(_ key: String) -> String {
        guard let entry = outcomeTexts.first(where: { $0.key.rawValue == key }) else {
            preconditionFailure("Unknown outcome text key")
        }
        return entry.text
    }
}
