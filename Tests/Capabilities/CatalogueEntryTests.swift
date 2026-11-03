import Capabilities
import LocalMCP
import Testing

@Suite
struct CatalogueEntryTests {
    @Test func preservesContractSchemaAndExamples() {
        let entry = searchEntry("scroll", description: "Scroll a list", examples: ["Scroll down", "Scorri la lista"])
        #expect(entry.contract.id.rawValue == "scroll")
        #expect(entry.contract.inputSchema["additionalProperties"] == .bool(false))
        #expect(entry.exampleQuestions == ["Scroll down", "Scorri la lista"])
        #expect(entry.isStrict)
        let copy = searchEntry("scroll", description: "Scroll a list", examples: ["Scroll down", "Scorri la lista"])
        #expect(entry == copy)
    }
}

func searchEntry(
    _ name: String,
    group: String = "",
    description: String = "",
    properties: [String: JSONValue] = [:],
    examples: [String] = []
) -> CatalogueEntry {
    CatalogueEntry(
        contract: CapabilityContract(
            id: CapabilityID(rawValue: name),
            group: group,
            description: description,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)
            ]),
            effect: .read,
            interruption: .readOnly,
            verification: .none(reason: "Result only"),
            channel: .braus,
            origin: .core,
            memory: .notRecorded(reason: "Test input"),
            takesSession: false
        ),
        exampleQuestions: examples
    )
}
