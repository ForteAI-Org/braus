//
//  ModelProvider+Preselection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports

extension ModelProvider {

    /// The provider a new worker starts on: the first, in `allCases` order,
    /// whose last check found it ready, and nil when none did.
    static func preselected(in states: [ModelProvider: ConnectionState]) -> ModelProvider? {
        allCases.first { states[$0]?.isReady == true }
    }

    /// The model a worker moved to this provider comes with, nil for an empty
    /// catalogue. The command lines list their own default first (Claude
    /// Code's default row, Codex's priority), so the first listed is theirs;
    /// the other providers start on the first of `defaultModels` they list.
    func startingModel(in catalogue: [ModelInfo]) -> ModelInfo? {
        switch self {
        case .claudeCode, .codex:
            return catalogue.first
        case .anthropic, .gemini, .ollama:
            let ids       = catalogue.map(\.id)
            let preferred = defaultModels.first(where: ids.contains)
            return catalogue.first { $0.id == preferred } ?? catalogue.first
        }
    }
}
