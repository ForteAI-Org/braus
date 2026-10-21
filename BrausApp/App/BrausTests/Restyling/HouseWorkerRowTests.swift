import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseWorkerRow", .serialized)
@MainActor
struct HouseWorkerRowTests {
    @Test("Every portrait clips the room but contains its brows and fits the card")
    func silhouettes() throws {
        let size = HouseWorkerPortrait.sceneSize
        for shape in WorkerShape.allCases {
            let path = HouseWorkerPortrait.silhouette(of: shape)
            let bounds = path.boundingRect
            #expect(bounds.width > 0 && bounds.height > 0)
            #expect(bounds.width < 56 && bounds.height < HouseLayout.rowHeight)
            #expect(!path.contains(.zero))
            #expect(!path.contains(CGPoint(
                x: size.width,
                y: size.height
            )))
            let face = try #require(RoomCamera.tilted.face(
                of  : shape,
                in  : size,
                lean: HouseWorkerPortrait.lean
            ))
            #expect(path.contains(CGPoint(
                x: size.width / 2 + face.anchor.dx,
                y: size.height / 2 + face.anchor.dy
            )), "\(shape): the brows stay inside the visible body")
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

    @Test("The compact card is chosen below the grid's compaction threshold")
    func compactBelowThreshold() {
        let threshold = ShellMetrics.sidebar.minimum
        #expect(HouseLayout.columns(sidebarWidth: threshold - 1) == 1)
        #expect(HouseLayout.columns(sidebarWidth: threshold) == 2)
        #expect(HouseLayout.rowHeight(isCompact: false) == HouseLayout.rowHeight)
        #expect(HouseLayout.rowHeight(isCompact: true) == HouseLayout.compactRowHeight)
        #expect(HouseLayout.compactRowHeight > HouseLayout.rowHeight)
    }

    @Test("Compacting keeps the same views")
    func compactingKeepsIdentity() async throws {
        let worker = try #require(MockHouse.sample.workers.first { $0.badge != nil })
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
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let wide = try #require(lights(in: host).first)
        host.rootView = HouseWorkerRow(
            worker    : worker,
            isSelected: false,
            isCompact : true
        )
        host.frame.size = CGSize(
            width : 120,
            height: HouseLayout.compactRowHeight
        )
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let compact = lights(in: host)
        #expect(compact.count == 1)
        #expect(compact.first === wide, "the portrait is not rebuilt")
    }

    private func lights(in view: NSView) -> [RoomLightView] {
        let own = (view as? RoomLightView).map { [$0] } ?? []
        return own + view.subviews.flatMap { lights(in: $0) }
    }
}
