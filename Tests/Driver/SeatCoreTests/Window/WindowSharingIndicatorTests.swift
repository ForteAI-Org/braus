//
//  WindowSharingIndicatorTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

@testable import SeatCore
import Testing

/// The window macOS adds to a captured application, as measured on 03/11/2026, against a
/// dialog that looks like it in every other way.
@Suite("The system's window sharing indicator")
struct WindowSharingIndicatorTests {

    static let indicatorButton: [(role: String?, title: String?)] = [("AXButton", "WindowSharingSessionButton")]

    @Test("a non-modal dialog whose one child is the sharing button is the indicator, unread modality included")
    func theIndicatorMatches() {
        #expect(WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false) { Self.indicatorButton })
        #expect(WindowSharingIndicator.matches(subrole: "AXDialog", isModal: nil) { Self.indicatorButton })
    }

    @Test("a modal dialog, another subrole, another button or a second child is no indicator")
    func aDialogIsNot() {
        #expect(!WindowSharingIndicator.matches(subrole: "AXDialog", isModal: true) { Self.indicatorButton })
        #expect(!WindowSharingIndicator.matches(subrole: "AXSystemDialog", isModal: false) { Self.indicatorButton })
        #expect(!WindowSharingIndicator.matches(subrole: "AXStandardWindow", isModal: false) { Self.indicatorButton })
        #expect(!WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false) { [("AXButton", "OK")] })
        #expect(!WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false) { [] })
        #expect(!WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false) {
            Self.indicatorButton + [("AXButton", "Cancel")]
        })
        #expect(!WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false) {
            [("AXStaticText", "WindowSharingSessionButton")]
        })
    }

    @Test("the children are read only once the subrole and the modality match")
    func childrenAreReadOnlyForACandidate() {
        var reads = 0
        let count: () -> [(role: String?, title: String?)] = { reads += 1; return Self.indicatorButton }
        _ = WindowSharingIndicator.matches(subrole: "AXStandardWindow", isModal: false, children: count)
        _ = WindowSharingIndicator.matches(subrole: "AXDialog", isModal: true, children: count)
        #expect(reads == 0)
        _ = WindowSharingIndicator.matches(subrole: "AXDialog", isModal: false, children: count)
        #expect(reads == 1)
    }
}
