//
//  HouseNewWorkerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseNewWorker")
@MainActor
struct HouseNewWorkerTests {

    @Test("Creating adds a free worker with the chosen name, role and shape after the others")
    func creatingAddsTheWorker() throws {
        var house = MockHouse.sample
        let id    = house.add(
            name : "Captions",
            role : "Writes subtitles",
            shape: .lens
        )
        #expect(house.workers.count == MockHouse.sample.workers.count + 1)
        let worker = try #require(house.workers.last)
        #expect(worker.id == id)
        #expect(worker.name == "Captions")
        #expect(worker.role == "Writes subtitles")
        #expect(worker.shape == .lens)
        #expect(worker.status == .free)
        #expect(worker.subtitle == "Writes subtitles")
        #expect(worker.badge == nil)
        #expect(Set(house.workers.map(\.id)).count == house.workers.count)
    }

    @Test("The starting shape is one no worker has, else one of the least used, chosen by the seed")
    func startingShapeAvoidsUsedOnes() {
        var house = MockHouse.sample
        house.workers.removeAll { $0.shape == .hexagon }
        for seed in UInt64(0)..<16 {
            #expect(house.suggestedShape(seed: seed) == .hexagon)
        }

        // Every shape is used in the sample house, the triangle twice.
        let sample = (UInt64(0)..<64).map { MockHouse.sample.suggestedShape(seed: $0) }
        #expect(!sample.contains(.triangle))
        #expect(Set(sample) == Set(WorkerShape.allCases).subtracting([.triangle]))

        let empty = MockHouse(
            workers      : [],
            archivedCount: 0,
            mostUsed     : []
        )
        #expect(empty.suggestedShape(seed: 3) == WorkerShape.allCases[3])
    }

    @Test("The shape grid offers eight named shapes, and the arrows move across and down it")
    func shapeGrid() {
        #expect(WorkerShape.allCases.map(\.name) == [
            "Circle", "Square", "Triangle", "Diamond", "Pentagon", "Hexagon", "Capsule", "Lens",
        ])
        #expect(HouseShapeGrid.columns == 4)
        #expect(HouseShapeGrid.shape(
            from  : .circle,
            moving: .rightArrow
        ) == .square)
        #expect(HouseShapeGrid.shape(
            from  : .square,
            moving: .downArrow
        ) == .hexagon)
        #expect(HouseShapeGrid.shape(
            from  : .hexagon,
            moving: .upArrow
        ) == .square)
        #expect(HouseShapeGrid.shape(
            from  : .pentagon,
            moving: .leftArrow
        ) == .diamond)
        // One past an edge stays put.
        #expect(HouseShapeGrid.shape(
            from  : .circle,
            moving: .leftArrow
        ) == .circle)
        #expect(HouseShapeGrid.shape(
            from  : .triangle,
            moving: .upArrow
        ) == .triangle)
        #expect(HouseShapeGrid.shape(
            from  : .lens,
            moving: .downArrow
        ) == .lens)
    }

    @Test("Editing a worker's shape gives its room new uniforms, which ask the room for a render")
    func editingTheShapeRerendersTheRoom() async throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        var house  = MockHouse.sample
        let index  = 2
        let before = house.workers[index]
        #expect(before.shape != .lens)

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
        let host = NSHostingView(rootView: Self.room(before))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let opening = try #require(Self.opening(in: host))
        #expect(opening.uniforms.shape == before.shape)
        let renders = opening.room.requestedRenders

        house.workers[index].shape = .lens
        host.rootView = Self.room(house.workers[index])
        host.layoutSubtreeIfNeeded()
        #expect(Self.opening(in: host) === opening)
        #expect(opening.uniforms.shape == .lens)
        #expect(opening.room.uniforms.shape == .lens)
        #expect(opening.room.requestedRenders == renders + 1)
    }

    private static func room(_ worker: MockWorker) -> HouseRoomCell {
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
