//
//  WorkerEditTeamTests.swift
//  Braus
//

import Foundation
import SeatBroker
import Testing
@testable import Braus

/// WorkerEditTeamTests exercises worker edits through the team and its real store.
@MainActor
@Suite("Editing workers from the team", .serialized)
struct WorkerEditTeamTests {

    @Test("Edits refresh the team, keep blank names, and allow clearing role and shape")
    func editsRefreshTheTeam() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(
            name      : "Atlas",
            role      : "Engineer",
            appearance: TemporaryStore.appearance()
        )
        let team = makeTeam(store)
        await team.load()
        team.selection = worker.id

        await team.update(
            worker.id,
            .name("  Nova  ")
        )
        #expect(team.selectedWorker?.name == "Nova")
        await team.update(
            worker.id,
            .name(" \n\t ")
        )
        #expect(team.selectedWorker?.name == "Nova")
        await team.update(
            worker.id,
            .role("Reviewer")
        )
        #expect(team.selectedWorker?.role == "Reviewer")
        await team.update(
            worker.id,
            .shape("lens")
        )
        #expect(team.selectedWorker?.shape == .lens)
        await team.update(
            worker.id,
            .role(nil)
        )
        await team.update(
            worker.id,
            .shape(nil)
        )
        #expect(team.selectedWorker?.role == nil)
        #expect(team.selectedWorker?.shape == worker.shape)
        #expect(team.selectedWorker?.appearance == worker.appearance)
        #expect(team.problem == nil)

        let reopened = try WorkspaceStore.opening(in: directory)
        let saved = try #require(try await reopened.worker(worker.id))
        #expect(saved.name == "Nova")
        #expect(saved.role == nil)
        #expect(saved.shape == worker.shape)
    }

    @Test("Creating with a shape persists it and keeps the existing selection workflow")
    func creationKeepsShape() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let team = makeTeam(store)
        await team.createWorker(
            name        : "Atlas",
            role        : "Engineer",
            instructions: "Check releases",
            appearance  : TemporaryStore.appearance(),
            selection   : TemporaryStore.firstSelection,
            shape       : .hexagon
        )
        let worker = try #require(team.selectedWorker)
        #expect(worker.shape == .hexagon)
        #expect(worker.configuration == TemporaryStore.firstSelection)
        #expect(team.conversation?.participantIDs == [worker.id])
        #expect(team.problem == nil)
        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(worker.id)?.shape == .hexagon)
    }

    @Test("A missing worker reports the failed edit without changing the loaded team")
    func missingWorkerReportsFailure() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        )
        let team = makeTeam(store)
        await team.load()
        await team.update(
            UUID(),
            .shape("square")
        )
        #expect(team.problem != nil)
        #expect(team.worker(worker.id) == worker)
        #expect(try await store.workers() == [worker])
    }

    private func makeTeam(_ store: WorkspaceStore) -> TeamModel {
        TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
    }
}
