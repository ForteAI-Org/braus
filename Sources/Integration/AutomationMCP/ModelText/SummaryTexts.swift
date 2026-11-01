import Foundation

extension ModelText {
    nonisolated static let summaryTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "turn.compacted"),
            owner: "Turn",
            delivery: .summary,
            budgetCharacters: 49,
            text: "Braus compacted this conversation. Reply only: ok",
            legacy: false
        )
    ]
}
