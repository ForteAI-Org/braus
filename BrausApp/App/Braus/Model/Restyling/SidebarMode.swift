//
//  SidebarMode.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// SidebarMode is how the mockup's sidebar shows the workers: a floor plan of rooms, or rows.
nonisolated enum SidebarMode: String, CaseIterable, Sendable {
    case rooms, rows

    /// The mode a stored preference names; rooms when none is stored or the value names no mode.
    init(preference: String?) {
        self = preference.flatMap(SidebarMode.init(rawValue:)) ?? .rooms
    }
}
