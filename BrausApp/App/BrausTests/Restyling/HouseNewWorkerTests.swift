//
//  HouseNewWorkerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import ModelTransports
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseNewWorker")
@MainActor
struct HouseNewWorkerTests {

    @Test("The starting shape is one no worker has, else one of the least used, chosen by the seed")
    func startingShapeAvoidsUsedOnes() {
        let shapes = HouseFixture.workers.map(\.shape)
        for seed in UInt64(0)..<16 {
            #expect(WorkerShape.suggested(
                avoiding: shapes.filter { $0 != .hexagon },
                seed    : seed
            ) == .hexagon)
        }

        // Every shape is used in the fixture's house, the triangle twice.
        let sample = (UInt64(0)..<64).map { WorkerShape.suggested(avoiding: shapes, seed: $0) }
        #expect(!sample.contains(.triangle))
        #expect(Set(sample) == Set(WorkerShape.allCases).subtracting([.triangle]))

        #expect(WorkerShape.suggested(avoiding: [], seed: 3) == WorkerShape.allCases[3])
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
        var workers = HouseFixture.workers
        let index   = 2
        let before  = workers[index]
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

        workers[index].shape = .lens
        host.rootView = Self.room(workers[index])
        host.layoutSubtreeIfNeeded()
        #expect(Self.opening(in: host) === opening)
        #expect(opening.uniforms.shape == .lens)
        #expect(opening.room.uniforms.shape == .lens)
        #expect(opening.room.requestedRenders == renders + 1)
    }

    @Test("The sheet lists the models of the first ready provider, through the closure it is given")
    func theSheetAsksForTheReadyProvidersModels() async throws {
        let asked  = Asked()
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 460,
                height: 570
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: HouseNewWorkerSheet(
            shapes     : HouseFixture.workers.map(\.shape),
            connections: { [.codex: .notInstalled, .claudeCode: .ready, .ollama: .ready] },
            catalogue  : { provider in
                asked.providers.append(provider)
                return []
            }
        ) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()

        for _ in 0..<100 where asked.providers.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(asked.providers == [.claudeCode])
    }

    /// The providers the sheet asked the catalogue for, in order.
    private final class Asked {
        var providers: [ModelProvider] = []
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
