//
//  CGRect+Carried.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import CoreGraphics

extension CGRect {

    /// Where this window frame goes once the pointer that took it at `grab` has gone to `pointer`, all
    /// in AppKit's screen space: carried by the pointer at its size, its top kept at or under `top`, as
    /// the window server keeps a dragged window under the menu bar.
    func carried(
        from grab : CGPoint,
        to pointer: CGPoint,
        under top : CGFloat = .infinity
    ) -> CGRect {
        let moved = offsetBy(
            dx: pointer.x - grab.x,
            dy: pointer.y - grab.y
        )
        return moved.offsetBy(
            dx: 0,
            dy: min(0, top - moved.maxY)
        )
    }
}
