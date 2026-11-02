import Foundation

struct ReplayExceptions: Decodable {
    let recorded: [String: Set<String>]
    let regenerated: [String: Set<String>]
    let historicalBudget: [String: Set<String>]
    let regeneratedBudget: [String: Set<String>]

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: ReplayCorpus.fixtures
            .appending(path: "known-exceptions.json")))
    }

    static func differences(actual: Set<String>, expected: Set<String>) -> Set<String> {
        actual.symmetricDifference(expected)
    }
}
