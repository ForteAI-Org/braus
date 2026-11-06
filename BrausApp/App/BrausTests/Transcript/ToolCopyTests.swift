//
//  ToolCopyTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation
import Testing
@testable import Braus

/// Copying a whole tool line: a release build gives the words the line shows,
/// a Debug build the records, compact enough to paste into a report.
@Suite("Tool copy: readable activity and complete text diagnostics")
struct ToolCopyTests {

    /// A scene as a JSON string, as the host renders it: a header line, then 35 elements.
    static let scene = #""app: Calcolatrice (com.apple.calculator): \"Calcolatrice\"\nviewport: 230x408\n"#
        + #"elements (35):\n"# + (1...35).map { #"  button \#($0)\n"# }.joined() + #"""#

    /// The scene a debug copy gives in its place.
    static let shortScene = #""app: Calcolatrice (com.apple.calculator): \"Calcolatrice\" · 35 elements""#

    /// The session the host names, as it records it.
    static let session = #""515D9A2C-7E41-4B0F-9C3D-2F6A8B1E4D70""#

    /// What a batch step's result carries as its observation.
    static func observation(revision: Int) -> String {
        #"{"session":"# + session + #","scene":"# + scene + #","revision":\#(revision),"#
            + #""observedAt":"2026-10-01T08:53:3\#(revision)Z"}"#
    }

    /// The Calculator turn as the host recorded it, keys in its order: a look
    /// around, the app opened, a three-step batch stopped at step 2.
    static let calculator: [String] = [
        #"→ status {}"#,
        #"← status {"session":null,"permissions":{"screenRecording":true,"accessibility":true,"postEvent":true}}"#,
        #"→ windows {"app":"Calcolatrice"}"#,
        #"← windows {"applications":[{"pid":13776,"windows":[{"id":27741,"title":"Calcolatrice"}],"#
            + #""name":"Calcolatrice","bundleID":"com.apple.calculator"}]}"#,
        #"→ open_session {"app":"com.apple.calculator","window":"Calcolatrice"}"#,
        #"← open_session {"observedAt":"2026-10-01T08:53:31Z","session":"# + session + #",""#
            + #"revision":7,"scene":"# + scene + "}",
        #"→ batch {"session":"# + session + #","steps":["#
            + #"{"target":"7","verb":"click","operation":"act"},"#
            + #"{"target":"Nonexistent","verb":"click","operation":"act"},"#
            + #"{"target":"8","verb":"click","operation":"act"}]}"#,
        #"← batch step 1 {"status":"found_acted","observation":"# + observation(revision: 8)
            + #","message":"clicked '7': reveals elements","session":"# + session + "}",
        #"← batch step 2 {"message":"no element 'Nonexistent' in Calcolatrice","observation":"#
            + observation(revision: 9) + #","session":"# + session + #","status":"honest_miss"}"#,
        #"← batch {"requested":3,"attemptedSteps":2,"steps":["#
            + #"{"status":"found_acted","observation":"# + observation(revision: 8) + "},"
            + #"{"status":"honest_miss","observation":"# + observation(revision: 9) + "}],"
            + #""verifiedSteps":1,"status":"stopped"}"#,
    ]

    private static func copy(_ lines: [String], isExpanded: Bool = true, detailed: Bool) -> String {
        ToolStep.copyText(
            of        : lines,
            isExpanded: isExpanded,
            ending    : .completed,
            detailed  : detailed
        )
    }

    @Test("A collapsed line copies its summary alone, an opened one the summary then its steps")
    func releaseCopy() {
        #expect(Self.copy(Self.calculator, isExpanded: false, detailed: false)
            == "Opened com.apple.calculator (Calcolatrice) · pressed 7")
        #expect(Self.copy(Self.calculator, detailed: false) == """
            Opened com.apple.calculator (Calcolatrice) · pressed 7
            Checked open apps
            Checked Calcolatrice’s open windows
            Opened com.apple.calculator (Calcolatrice)
            Pressed 7
            Could not press Nonexistent: no element 'Nonexistent' in Calcolatrice
            """)
    }

    @Test("A diagnostic copy preserves the saved evidence, including long scenes and protected omissions")
    func completeDiagnosticCopy() {
        let long = #"← act {"gesture":"uncertain","effect":"confirmed","message":""#
            + String(repeating: "a", count: 400)
            + #"","observation":{"scene":"First line\nLast line"},"text":"[withheld]"}"#
        #expect(Self.copy(Self.calculator + [long], isExpanded: false, detailed: true)
            == (Self.calculator + [long]).joined(separator: "\n"))
        #expect(Self.copy([long], detailed: true).contains("[withheld]"))
        #expect(Self.copy([long], detailed: true).contains("Last line"))
    }

    @Test func diagnosticCopyDoesNotIncludeEncodedPictures() {
        let line = ToolPictures.mark + #"canvas {"data":"encoded-private-pixels"}"#
        let copied = Self.copy([line], detailed: true)
        #expect(!copied.contains("encoded-private-pixels"))
        #expect(copied.contains("image data omitted"))
    }
}
