//
//  NewWorkerModelTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports
import SeatBroker
import Testing
@testable import Braus

/// The provider and the model the New Worker sheet starts on, by the rule the
/// inspector's change of provider uses too.
@MainActor
@Suite("The new worker's preselected model")
struct NewWorkerPreselectionTests {

    @Test func theFirstReadyProviderInOrderIsPreselected() {
        let states: [ModelProvider: ConnectionState] = [
            .codex     : .credentialMissing,
            .anthropic : .ready,
            .claudeCode: .ready,
        ]
        #expect(ModelProvider.preselected(in: states) == .claudeCode)
    }

    @Test func noProviderIsPreselectedWhenNoneIsReady() {
        let states: [ModelProvider: ConnectionState] = [
            .codex : .credentialMissing,
            .ollama: .usageLimited(detail: "limit"),
        ]
        #expect(ModelProvider.preselected(in: states) == nil)
        #expect(ModelProvider.preselected(in: [:]) == nil)
    }

    @Test func aCommandLineStartsOnTheFirstModelItLists() {
        let catalogue = [
            ModelInfo(
                id     : "claude-sonnet-5-5",
                efforts: [.low]
            ),
            ModelInfo(
                id     : "claude-opus-5-5",
                efforts: [.low]
            ),
        ]
        #expect(ModelProvider.claudeCode.startingModel(in: catalogue)?.id == "claude-sonnet-5-5")
        #expect(ModelProvider.codex.startingModel(in: catalogue)?.id == "claude-sonnet-5-5")
    }

    @Test func anAPIProviderStartsOnItsDefaultModelWhenListed() {
        let catalogue = [
            ModelInfo(
                id     : "claude-haiku-4-5",
                efforts: []
            ),
            ModelInfo(
                id     : "claude-opus-5-5",
                efforts: [.low]
            ),
        ]
        #expect(ModelProvider.anthropic.startingModel(in: catalogue)?.id == "claude-opus-5-5")
    }

    @Test func theFirstModelIsPreselectedOtherwise() {
        let catalogue = [
            ModelInfo(
                id     : "qwen3:8b",
                efforts: []
            ),
            ModelInfo(
                id     : "llama4",
                efforts: []
            ),
        ]
        #expect(ModelProvider.ollama.startingModel(in: catalogue)?.id == "qwen3:8b")
        #expect(ModelProvider.anthropic.startingModel(in: catalogue)?.id == "qwen3:8b")
    }

    @Test func anEmptyCatalogueHasNoModel() {
        #expect(ModelProvider.codex.startingModel(in: []) == nil)
    }
}

/// A worker created with a model has it as its first configuration version,
/// and one created without stays to configure.
@MainActor
@Suite("Creating a worker with a model")
struct NewWorkerCreationTests {

    @Test func aWorkerCreatedWithASelectionIsConfiguredWithIt() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let team  = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.createWorker(
            name        : "Iris",
            role        : nil,
            instructions: nil,
            appearance  : TemporaryStore.appearance(),
            selection   : TemporaryStore.firstSelection
        )

        let worker = try #require(team.active.first)
        #expect(team.active.count == 1)
        #expect(worker.configuration == TemporaryStore.firstSelection)
        #expect(team.problem == nil)
        // The next version is the second, so the selection was the first.
        #expect(try await store.configure(
            worker   : worker.id,
            selection: TemporaryStore.secondSelection
        ) == 2)
    }

    @Test func aWorkerCreatedWithoutASelectionHasNoConfiguration() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.createWorker(
            name        : "Nova",
            role        : nil,
            instructions: nil,
            appearance  : TemporaryStore.appearance()
        )

        let worker = try #require(team.active.first)
        #expect(worker.configuration == nil)
        #expect(team.needsConfiguring(worker))
        #expect(team.problem == nil)
    }
}
