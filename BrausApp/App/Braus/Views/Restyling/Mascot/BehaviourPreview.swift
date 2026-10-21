//
//  BehaviourPreview.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// BehaviourPreview shows the four statuses' brow behaviour side by side on `MascotFace`, outside
/// rooms, so it can be judged. Debug builds open it instead of the window when launched with
/// `BRAUS_BEHAVIOUR_PREVIEW=1`; every mascot plays its own seed's loop.
struct BehaviourPreview: View {

    /// Whether this debug process was launched with `BRAUS_BEHAVIOUR_PREVIEW=1`.
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BRAUS_BEHAVIOUR_PREVIEW"] == "1"
        #else
        false
        #endif
    }

    private static let statuses: [(status: WorkerStatus, title: String)] = [
        (.busy, "Busy"),
        (.waiting, "Waiting"),
        (.free, "Free"),
        (.off, "Off"),
    ]

    var body: some View {
        HStack(spacing: 56) {
            ForEach(
                Self.statuses.indices,
                id: \.self
            ) { index in
                let entry = Self.statuses[index]
                VStack(spacing: 18) {
                    MascotFace(
                        shape        : .circle,
                        status       : entry.status,
                        brows        : BrowState(entry.status),
                        size         : 120,
                        behaviourSeed: UInt64(index + 1)
                    )
                    Text(entry.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(56)
        .background { Color("RestylingGround").ignoresSafeArea() }
        .preferredColorScheme(.dark)
    }
}
