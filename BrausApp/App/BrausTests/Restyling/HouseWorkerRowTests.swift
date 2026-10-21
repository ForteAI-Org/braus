import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseWorkerRow", .serialized)
@MainActor
struct HouseWorkerRowTests {
    @Test("Every portrait clips the room but contains its brows, at every size it is shown at, and fits the card")
    func silhouettes() throws {
        let sizes = [18, HouseWorkerPortrait.rowSize, HouseShapeGrid.mascotSize, HouseHero.workerSize]
        for size in sizes {
            let side = HouseWorkerPortrait.sceneSide(for: size)
            for shape in WorkerShape.allCases {
                let path = HouseWorkerPortrait.silhouette(
                    of  : shape,
                    side: side
                )
                let bounds = path.boundingRect
                #expect(bounds.width > 0 && bounds.height > 0)
                if size == HouseWorkerPortrait.rowSize {
                    #expect(bounds.width < 56 && bounds.height < HouseLayout.rowHeight)
                }
                #expect(!path.contains(.zero))
                #expect(!path.contains(CGPoint(
                    x: side,
                    y: side
                )))
                let face = try #require(RoomCamera.tilted.face(
                    of  : shape,
                    in  : CGSize(
                        width : side,
                        height: side
                    ),
                    lean: HouseWorkerPortrait.lean
                ))
                #expect(path.contains(CGPoint(
                    x: side / 2 + face.anchor.dx,
                    y: side / 2 + face.anchor.dy
                )), "\(shape) at \(size): the brows stay inside the visible body")
            }
        }
    }

    @Test("Every shape stands inside its cell of the shape picker")
    func gridCellsHoldTheShapes() {
        let side = HouseWorkerPortrait.sceneSide(for: HouseShapeGrid.mascotSize)
        for shape in WorkerShape.allCases {
            let bounds = HouseWorkerPortrait.silhouette(
                of  : shape,
                side: side
            ).boundingRect
            #expect(bounds.width <= HouseShapeGrid.cell.width - 4, "\(shape): \(bounds.size)")
            #expect(bounds.height <= HouseShapeGrid.cell.height - 4, "\(shape): \(bounds.size)")
        }
    }

    @Test("A preparation squashes the whole worker, body and brows together, and nothing under Reduce Motion")
    func preparationMovesTheWholeWorker() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        for reducesMotion in [false, true] {
            RestylingMotion.overrideReducesMotion = reducesMotion
            let host = NSHostingView(rootView: HouseWorkerPortrait(
                shape      : .triangle,
                status     : .busy,
                size       : HouseHero.workerSize,
                preparation: 0
            ))
            host.frame = CGRect(
                x     : 0,
                y     : 0,
                width : 120,
                height: 120
            )
            host.layoutSubtreeIfNeeded()
            let portrait = try #require(Self.find(HouseWorkerPortrait.HostView.self, in: host))
            #expect(portrait.figure.layer?.animation(forKey: HouseWorkerPortrait.HostView.prepareKey) == nil)

            host.rootView = HouseWorkerPortrait(
                shape      : .triangle,
                status     : .busy,
                size       : HouseHero.workerSize,
                preparation: 1
            )
            host.layoutSubtreeIfNeeded()
            let squash = portrait.figure.layer?.animation(forKey: HouseWorkerPortrait.HostView.prepareKey)
            #expect((squash != nil) == !reducesMotion)
            #expect(portrait.face.mascot.animation(forKey: "prepare") == nil)
            #expect(portrait.room?.superview === portrait.figure)
        }
    }

    @Test("Selecting a card keeps its tilted worker and status light present")
    func selectionKeepsWorker() async throws {
        let worker = try #require(MockHouse.sample.workers.first)
        let host = NSHostingView(rootView: HouseWorkerRow(
            worker    : worker,
            isSelected: false
        ))
        host.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 260,
            height: HouseLayout.rowHeight
        )
        for selected in [false, true] {
            host.rootView = HouseWorkerRow(
                worker    : worker,
                isSelected: selected
            )
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let views = lights(in: host)
            #expect(views.count == 1)
            let light = try #require(views.first)
            #expect(light.uniforms.hasOccupant)
            #expect(light.uniforms.camera == .tilted)
            #expect(light.uniforms.status == worker.status)
            #expect(light.uniforms.shape == worker.shape)
        }
    }

    static func find<V: NSView>(
        _ type: V.Type,
        in view: NSView
    ) -> V? {
        if let found = view as? V { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private func lights(in view: NSView) -> [RoomLightView] {
        let own = (view as? RoomLightView).map { [$0] } ?? []
        return own + view.subviews.flatMap { lights(in: $0) }
    }
}
