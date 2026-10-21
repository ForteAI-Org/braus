//
//  InspectorDisclosure.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// InspectorDisclosure is what the house's inspector has folded and opened, per worker: the
/// sections folded under their titles, and the worker whose list of providers is open, as the
/// app's `TeamModel.choosingProviderFor`. Coming back to a worker finds its inspector as it was
/// left; every section starts open.
nonisolated struct InspectorDisclosure: Equatable {

    /// Section is one part of the inspector that folds under its title.
    enum Section: CaseIterable, Hashable {
        case now, screen, model, web, turn
    }

    /// The worker whose list of providers is open, nil while no list is.
    var choosingProviderFor: MockWorker.ID?

    private var folded: [MockWorker.ID: Set<Section>] = [:]

    func isExpanded(
        _ section : Section,
        for worker: MockWorker.ID
    ) -> Bool {
        folded[worker]?.contains(section) != true
    }

    mutating func setExpanded(
        _ isExpanded: Bool,
        _ section   : Section,
        for worker  : MockWorker.ID
    ) {
        if isExpanded {
            folded[worker]?.remove(section)
        } else {
            folded[worker, default: []].insert(section)
        }
    }
}
