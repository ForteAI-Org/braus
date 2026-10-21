//
//  HouseFindCommands.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseFindCommands is the Edit menu's Find… (⌘F) for the house window, the mockup's or the new
/// look's: it moves the keyboard focus to the sidebar's search field. Otherwise the group stays
/// empty, so the team window's menus are unchanged.
struct HouseFindCommands: Commands {

    @FocusedValue(\.findInHouse)
    private var findInHouse

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            if RestylingMode.isRequested || AppPreferenceValues.shared.newLook {
                Button("Find…") { findInHouse?() }
                    .keyboardShortcut("f")
                    .disabled(findInHouse == nil)
            }
        }
    }
}

extension FocusedValues {

    /// Focuses the key house window's search field, published by `HouseSidebar`.
    @Entry var findInHouse: (() -> Void)?
}
