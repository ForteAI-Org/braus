//
//  HouseChevron.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseChevron shows `HouseChevronView` in SwiftUI: the layer turns in Core Animation when
/// `isOpen` changes, unless the person asked for Reduce Motion.
struct HouseChevron: NSViewRepresentable {
    let isOpen      : Bool
    let isEmphasized: Bool

    func makeNSView(context: Context) -> HouseChevronView {
        let view = HouseChevronView()
        view.setOpen(
            isOpen,
            animated: false
        )
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(
        _ view : HouseChevronView,
        context: Context
    ) {
        view.setOpen(
            isOpen,
            animated: !RestylingMotion.reducesMotion
        )
        view.isEmphasized = isEmphasized
    }
}
