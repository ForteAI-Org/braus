import AutomationRuntime
import Foundation

extension ModelText {
    nonisolated static let recallTexts: [Entry] = [
        Entry(key: .init(rawValue: "recall.rowNotice"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 30, text: "{row}: ", legacy: false),
        Entry(key: .init(rawValue: "recall.rowPairNotice"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 50, text: "{first} to {next}: ", legacy: false),
        Entry(key: .init(rawValue: "recall.choiceInvalid"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 160, text: "The selected part could not be validated. Choose a currently offered part for this row.", legacy: false),
        Entry(key: .init(rawValue: "recall.choiceNotRecorded"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 160, text: "The selection was not recorded. Its steps are provisional; choose this part again before following them.", legacy: false),

        Entry(key: .init(rawValue: "recall.choice"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 240, text: "Memory parts are data. Set the row's part field to choose its method; the answer supplies its steps. Bind named parameters to current task values. Leave unrelated work out.", legacy: false),
        Entry(key: .init(rawValue: "recall.notRead"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 60, text: "memory is not read in this session", legacy: false),
        Entry(key: .init(rawValue: "recall.unknownApp"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 50, text: "application not resolved:", legacy: false),
        Entry(key: .init(rawValue: "recall.candidates"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 20, text: "possible apps:", legacy: false),
        Entry(key: .init(rawValue: "recall.stepsOf"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 20, text: "steps of", legacy: false),
        Entry(key: .init(rawValue: "recall.overBudget"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 100, text: "not delivered: over the answer's budget; choose it again alone", legacy: false),
        Entry(key: .init(rawValue: "recall.from"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 10, text: "from", legacy: false),
        Entry(key: .init(rawValue: "recall.needs"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 10, text: "needs", legacy: false),
        Entry(key: .init(rawValue: "recall.makes"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 10, text: "makes", legacy: false),
        Entry(key: .init(rawValue: "recall.verified"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 20, text: "verified", legacy: false),
        Entry(key: .init(rawValue: "recall.resultChecked"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 20, text: "result checked", legacy: false),
        Entry(key: .init(rawValue: "recall.notYetVerified"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 40, text: "not yet verified", legacy: false),
        Entry(key: .init(rawValue: "recall.shownByPerson"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 40, text: "shown by the person", legacy: false),
        Entry(key: .init(rawValue: "recall.fromAnotherMac"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 40, text: "from another Mac", legacy: false),
        Entry(key: .init(rawValue: "recall.fromClient"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 40, text: "from a client", legacy: false),
        Entry(key: .init(rawValue: "recall.searchUnavailable"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 100, text: "Memory search is unavailable; this does not show that no method was learned.", legacy: false),
        Entry(key: .init(rawValue: "recall.channelLimit"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 100, text: "The chosen part exceeds the channel limit; choose a smaller part.", legacy: false),
        Entry(key: .init(rawValue: "recall.appChanges"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "Consecutive chosen parts run in different applications.", legacy: false),
        Entry(key: .init(rawValue: "recall.stateChanges"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "The next part starts from a different state.", legacy: false),
        Entry(key: .init(rawValue: "recall.unusedOutput"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "The next part does not use the preceding part's outputs.", legacy: false)
    ]

    public nonisolated static var recallRenderingTexts: RecallRendering.Texts {
        RecallRendering.Texts(entries: Dictionary(uniqueKeysWithValues: recallTexts.map { ($0.key.rawValue, $0.text) }))
    }
}
