//
//  BrainPalette.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import PerceptionCore
import Memory
import SwiftUI

/// BrainPalette is the colour each kind of node is drawn in, the same in the
/// graph and in the list: a window in the accent colour, and a group in the
/// colour of the controls it holds, so each group reads as one constellation.
enum BrainPalette {

    static func colour(of kind: BrainGraph.Kind) -> Color {
        switch kind {
        case .window, .scene: .accentColor
        case .container: .gray
        case .collection, .itemTemplate: .purple
        case .unknownState: .gray
        case .relation(let standing):
            switch standing {
            case .candidate: .orange
            case .exposed: .green
            case .limited: .red
            }
        case .group(let element), .control(let element): colour(of: element)
        }
    }

    static func colour(of kind: ElementKind) -> Color {
        switch kind {
        case .control         : .blue
        case .icon            : .purple
        case .text            : .gray
        case .image, .canvas  : .teal
        case .overlayCandidate: .pink
        }
    }
}
