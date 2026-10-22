//
//  TeamModel+Workers.swift
//  Braus
//

import Foundation
import ModelTransports

/// TeamModel persists worker details and refreshes the team after each edit.
extension TeamModel {

    /// TeamModel trims edited names; a blank name keeps the stored one.
    /// Store failures become a problem without discarding the loaded team.
    func update(
        _ id    : UUID,
        _ change: WorkerChange
    ) async {
        do {
            if case .name(let value) = change {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    try await store.update(
                        worker: id,
                        .name(name)
                    )
                }
            } else {
                try await store.update(
                    worker: id,
                    change
                )
            }
            await load()
        } catch {
            problem = issue(
                title  : "Couldn’t Update Worker",
                message: "The worker details weren’t saved. Try again.",
                error  : error
            )
        }
    }

    /// TeamModel creates a worker and, when `selection` is given, writes it as the
    /// worker's first configuration version. A worker whose model could not be
    /// written is still created, with no model. Creation is always the person's
    /// act: nothing else in the app calls this.
    func createWorker(
        name        : String,
        role        : String?,
        instructions: String?,
        appearance  : WorkerAppearance,
        selection   : ModelSelection? = nil,
        shape       : WorkerShape?    = nil
    ) async {
        do {
            let made = try await store.createWorker(
                name        : name,
                role        : role,
                instructions: instructions,
                appearance  : appearance,
                shape       : shape?.rawValue
            )
            if let selection {
                do {
                    try await store.configure(
                        worker   : made.id,
                        selection: selection
                    )
                } catch {
                    problem = issue(
                        title  : "Couldn’t Change Model",
                        message: "\(made.name) was created without a model.",
                        error  : error
                    )
                }
            }
            await load()
            self.selection = made.id
            await openSelectedConversation()
        } catch {
            problem = issue(
                title  : "Couldn’t Create Worker",
                message: "Review the worker details and try again.",
                error  : error
            )
        }
    }

}
