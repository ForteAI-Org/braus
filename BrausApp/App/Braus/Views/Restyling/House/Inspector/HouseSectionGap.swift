//
//  HouseSectionGap.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseSectionGap is the footer of an inspector section that has no footer text: it holds the
/// section's end a little further from the next header, which a grouped form on macOS has no setting for.
struct HouseSectionGap: View {
    var body: some View {
        Color.clear
            .frame(height: 12)
            .accessibilityHidden(true)
    }
}
