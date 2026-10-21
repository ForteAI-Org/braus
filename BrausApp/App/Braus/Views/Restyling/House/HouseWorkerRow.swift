import SwiftUI

/// HouseWorkerRow presents a compact card with a lit worker, its name and its badge.
/// Wide, the name and what the worker is doing sit beside the worker and the badge ends the card. Narrow (`isCompact`), the
/// worker is centred with its name alone under it, as in a compact room, and the badge marks the corner.
/// Both forms are the same views in a different layout, so a change between them moves and resizes
/// them. The worker stays visible when selected; the card and accessibility traits mark the choice.
struct HouseWorkerRow: View {
    let worker    : MockWorker
    let isSelected: Bool
    var isCompact : Bool = false

    /// The room a trailing badge takes beside a wide card's name.
    private static let badgeRoom: CGFloat = 30

    private var badge: MockBadge? { isSelected ? nil : worker.badge }

    var body: some View {
        let layout = isCompact
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            HouseWorkerPortrait(
                shape : worker.shape,
                status: worker.status,
                seed  : WorkerBehaviour.seed(for: worker.id)
            )
            .accessibilityHidden(true)
            VStack(
                alignment: isCompact ? .center : .leading,
                spacing  : 1
            ) {
                Text(worker.name)
                    .font(.system(
                        size  : isCompact ? 11 : 13,
                        weight: isCompact ? .regular : .medium
                    ))
                    .foregroundStyle(isCompact ? .secondary : .primary)
                    .lineLimit(1)
                if !isCompact {
                    Text(worker.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(
                .trailing,
                isCompact || badge == nil ? 0 : Self.badgeRoom
            )
            .frame(
                maxWidth : isCompact ? nil : .infinity,
                alignment: .leading
            )
        }
        .padding(
            .horizontal,
            isCompact ? 8 : 0
        )
        .padding(
            .bottom,
            isCompact ? 5 : 0
        )
        .frame(
            maxWidth : .infinity,
            maxHeight: .infinity
        )
        .overlay(alignment: isCompact ? .topTrailing : .trailing) {
            if let badge {
                HouseBadgeView(
                    badge : badge,
                    height: isCompact ? 15 : 17
                )
                .padding(isCompact ? 6 : 12)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(isSelected ? 0.08 : 0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            .white.opacity(isSelected ? 0.1 : 0.04),
                            lineWidth: 0.5
                        )
                }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HouseRoomCell.spokenRowLabel(
            for       : worker,
            isSelected: isSelected
        ))
        .accessibilityValue(isSelected ? "" : worker.badge.map(HouseBadgeView.spokenText(for:)) ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
