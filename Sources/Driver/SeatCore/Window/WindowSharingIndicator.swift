//
//  WindowSharingIndicator.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

/// WindowSharingIndicator recognises the window macOS adds to an application's own
/// accessibility tree while one of its windows is captured, as the seat's capture stream
/// does: an `AXWindow` with subrole `AXDialog`, `AXModal` false, titled "Window", 66 by 20
/// points at the captured window's top-left corner, whose one child is an `AXButton` titled
/// `WindowSharingSessionButton`. Measured on macOS 27.0.1 on 03/11/2026.
///
/// It is no dialog, blocks nothing and is no target. The subrole, the modality and the one
/// button decide; a title, a size or an identifier is never evidence alone, because a dialog
/// a person answers can share any of them.
nonisolated package enum WindowSharingIndicator {

    /// The title of the indicator's one child.
    package static let buttonTitle = "WindowSharingSessionButton"

    /// Whether a window with these facts is the indicator.
    ///
    /// `children` is asked only once the subrole and the modality already match, so a caller
    /// that has not read them may read them there, for that window alone. A window whose
    /// `AXModal` reads true never matches; one whose `AXModal` was not read is decided by its
    /// one button, which no dialog of an application carries.
    package static func matches(
        subrole : String?,
        isModal : Bool?,
        children: () -> [(role: String?, title: String?)]
    ) -> Bool {
        guard subrole == "AXDialog", isModal != true else { return false }
        let read = children()
        return read.count == 1 && read[0].role == "AXButton" && read[0].title == buttonTitle
    }
}
