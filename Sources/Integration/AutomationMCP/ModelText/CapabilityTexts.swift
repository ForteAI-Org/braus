extension ModelText {
    nonisolated static let capabilityTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "capability.unresolvedPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 33,
            text: "An earlier effect is unresolved (",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.unresolvedSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 46,
            text: "); reconcile it before this capability writes.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.historicalPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 42,
            text: "This value comes from an earlier attempt: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.historicalSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 43,
            text: ". Read it again or name it as a task input.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.failurePrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 19,
            text: "Capability failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.recordingFailure"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 20,
            text: ". Recording failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.recordingPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 18,
            text: "Recording failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.completedSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 39,
            text: ". The call completed. Do not repeat it.",
            legacy: false
        ),
    ]
}
