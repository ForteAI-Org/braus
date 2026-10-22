//
//  StoreShapeV6.swift
//  Braus
//

import Foundation
import SwiftData
@testable import Braus

/// StoreShapeV6 freezes the workspace before worker shapes. Only Worker changes;
/// the remaining entities use their unchanged production models.
enum StoreShapeV6: VersionedSchema {

    static var versionIdentifier: Schema.Version {
        Schema.Version(
            6,
            0,
            0
        )
    }

    static var models: [any PersistentModel.Type] {
        [
            Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }

    /// Worker preserves every column and index from the pre-shape model.
    @Model
    nonisolated final class Worker {

        #Unique<Worker>([\.id])
        #Index<Worker>([\.isArchived, \.name])

        /// Stable across renames, model changes and appearance regeneration.
        var id: UUID

        var name: String

        /// The short role the team list and the routing read. May be empty.
        var role: String?

        /// The longer description of responsibilities and preferences. May be
        /// empty: a worker without one is a generalist, and nothing infers a
        /// specialisation from its name.
        var instructions: String?

        /// Archiving is the ordinary removal from the active team. Deleting for
        /// good is a separate act, `WorkspaceStore.deleteWorker`.
        var isArchived: Bool

        var createdAt: Date

        /// The mascot descriptor. Only an explicit regenerate replaces it.
        var appearance: WorkerAppearance

        init(
            id          : UUID    = UUID(),
            name        : String,
            role        : String? = nil,
            instructions: String? = nil,
            isArchived  : Bool    = false,
            createdAt   : Date    = Date(),
            appearance  : WorkerAppearance
        ) {
            self.id           = id
            self.name         = name
            self.role         = role
            self.instructions = instructions
            self.isArchived   = isArchived
            self.createdAt    = createdAt
            self.appearance   = appearance
        }
    }
}
