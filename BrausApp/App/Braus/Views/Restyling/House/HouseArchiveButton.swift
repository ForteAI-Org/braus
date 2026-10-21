//
//  HouseArchiveButton.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseArchiveButton is the archive in the sidebar's toolbar: a box that names how many workers
/// it holds in its help tag and to VoiceOver. `HouseSidebar` shows it only while the archive holds
/// a worker and nobody is searching. The mockup opens no archive.
struct HouseArchiveButton: View {
    let archivedCount: Int

    var body: some View {
        Button(
            "Archive",
            systemImage: "archivebox"
        ) {}
        .help(Self.helpTag(archivedCount: archivedCount))
        .accessibilityLabel(Self.spokenLabel(archivedCount: archivedCount))
    }

    /// The help tag for the archive holding `archivedCount` workers.
    static func helpTag(archivedCount: Int) -> String {
        "Archive · \(archivedCount)"
    }

    /// What VoiceOver says for the archive holding `archivedCount` workers.
    static func spokenLabel(archivedCount: Int) -> String {
        "Archive, \(archivedCount) workers"
    }
}
