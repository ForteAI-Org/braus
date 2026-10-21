//
//  HouseFoldableSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseFoldableSection is an inspector section that folds under its title: the whole header row
/// is the button, with a chevron that turns a quarter turn (`HouseChevron`), and the box of rows
/// below folds up into the title over the same time, its height and opacity going together while
/// the title stays put and the sections below follow its bottom edge. Under Reduce Motion it is
/// a cut.
///
/// The box is the grouped form's (`HouseInspectorRows`), drawn here and not by a `Form`: a form
/// inserts and removes its rows in a table, which snaps its boxes and restyles their titles midway.
/// Here one layout (`Fold`) shows a share of the rows' measured height, and SwiftUI animates that
/// share: Core Animation cannot move the sections below, which SwiftUI lays out. The rows leave
/// the hierarchy once the fold ends, so nothing in a folded section runs.
struct HouseFoldableSection<Content: View>: View {
    let title: String

    @Binding var isExpanded: Bool

    @ViewBuilder let content: () -> Content

    /// Whether a folded section's rows have left, which they do once the box has closed.
    @State private var isFoldedAway = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 0
        ) {
            Header(
                title     : title,
                isExpanded: isExpanded,
                toggle    : { Self.fold($isExpanded) }
            )
            Fold(openness: isExpanded ? 1 : 0) {
                HouseInspectorRows {
                    if isExpanded || !isFoldedAway {
                        content()
                    }
                }
            }
            .background(HouseInspectorMetrics.box.fill(HouseInspectorMetrics.boxFill))
            .clipShape(HouseInspectorMetrics.box)
            .opacity(isExpanded ? 1 : 0)
            .padding(
                .top,
                isExpanded ? HouseInspectorMetrics.headerGap : 0
            )
        }
        .task(id: isExpanded) {
            guard !isExpanded else {
                isFoldedAway = false
                return
            }

            let delay = Self.animation == nil ? 0 : HouseChevronView.duration
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { isFoldedAway = true }
        }
    }

    /// The animation of a fold, or nil for the cut Reduce Motion asks for.
    static var animation: Animation? {
        RestylingMotion.reducesMotion ? nil : .easeInOut(duration: HouseChevronView.duration)
    }

    /// Opens a closed section and folds an open one, animating unless motion is reduced.
    static func fold(_ isExpanded: Binding<Bool>) {
        withAnimation(animation) {
            isExpanded.wrappedValue.toggle()
        }
    }

    /// Fold shows the top `openness` share of its content's height, 0 for none and 1 for all of
    /// it, and animates between them as one value, so the height moves without overshoot.
    struct Fold: Layout {
        var openness: CGFloat

        var animatableData: CGFloat {
            get { openness }
            set { openness = newValue }
        }

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache   : inout ()
        ) -> CGSize {
            let full = Self.fullSize(
                of   : subviews,
                width: proposal.width
            )
            return CGSize(
                width : proposal.width ?? full.width,
                height: full.height * min(max(openness, 0), 1)
            )
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal : ProposedViewSize,
            subviews : Subviews,
            cache    : inout ()
        ) {
            let full = Self.fullSize(
                of   : subviews,
                width: bounds.width
            )
            for subview in subviews {
                subview.place(
                    at      : bounds.origin,
                    anchor  : .topLeading,
                    proposal: ProposedViewSize(
                        width : bounds.width,
                        height: full.height
                    )
                )
            }
        }

        private static func fullSize(
            of subviews: Subviews,
            width      : CGFloat?
        ) -> CGSize {
            subviews.reduce(CGSize.zero) { size, subview in
                let fit = subview.sizeThatFits(ProposedViewSize(
                    width : width,
                    height: nil
                ))
                return CGSize(
                    width : max(size.width, fit.width),
                    height: max(size.height, fit.height)
                )
            }
        }
    }

    /// Header is the section's title and chevron, one button across the full width.
    private struct Header: View {
        let title     : String
        let isExpanded: Bool
        let toggle    : () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: toggle) {
                HStack {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    HouseChevron(
                        isOpen      : isExpanded,
                        isEmphasized: isHovering
                    )
                    .frame(
                        width : 12,
                        height: 12
                    )
                }
                .padding(
                    .horizontal,
                    HouseInspectorMetrics.rowInset
                )
                .frame(height: HouseInspectorMetrics.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointerStyle(.link)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the section")
        }
    }
}
