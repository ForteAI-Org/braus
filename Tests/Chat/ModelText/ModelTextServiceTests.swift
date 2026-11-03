import AutomationMCP
import Testing

struct ModelTextServiceTests {
    @Test func serviceFallbacksAreCatalogued() throws {
        let entries = Dictionary(uniqueKeysWithValues: ModelText.catalogue.map { ($0.key.rawValue, $0.text) })
        #expect(entries["adapter.protectedPath"] == "Changing a protected path needs the person's confirmation; nothing was done.")
        #expect(entries["outcome.human_intervention"] == "The person is controlling the application.")
        #expect(entries["recall.modelReleased"] == "the semantic model was released; the lexical index answered")
    }
}
