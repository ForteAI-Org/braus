//
//  HouseArchivePopover.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseArchivePopover is the house's archive, opened from its toolbar button (`HouseArchiveButton`):
/// the team's archived workers, each with its name and role, Restore to Team and Delete….
///
/// A click on a worker opens its conversation (`open`), as a click on an archived row of the team's
/// own sidebar does; its context menu holds the same commands (`WorkerCommands`). Delete… closes the
/// archive and asks first in the team window, and waits while the worker is answering.
struct HouseArchivePopover: View {
    let team: TeamModel
    let open: (UUID) -> Void

    @Environment(\.dismiss)
    private var dismiss

    /// The height of one worker's row, and the most rows the archive shows before it scrolls.
    private static let rowHeight: CGFloat = 40
    private static let rowsShown          = 8

    var body: some View {
        List(team.archived) { worker in
            row(worker)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(
            width : 280,
            height: Self.rowHeight * CGFloat(min(
                max(
                    team.archived.count,
                    1
                ),
                Self.rowsShown
            )) + 12
        )
        .accessibilityLabel("Archive")
    }

    private func row(_ worker: WorkerSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(
                alignment: .leading,
                spacing  : 1
            ) {
                Text(worker.name)
                    .lineLimit(1)
                if let role = Self.role(of: worker) {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            Button(
                "Restore to Team",
                systemImage: "arrow.uturn.backward"
            ) {
                Task {
                    await team.setArchived(
                        false,
                        for: worker.id
                    )
                }
            }
            .help("Restore to Team")
            Button(
                "Delete…",
                systemImage: "trash",
                role       : .destructive
            ) {
                dismiss()
                team.deletingWorker = worker.id
            }
            .help("Delete…")
            .disabled(team.isAnswering(worker.id))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(height: Self.rowHeight - 8)
        .contentShape(Rectangle())
        .onTapGesture { open(worker.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(worker.name), archived")
        .accessibilityAction(named: "Open") { open(worker.id) }
        .contextMenu {
            WorkerCommands(
                worker: worker,
                team  : team
            )
        }
    }

    /// `worker`'s role as the archive shows it, nil when it has none.
    private static func role(of worker: WorkerSnapshot) -> String? {
        let role = worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return role.isEmpty ? nil : role
    }
}
