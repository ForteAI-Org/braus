//
//  HouseSidebarLiveTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

@Suite("The house's sidebar over the real team")
@MainActor
struct HouseSidebarLiveTests {

    @Test("A room shows the shape its worker stores, or the one derived from its id")
    func storedShape() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let lens  = try await store.createWorker(
            name      : "Lens",
            appearance: TemporaryStore.appearance(),
            shape     : WorkerShape.lens.rawValue
        )
        let plain = try await store.createWorker(
            name      : "Plain",
            appearance: TemporaryStore.appearance()
        )
        let team = Self.team(store)
        await team.load()

        let shapes = HouseRoster.workers(of: team).map(\.shape)
        #expect(shapes == [.lens, WorkerShape.derived(from: plain.id)])
        #expect(lens.shape == .lens)
    }

    @Test("The badges follow the team's unread replies")
    func badgesFollowTheTeam() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        )
        let direct = try await store.createConversation(
            kind        : .direct,
            participants: [worker.id]
        )
        let team = Self.team(store)
        await team.load()
        #expect(HouseRoster.workers(of: team).first?.badge == nil)

        try await store.appendMessage(
            to      : direct.id,
            author  : worker.id,
            text    : "done",
            delivery: .completed
        )
        await team.load()
        #expect(HouseRoster.workers(of: team).first?.badge == .unread(1))
        #expect(HouseRoster.workers(
            of              : team,
            showsUnreadCount: false
        ).first?.badge == nil)

        try await store.markRead(conversation: direct.id)
        await team.load()
        #expect(HouseRoster.workers(of: team).first?.badge == nil)
    }

    @Test("The unread badge counts to 99, then reads 99+")
    func badgeCap() {
        #expect(HouseBadgeView.countText(3) == "3")
        #expect(HouseBadgeView.countText(99) == "99")
        #expect(HouseBadgeView.countText(100) == "99+")
        #expect(HouseBadgeView.spokenText(for: .unread(120)) == "120 unread")
    }

    @Test("A real worker is read as its team row, with no badge value said twice")
    func spokenAsTheTeamRow() throws {
        var worker = try #require(MockHouse.sample.workers.first)
        worker.badge = .unread(2)
        #expect(HouseRoomCell.spokenValue(
            for       : worker,
            isSelected: false
        ) == "2 unread")

        worker.spokenLabel = "Delivery, Exports the stems, 2 unread replies"
        #expect(HouseRoomCell.spokenLabel(
            for       : worker,
            isSelected: false
        ) == "Delivery, Exports the stems, 2 unread replies")
        #expect(HouseRoomCell.spokenRowLabel(
            for       : worker,
            isSelected: true
        ) == "Delivery, Exports the stems, 2 unread replies, in chat with you")
        #expect(HouseRoomCell.spokenValue(
            for       : worker,
            isSelected: false
        ).isEmpty)
    }

    @Test("Off rooms read Needs Setup only while their worker has no model")
    func needsSetupSubtitle() throws {
        var worker = try #require(MockHouse.sample.workers.first { $0.status == .off })
        #expect(worker.subtitle == worker.role)
        worker.needsSetup = true
        #expect(worker.subtitle == TeamRow.toConfigure)
        worker.status = .free
        #expect(worker.subtitle == worker.role)
    }

    @Test("Arrow keys step through the rooms in order and by rows, and stop at the ends")
    func arrowKeys() {
        func next(
            _ index    : Int?,
            _ direction: MoveCommandDirection,
            count      : Int = 7,
            columns    : Int = 2
        ) -> Int? {
            HouseRoomsGrid.neighbour(
                of       : index,
                count    : count,
                columns  : columns,
                direction: direction
            )
        }
        #expect(next(nil, .down) == 0)
        #expect(next(nil, .up) == 6)
        #expect(next(nil, .down, count: 0) == nil)
        // The first room spans the row; the others sit two by two: 1 2, 3 4, 5 6.
        #expect(next(0, .down) == 1)
        #expect(next(1, .down) == 3)
        #expect(next(2, .down) == 4)
        #expect(next(5, .down) == 6)
        #expect(next(6, .down) == nil)
        #expect(next(4, .up) == 2)
        #expect(next(2, .up) == 0)
        #expect(next(0, .up) == nil)
        #expect(next(2, .right) == 3)
        #expect(next(6, .right) == nil)
        #expect(next(0, .left) == nil)
        // One column is a plain list.
        #expect(next(2, .down, columns: 1) == 3)
        #expect(next(2, .up, columns: 1) == 1)
    }

    @Test("A room's context menu holds the worker's commands beside Edit Worker…")
    func contextMenu() {
        #expect(String(reflecting: HouseWorkerMenu.Body.self).contains("WorkerCommands"))
    }

    @Test("A subtitle or badge change requests no room render")
    func subtitleAndBadgeDoNotRender() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        var worker = try #require(MockHouse.sample.workers.first { $0.status == .busy })

        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 200,
                height: 104
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Self.room(worker))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let opening = try #require(Self.opening(in: host))
        let renders = opening.room.requestedRenders

        worker.activity    = "Renders the credits"
        worker.role        = "Cuts trailers"
        worker.badge       = .unread(4)
        worker.spokenLabel = "Delivery, Renders the credits, 4 unread replies"
        host.rootView = Self.room(worker)
        host.layoutSubtreeIfNeeded()
        worker.badge = .attention
        host.rootView = Self.room(worker)
        host.layoutSubtreeIfNeeded()
        #expect(Self.opening(in: host) === opening)
        #expect(opening.room.requestedRenders == renders)

        // A change of light does render, so the count above is live.
        worker.status = .waiting
        host.rootView = Self.room(worker)
        host.layoutSubtreeIfNeeded()
        #expect(opening.room.requestedRenders == renders + 1)
    }

    private static func team(_ store: WorkspaceStore) -> TeamModel {
        TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
    }

    private static func room(_ worker: HouseWorker) -> HouseRoomCell {
        HouseRoomCell(
            worker    : worker,
            isSelected: false
        ) {}
    }

    private static func opening(in view: NSView) -> RoomOpeningView? {
        if let opening = view as? RoomOpeningView { return opening }
        return view.subviews.lazy.compactMap { opening(in: $0) }.first
    }
}
