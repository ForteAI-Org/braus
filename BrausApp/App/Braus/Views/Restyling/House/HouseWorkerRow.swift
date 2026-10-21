import SwiftUI

/// HouseWorkerRow presents a compact card with a lit worker, its name and its badge.
/// The worker stays visible during selection; the card and accessibility traits mark the choice.
struct HouseWorkerRow: View {
    let worker    : MockWorker
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HouseWorkerPortrait(
                shape : worker.shape,
                status: worker.status,
                seed  : WorkerBehaviour.seed(for: worker.id)
            )
            .accessibilityHidden(true)
            Text(worker.name)
                .font(.system(
                    size  : 13,
                    weight: .medium
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
            if !isSelected, let badge = worker.badge {
                HouseBadgeView(
                    badge : badge,
                    height: 17
                )
            }
        }
        .padding(
            .trailing,
            12
        )
        .frame(
            maxWidth : .infinity,
            maxHeight: .infinity
        )
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
