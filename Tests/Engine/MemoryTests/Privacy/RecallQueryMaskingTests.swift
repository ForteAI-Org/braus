import Memory
import Testing

@Suite("Recall query text kept without task values")
struct RecallQueryMaskingTests {
    private func value(_ name: String, _ text: String) throws -> TaskValue {
        try TaskValue(name: name, kind: .text, content: .text(text), source: .request)
    }

    @Test func replacesFileAndEmbeddedOccurrences() throws {
        let values = try [value("file", "invoice-2026.pdf"), value("person", "ann")]
        #expect(RecallQueryMasking.masked("rename old-invoice-2026.pdf to {new name}; banner", values: values)
                == "rename old-{file} to {new name}; b{person}er")
    }

    @Test func longestMatchAndNameOrderWin() throws {
        let values = try [value("short", "doc"), value("z", "doc.pdf"), value("a", "doc.pdf")]
        #expect(RecallQueryMasking.masked("/doc.pdf/doc", values: values) == "/{a}/{short}")
        #expect(RecallQueryMasking.masked("doc.pdf", values: Array(values.reversed())) == "{a}")
    }

    @Test func insertedNamesAreNotScannedAgain() throws {
        let values = try [value("ann", "doc.pdf"), value("person", "ann")]
        #expect(RecallQueryMasking.masked("doc.pdf ann", values: values) == "{ann} {person}")
    }

    @Test func withheldSecretAndAbsentValuesAreIgnored() throws {
        let values = try [
            value("file", "doc.pdf"),
            TaskValue(name: "password", kind: .text, content: .withheld, sensitivity: .secret, source: .request),
            TaskValue(name: "pending", kind: .missing, content: .missing, source: .request)
        ]
        #expect(RecallQueryMasking.masked("open doc.pdf using password", values: values)
                == "open {file} using password")
    }

    @Test func emptyValuesAndDistinctUnicodeSpellings() throws {
        let values = try [value("empty", ""), value("accent", "é")]
        #expect(RecallQueryMasking.masked("e\u{301} é", values: values) == "e\u{301} {accent}")
    }

    @Test func undeclaredCredentialIsWithheld() {
        #expect(RecallQueryMasking.masked("use sk-fake00000000000000000000", values: []) == "use [withheld]")
    }

    @Test func unchangedTextAndCaseSensitivity() throws {
        #expect(RecallQueryMasking.masked("Open DOC.PDF", values: [try value("file", "doc.pdf")]) == "Open DOC.PDF")
        #expect(RecallQueryMasking.masked("plain request", values: []) == "plain request")
    }

    @Test func literalUnicodeAndAdjacentMatches() throws {
        #expect(RecallQueryMasking.masked("éé/[a].pdf", values: [try value("letter", "é"), try value("file", "[a].pdf")])
                == "{letter}{letter}/{file}")
    }
}
