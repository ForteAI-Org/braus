//
//  HouseArchiveButton.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseArchiveButton is the archive in the sidebar's toolbar: a box that names how many workers
/// it holds in its help tag and to VoiceOver. `HouseSidebar` shows it only while the archive holds
/// a worker and nobody is searching. Over a real team it opens the archive (`HouseArchivePopover`),
/// where `open` opens an archived worker's conversation; the mockup, with no team, opens nothing.
struct HouseArchiveButton: View {
    let archivedCount: Int
    var team         : TeamModel?
    var open         : (UUID) -> Void = { _ in }

    @State private var isShowingArchive = false

    var body: some View {
        Button(
            "Archive",
            systemImage: "archivebox"
        ) {
            if team != nil { isShowingArchive.toggle() }
        }
        .help(Self.helpTag(archivedCount: archivedCount))
        .accessibilityLabel(Self.spokenLabel(archivedCount: archivedCount))
        .popover(
            isPresented: $isShowingArchive,
            arrowEdge  : .bottom
        ) {
            if let team {
                HouseArchivePopover(team: team) { worker in
                    isShowingArchive = false
                    open(worker)
                }
            }
        }
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
