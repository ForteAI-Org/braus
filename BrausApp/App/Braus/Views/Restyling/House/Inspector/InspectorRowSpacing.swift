//
//  InspectorRowSpacing.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

extension View {

    /// Rows a little taller than the system's, for the mockup inspector's sections: the same
    /// padding on every row so none stands tighter than the others.
    func inspectorRow() -> some View {
        padding(
            .vertical,
            InspectorRowSpacing.vertical
        )
    }
}

enum InspectorRowSpacing {
    static let vertical: CGFloat = 3
}
