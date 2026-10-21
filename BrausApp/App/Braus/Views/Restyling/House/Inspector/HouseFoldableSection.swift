//
//  HouseFoldableSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseFoldableSection is an inspector section that folds under its title: the whole header row
/// is the button, with a chevron that turns a quarter turn (`HouseChevron`), and the rows fade and
/// fold away over the same time. Under Reduce Motion both change at once.
struct HouseFoldableSection<Content: View>: View {
    let title: String

    @Binding var isExpanded: Bool

    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            if isExpanded {
                content()
            }
        } header: {
            Header(
                title     : title,
                isExpanded: $isExpanded
            )
        }
    }

    /// Opens a closed section and folds an open one, animating the rows unless motion is reduced.
    static func fold(_ isExpanded: Binding<Bool>) {
        withAnimation(RestylingMotion.reducesMotion ? nil : .easeInOut(duration: HouseChevronView.duration)) {
            isExpanded.wrappedValue.toggle()
        }
    }

    /// Header is the section's title and chevron, one button across the full width.
    private struct Header: View {
        let title: String

        @Binding var isExpanded: Bool

        @State private var isHovering = false

        var body: some View {
            Button { fold($isExpanded) } label: {
                HStack {
                    // An explicit font keeps the title as it is when the section above is folded and
                    // the list would otherwise style it as a sub-header.
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
                .padding(.vertical, 3)
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
