//
//  BrainAppRow.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Memory
import SwiftUI

/// BrainAppRow is one application in the Brain's list: its icon and name,
/// without reading its contents. The navigation link
/// around it opens it and draws the chevron.
struct BrainAppRow: View {

    let app: BrainAppSummary

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                width : 28,
                height: 28
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                if let summary = app.observationSummary {
                    if summary.scenes == 0 && summary.relations == 0 {
                        Text(summary.hasHistoricalProjection
                             ? String(localized: "Historical naming projection")
                             : String(localized: "Encountered app; no saved observations yet"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Observed states") + ": \(summary.scenes) · "
                             + String(localized: "Observed relationships") + ": \(summary.relations)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(
            .vertical,
            4
        )
    }
}
