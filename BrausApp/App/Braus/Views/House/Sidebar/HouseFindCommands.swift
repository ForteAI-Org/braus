//
//  HouseFindCommands.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseFindCommands is the Edit menu's Find… (⌘F) for the house window: it moves the keyboard focus
/// to the sidebar's search field.
struct HouseFindCommands: Commands {

    @FocusedValue(\.findInHouse)
    private var findInHouse

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { findInHouse?() }
                .keyboardShortcut("f")
                .disabled(findInHouse == nil)
        }
    }
}

struct FindInHouseAction: Equatable {
    let action: () -> Void

    func callAsFunction() {
        action()
    }

    // Evita il warning di @Entry dicendo a SwiftUI che l'azione in sé non cambia
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension FocusedValues {
    @Entry var findInHouse: FindInHouseAction?
}
