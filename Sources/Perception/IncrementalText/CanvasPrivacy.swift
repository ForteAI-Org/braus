//
//  CanvasPrivacy.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import PerceptionCore

/// CanvasPrivacy decides which parts of a canvas crop may leave, from the scene its pixels were read
/// with. It is the rule that later allows canvas pixels to be sent at all.
///
/// Only canvas pixels are ever cropped (`CanvasCrop` clips to the canvas); this adds the elements over
/// them. A crop that touches a secure field is refused, so no pixel of it leaves. Inside an accepted
/// crop, an editable field and an element whose label or value is withheld are blanked. `isWithheld`
/// is the caller's policy and should be the one the human intervention report withholds a person's
/// values with (a label naming a secret, or credential-shaped text): a field it withholds is
/// protected there exactly as a secure field is, so here it refuses the crop too.
///
/// A secure field AppKit reports as a text field with a secure subrole reaches the scene with its role
/// only, so it is blanked as an editable field unless its label is withheld.
public enum CanvasPrivacy {

    /// The role of a field whose value is never read.
    public static let secureRole = "AXSecureTextField"
    /// Roles whose value a person types, blanked wherever a crop meets them.
    public static let editableRoles = AccessibilityAugmentation.textEntryRoles.union(["AXSearchField", secureRole])

    /// The window-point rectangles of `scene` to blank in a crop of `rect`, or nil when the crop must
    /// be refused. `windowSize` is the window's size in points, which the scene's bounds scale by.
    public static func blanking(
        _ rect    : CGRect,
        in scene  : SceneSnapshot,
        windowSize: CGSize,
        isWithheld: (String) -> Bool
    ) -> [CGRect]? {
        var blanks: [CGRect] = []
        for element in scene.elements where element.kind != .canvas {
            let frame = element.bounds.pixelBox(in: windowSize)
            guard frame.intersects(rect) else { continue }
            let role       = element.role ?? ""
            let isEditable = editableRoles.contains(role)
            let withheld   = [element.label, element.value ?? ""].contains { !$0.isEmpty && isWithheld($0) }
            if role == secureRole || isEditable && withheld { return nil }
            if isEditable || withheld { blanks.append(frame) }
        }
        return blanks
    }
}
