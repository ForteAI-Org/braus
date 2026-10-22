//
//  HouseShapeGrid.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseShapeGrid lets the person choose a worker's shape: the eight shapes as live workers standing
/// in three quarters as their rooms show them (`HouseWorkerPortrait`), four across, the chosen one
/// ringed as a selected room is.
///
/// Each shape is a button named after it, selected while chosen. The grid takes the keyboard as one
/// control, and the arrow keys move the choice across and down it. A shape just chosen raises its
/// brows for a moment, a Core Animation morph; under Reduce Motion it does not.
struct HouseShapeGrid: View {
    @Binding var selection: WorkerShape

    /// The shape whose brows are raised, nil once they have settled.
    @State private var reacting: WorkerShape?

    static let columns = 4

    /// The side of a mascot's sphere, in points.
    static let mascotSize: CGFloat = 48

    /// Room for the widest body, the lens, and the tallest, the triangle, at `mascotSize`.
    static let cell = CGSize(
        width : 76,
        height: 70
    )

    /// How long a chosen shape keeps its brows raised.
    private static let reaction = Duration.milliseconds(700)

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .fixed(Self.cell.width),
                    spacing: 6
                ),
                count    : Self.columns
            ),
            spacing: 6
        ) {
            ForEach(
                WorkerShape.allCases,
                id: \.self
            ) { shape in
                option(shape)
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            choose(Self.shape(
                from  : selection,
                moving: press.key
            ))
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shape")
        .task(id: reacting) {
            guard reacting != nil else { return }
            try? await Task.sleep(for: Self.reaction)
            // A newer choice cancelled this wait and holds its own brows.
            if !Task.isCancelled { reacting = nil }
        }
    }

    /// The shape `key` moves to from `shape`, in reading order four across; one past the grid's edge
    /// stays where it is.
    static func shape(
        from shape: WorkerShape,
        moving key: KeyEquivalent
    ) -> WorkerShape {
        let shapes = WorkerShape.allCases
        let index  = shapes.firstIndex(of: shape) ?? 0
        let step   = switch key {
        case .leftArrow : -1
        case .rightArrow: 1
        case .upArrow   : -columns
        case .downArrow : columns
        default         : 0
        }
        return shapes.indices.contains(index + step) ? shapes[index + step] : shape
    }

    private func option(_ shape: WorkerShape) -> some View {
        let isSelected = shape == selection
        return Button { choose(shape) } label: {
            HouseWorkerPortrait(
                shape : shape,
                status: .free,
                size  : Self.mascotSize,
                brows : reacting == shape ? .listening : .idle
            )
            .frame(
                width : Self.cell.width,
                height: Self.cell.height
            )
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: 12,
                        style       : .continuous
                    )
                    .fill(.white.opacity(0.06))
                    .strokeBorder(
                        .white.opacity(0.55),
                        lineWidth: 1.5
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shape.name)
        .accessibilityLabel(shape.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ shape: WorkerShape) {
        guard shape != selection else { return }

        selection = shape
        if !HouseMotion.reducesMotion { reacting = shape }
    }
}
