import AppAdapters
import AutomationRuntime

extension ModelText {
    nonisolated static let serviceTexts: [Entry] = [
        Entry(key: .init(rawValue: "adapter.argumentsRejected"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "The adapter rejected the arguments before invocation.", legacy: false),
        Entry(key: .init(rawValue: "adapter.notInvoked"), owner: "AutomationMCP", delivery: .summary,
              budgetCharacters: 80, text: "The adapter was not invoked.", legacy: false),
        Entry(
            key: .init(rawValue: "adapter.protectedPath"),
            owner: "AppAdapters",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 100,
            text: AdapterText.protectedPathRefusal,
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "recall.modelReleased"),
            owner: "AutomationRuntime",
            delivery: .toolAnswer(tool: "plan"),
            budgetCharacters: 80,
            text: RecallService.releasedModelNote,
            legacy: false
        ),
    ]
}
