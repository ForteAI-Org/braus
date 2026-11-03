import EngineCore
import Testing
@testable import braus

struct GestureExpectCLITests {
    private let header = ["batch", "Test", "--window", "Panel", "--seat", "--"]

    @Test func cliPredicatesUseThePublicScreenDecoder() throws {
        let plan = try BatchPlan(arguments: header + [
            "act", "Export", "--expect", #"{"window":"Export","open":true}"#,
            "--then", "select", "Format", "Text", "--expect", #"{"element":"Format","value":"Text"}"#])
        #expect(plan.expectations == [.window(title: "Export", open: true), .element(label: "Format", expect: .value("Text"))])
        #expect(try BatchPlan(arguments: header + ["act", "Export"]).expectations == [nil])
        let standalone = Invocation(arguments: ["act", "Export", "--expect", "predicate"])
        #expect(standalone.flags.contains("expect"))
        #expect(standalone.positionals == ["Export", "predicate"])
        #expect(throws: (any Error).self) {
            _ = try BatchPlan(arguments: header + ["act", "Export", "--expect", #"{"file_written":"/tmp/output"}"#])
        }
    }
}
