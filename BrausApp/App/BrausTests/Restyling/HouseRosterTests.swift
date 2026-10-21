//
//  HouseRosterTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation
import ModelTransports
import SeatBroker
import Testing
@testable import Braus

@MainActor
@Suite("The house's workers read from the team")
struct HouseRosterTests {

    @Test("A room's light is the first state that applies to its worker")
    func statusRule() {
        func status(
            needsConfiguring  : Bool = false,
            provider          : ConnectionState? = nil,
            isAwaitingApproval: Bool = false,
            isAnswering       : Bool = false,
            unreadReplies     : Int = 0
        ) -> WorkerStatus {
            HouseRoster.status(
                needsConfiguring  : needsConfiguring,
                provider          : provider,
                isAwaitingApproval: isAwaitingApproval,
                isAnswering       : isAnswering,
                unreadReplies     : unreadReplies
            )
        }
        #expect(status() == .free)
        #expect(status(provider: .ready) == .free)
        #expect(status(needsConfiguring: true, isAwaitingApproval: true, isAnswering: true, unreadReplies: 2) == .off)
        for provider in [ConnectionState.credentialMissing, .notInstalled, .credentialRejected(detail: "401")] {
            #expect(status(provider: provider, isAnswering: true, unreadReplies: 1) == .off, "\(provider)")
        }
        #expect(status(isAwaitingApproval: true, isAnswering: true) == .waiting)
        #expect(status(isAnswering: true, unreadReplies: 3) == .busy)
        #expect(status(unreadReplies: 1) == .waiting)
        // A passing connection problem leaves the worker free; the inspector says what is wrong.
        for provider in [
            ConnectionState.unreachable(destination: "localhost", detail: ""),
            .usageLimited(detail: ""),
            .modelRemoved(model: "gone"),
            .refused(detail: ""),
        ] {
            #expect(status(provider: provider) == .free, "\(provider)")
        }
    }

    @Test("A worker's derived shape is the same every time and the shapes vary across workers")
    func shapeIsStable() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(HouseRoster.shape(for: id) == HouseRoster.shape(for: id))
        let shapes = Set((0..<64).map { _ in HouseRoster.shape(for: UUID()) })
        #expect(shapes.count > 1)
    }

    @Test("The team's active workers become rooms in order, with their light, activity, badge and screen")
    func workersFromTheTeam() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let ada   = try await store.createWorker(
            name      : "Ada",
            role      : "  Writes the copy ",
            appearance: TemporaryStore.appearance()
        )
        let bo    = try await store.createWorker(
            name      : "Bo",
            appearance: TemporaryStore.appearance()
        )
        let cy    = try await store.createWorker(
            name      : "Cy",
            appearance: TemporaryStore.appearance()
        )
        try await store.configure(
            worker   : ada.id,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5"
            )
        )
        try await store.update(
            worker: cy.id,
            .archived(true)
        )
        let team = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.load()

        let workers = HouseRoster.workers(of: team)
        #expect(workers.map(\.id) == [ada.id, bo.id])
        let first = try #require(workers.first)
        #expect(first.status == .free)
        #expect(first.role == "Writes the copy")
        #expect(first.subtitle == "Writes the copy")
        #expect(first.shape == HouseRoster.shape(for: ada.id))
        #expect(first.badge == nil && !first.usesScreen)
        #expect(workers.last?.status == .off)

        // The states the team derives at run time, given to the row's reading directly.
        let row = try #require(team.rows.first)
        let answering = HouseRoster.worker(
            row,
            provider   : .ready,
            isAnswering: true,
            usesScreen : true
        )
        #expect(answering.status == .busy && answering.usesScreen)
        #expect(answering.subtitle == "Working")
        let driving = HouseRoster.worker(
            TeamRow(
                worker            : row.worker,
                isModelUnavailable: false,
                activity          : "Using Pro Tools"
            ),
            provider   : nil,
            isAnswering: true,
            usesScreen : true
        )
        #expect(driving.subtitle == "Using Pro Tools")
        #expect(HouseRoster.worker(row, provider: .credentialMissing, isAnswering: true, usesScreen: false).status == .off)

        let replied = TeamRow(
            worker            : row.worker,
            isModelUnavailable: false,
            activity          : nil,
            unread            : UnreadState(
                replies         : 3,
                hasUnseenProblem: false
            )
        )
        let waiting = HouseRoster.worker(
            replied,
            provider   : .ready,
            isAnswering: false,
            usesScreen : false
        )
        #expect(waiting.status == .waiting && waiting.badge == .unread(3))
        #expect(HouseRoster.worker(replied, provider: nil, isAnswering: false, usesScreen: false, showsUnreadCount: false).badge == nil)
        #expect(HouseRoster.worker(replied, provider: nil, isAnswering: true, usesScreen: false).status == .busy)
        #expect(HouseRoster.worker(row, provider: nil, isAnswering: false, usesScreen: false, isAwaitingApproval: true).status == .waiting)

        let failed = TeamRow(
            worker            : row.worker,
            isModelUnavailable: false,
            activity          : nil,
            unread            : UnreadState(
                replies         : 2,
                hasUnseenProblem: true
            )
        )
        #expect(HouseRoster.worker(failed, provider: nil, isAnswering: false, usesScreen: false).badge == .attention)
        #expect(
            HouseRoster.worker(
                TeamRow(
                    worker            : row.worker,
                    isModelUnavailable: true,
                    activity          : nil
                ),
                provider   : .ready,
                isAnswering: false,
                usesScreen : false
            ).status == .off
        )
    }
}
