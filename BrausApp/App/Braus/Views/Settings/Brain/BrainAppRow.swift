//
//  BrainAppRow.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

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

            Text(app.name)

            Spacer()
        }
        .padding(
            .vertical,
            4
        )
    }
}
