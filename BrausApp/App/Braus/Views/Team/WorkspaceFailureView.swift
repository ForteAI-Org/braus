//
//  WorkspaceFailureView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import SwiftUI

/// WorkspaceFailureView is what the team window says when the store did not open, on the house's
/// own dark ground (`HouseGround`) rather than the system's grey, up under the transparent
/// title bar as the house's split has it.
struct WorkspaceFailureView: View {

    /// Why the workspace could not be opened.
    let failure: String

    var body: some View {
        ContentUnavailableView {
            Label(
                "Couldn’t Open the Workspace",
                systemImage: "externaldrive.badge.xmark"
            )
        } description: {
            Text("Braus couldn’t load your team or conversations.\n\nDetails: \(failure)")
        }
        .frame(
            maxWidth : .infinity,
            maxHeight: .infinity
        )
        .background { Color("HouseGround").ignoresSafeArea() }
        .background(TransparentTitleBar())
        .preferredColorScheme(.dark)
    }
}
