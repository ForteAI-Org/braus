//
//  BehaviourPreview.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// BehaviourPreview shows the four statuses' brow behaviour side by side on the worker as it stands
/// outside rooms (`HouseWorkerPortrait`), so it can be judged. Debug builds open it instead of the
/// window when launched with `BRAUS_BEHAVIOUR_PREVIEW=1`; every worker plays its own seed's loop.
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
                    HouseWorkerPortrait(
                        shape     : .circle,
                        status    : entry.status,
                        size      : 120,
                        seed      : UInt64(index + 1),
                        usesScreen: entry.status == .busy
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
