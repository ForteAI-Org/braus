//
//  WindowSnapshots+House.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Memory
import Metal
import MetalKit
import ModelTransports
import SeatBroker
import SwiftUI

extension WindowSnapshots {

    /// Writes the house window (`HouseShellView`, the new look) of the synthetic team as
    /// `house-*.png`: rooms, rows, compact, the inspector open, an empty team, and teams of 30 and 60
    /// workers for the performance pass. The flag-off snapshots are untouched.
    ///
    /// The split's sidebar column and a Metal room draw nothing offscreen, so the sidebar is drawn on
    /// its own, layer by layer, over the column, and each room is lit again with the precomputed
    /// kernels (`RoomPicture`) into a layer of it. The ray tracer's refinement is not reproduced, so a
    /// busy light does not pulse.
    static func writeHouse(
        from team: TeamModel,
        in store : URL,
        to output: URL
    ) async throws {
        guard let appStorage else { throw HouseSnapshotFailure("no defaults of the snapshots' own") }
        defer {
            appStorage.set(
                false,
                forKey: AppPreferences.newLook
            )
            appStorage.removeObject(forKey: AppPreferences.restylingSidebarMode)
        }
        appStorage.set(
            true,
            forKey: AppPreferences.newLook
        )

        let minimum = RestylingWindowLayout.minimumWidth
        let cases: [(name: String, mode: SidebarMode, width: Double, inspector: Bool)] = [
            ("rooms", .rooms, 1200, false),
            ("rows", .rows, 1200, false),
            ("compact", .rooms, minimum, false),
            ("compact-rows", .rows, minimum, false),
            ("inspector", .rooms, 1200, true),
        ]
        for shot in cases {
            appStorage.set(
                shot.mode.rawValue,
                forKey: AppPreferences.restylingSidebarMode
            )
            try await writeHouseWindow(
                team,
                width    : shot.width,
                inspector: shot.inspector,
                to       : output.appending(path: "house-\(shot.name).png")
            )
        }

        appStorage.set(
            SidebarMode.rooms.rawValue,
            forKey: AppPreferences.restylingSidebarMode
        )
        let empty = TeamModel(
            store      : try WorkspaceStore.opening(in: store.appending(
                path         : "HouseEmpty",
                directoryHint: .isDirectory
            )),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await empty.load()
        try await writeHouseWindow(
            empty,
            width    : 1200,
            inspector: false,
            to       : output.appending(path: "house-empty.png")
        )

        for count in [30, 60] {
            try await writeHouseWindow(
                try await crowdedTeam(
                    count: count,
                    in   : store.appending(
                        path         : "House\(count)",
                        directoryHint: .isDirectory
                    )
                ),
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-\(count)-workers.png")
            )
        }
    }

    /// `count` workers for the house's load: every seventh has no model (off), every fifth has an
    /// unread reply (waiting), the rest are free. None is busy, which needs a running turn.
    private static func crowdedTeam(
        count    : Int,
        in folder: URL
    ) async throws -> TeamModel {
        let store     = try WorkspaceStore.opening(in: folder)
        let selection = ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .high
        )
        let palettes = ["dusk", "tide", "ember", "dawn"]
        var first: UUID?

        for index in 0..<count {
            let worker = try await store.createWorker(
                name      : "Worker \(index + 1)",
                role      : "Role \(index % 9 + 1)",
                appearance: WorkerAppearance(
                    seed   : Int64(index * 7 + 3),
                    palette: palettes[index % palettes.count]
                )
            )
            first = first ?? worker.id
            guard index % 7 != 6 else { continue }

            try await store.configure(
                worker   : worker.id,
                selection: selection
            )
            guard index % 5 == 4 else { continue }

            let conversation = try await store.createConversation(
                kind        : .direct,
                participants: [worker.id]
            )
            try await store.appendMessage(
                to      : conversation.id,
                author  : worker.id,
                text    : "Done.",
                delivery: .completed
            )
        }

        let team = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.load()
        team.selection = first
        await team.openSelectedConversation()
        return team
    }

    // MARK: Drawing

    /// The window's memory as plain state, as `Root` does for today's shell.
    private struct HouseRoot: View {

        let team: TeamModel

        @State var isInspectorRequested: Bool

        var body: some View {
            HouseShellView(
                team                : team,
                isInspectorRequested: $isInspectorRequested
            )
        }
    }

    /// What one offscreen drawing gives back: the picture, and what the caller needs of the window.
    private struct Drawn {

        let bitmap       : NSBitmapImageRep
        let toolbarHeight: CGFloat
        let sidebarWidth : CGFloat
        let inspectorWidth: CGFloat
        let rooms        : Int
        let lit          : Int
        let allocated    : Int
    }

    /// Draws the house window at `width` by 900. Its sidebar column draws blank offscreen, as the old
    /// shell's does, so the sidebar is drawn again on its own over the same column.
    private static func writeHouseWindow(
        _ team   : TeamModel,
        width    : Double,
        inspector: Bool,
        to file  : URL
    ) async throws {
        let height = 900.0
        let window = try await draw(
            HouseRoot(
                team                : team,
                isInspectorRequested: inspector
            ),
            width : width,
            height: height,
            titled: true
        )
        guard window.sidebarWidth > 0 else { throw HouseSnapshotFailure("no sidebar column in \(file.lastPathComponent)") }
        let sidebar = try await draw(
            HouseSidebarAlone(
                team: team,
                top : window.toolbarHeight
            ),
            width : window.sidebarWidth,
            height: height,
            titled: false
        )
        let inspectorColumn = window.inspectorWidth > 0 ? try await draw(
            HouseInspectorAlone(
                team: team,
                top : window.toolbarHeight
            ),
            width : window.inspectorWidth,
            height: height,
            titled: false
        ) : nil

        // Each column over the window's drawing: the sidebar's below the toolbar's strip, which keeps the
        // window's buttons, the inspector's whole, as nothing of its strip is drawn.
        let size = window.bitmap.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: window.bitmap) else {
            throw HouseSnapshotFailure("no context for \(file.lastPathComponent)")
        }
        NSGraphicsContext.current = context
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(
            x     : 0,
            y     : 0,
            width : window.sidebarWidth,
            height: size.height - window.toolbarHeight
        )).addClip()
        sidebar.bitmap.draw(in: NSRect(
            x     : 0,
            y     : 0,
            width : window.sidebarWidth,
            height: size.height
        ))
        NSGraphicsContext.restoreGraphicsState()
        inspectorColumn?.bitmap.draw(in: NSRect(
            x     : size.width - window.inspectorWidth,
            y     : 0,
            width : window.inspectorWidth,
            height: size.height
        ))
        context.flushGraphics()

        guard let png = window.bitmap.representation(
            using     : .png,
            properties: [:]
        ) else {
            throw HouseSnapshotFailure("no PNG for \(file.lastPathComponent)")
        }
        try png.write(to: file)
        print("snapshot: \(file.path)")
        print("house: \(file.lastPathComponent) rooms=\(sidebar.rooms) lit=\(sidebar.lit) gpu=\(sidebar.allocated / 1_048_576) MB")
    }

    /// The sidebar of the house window alone, on its own ground, below the toolbar's strip.
    private struct HouseSidebarAlone: View {

        @Bindable
        var team: TeamModel

        let top: CGFloat

        var body: some View {
            HouseSidebar(
                house    : MockHouse(
                    workers      : HouseRoster.workers(
                        of              : team,
                        showsUnreadCount: AppPreferenceValues.shared.sidebarShowsUnreadCount
                    ),
                    archivedCount: team.archived.count,
                    mostUsed     : []
                ),
                selection: $team.selection
            )
            .safeAreaInset(
                edge   : .top,
                spacing: 0
            ) {
                Color.clear.frame(height: top)
            }
            .scrollContentBackground(.hidden)
            .background { Color("RestylingSidebar").ignoresSafeArea() }
        }
    }

    /// The inspector of the house window alone, on its own ground, with the separator on its edge.
    private struct HouseInspectorAlone: View {

        @Bindable
        var team: TeamModel

        let top: CGFloat

        var body: some View {
            Group {
                if let worker = team.selectedWorker {
                    WorkerInspectorView(
                        team  : team,
                        worker: worker
                    )
                } else {
                    ContentUnavailableView(
                        "No Worker Selected",
                        systemImage: "info.circle",
                        description: Text("Select a worker to view current activity and turn details.")
                    )
                }
            }
            .safeAreaInset(
                edge   : .top,
                spacing: 0
            ) {
                Color.clear.frame(height: top)
            }
            .scrollContentBackground(.hidden)
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity
            )
            .background { Color("RestylingInspector").ignoresSafeArea() }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) { Divider() }
                    .ignoresSafeArea()
            }
        }
    }

    /// Hosts `content` at `width` by `height` in a window that is never shown, lets it settle, puts
    /// every visible room's light in its place and draws the window's frame view.
    private static func draw(
        _ content: some View,
        width     : Double,
        height    : Double,
        titled    : Bool
    ) async throws -> Drawn {
        let appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = appearance

        let hosting = NSHostingView(rootView: content
            .defaultAppStorage(appStorage ?? .standard))
        hosting.sceneBridgingOptions = titled ? [.toolbars, .title] : []

        let window = NSWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : width,
                height: height
            ),
            styleMask  : titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = appearance
        window.contentView          = hosting
        window.setContentSize(NSSize(
            width : width,
            height: height
        ))

        // The split decides its division from the first width it reports, then the rooms settle.
        for _ in 0..<30 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }

        let frame = window.contentView?.superview ?? hosting
        frame.layoutSubtreeIfNeeded()

        // A Metal room is a layer a render of the tree skips: its light goes in a sublayer of it.
        var pictures: [CALayer] = []
        let rooms = rooms(in: frame).filter { !$0.visibleRect.isEmpty }
        if !titled {
            for room in rooms {
                guard let picture = RoomPicture.layer(
                    for  : room,
                    scale: window.backingScaleFactor
                ) else { continue }
                room.layer?.addSublayer(picture)
                pictures.append(picture)
            }
        }
        let allocated = MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0
        let bitmap: NSBitmapImageRep

        if titled {
            // The window's frame, toolbar included, as the old shell's snapshots draw it.
            guard let cached = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                throw HouseSnapshotFailure("no bitmap")
            }
            frame.cacheDisplay(
                in: frame.bounds,
                to: cached
            )
            bitmap = cached
        } else {
            // Layer by layer, which reaches what the views do not draw (the plaque, the brows).
            let scale = window.backingScaleFactor
            guard
                let layer   = frame.layer,
                let context = CGContext(
                    data            : nil,
                    width           : Int((frame.bounds.width * scale).rounded(.up)),
                    height          : Int((frame.bounds.height * scale).rounded(.up)),
                    bitsPerComponent: 8,
                    bytesPerRow     : 0,
                    space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo      : CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            else { throw HouseSnapshotFailure("no context") }
            context.scaleBy(
                x: scale,
                y: scale
            )
            layer.render(in: context)
            guard let image = context.makeImage() else { throw HouseSnapshotFailure("no image") }
            bitmap      = NSBitmapImageRep(cgImage: image)
            bitmap.size = frame.bounds.size
        }
        let drawn = Drawn(
            bitmap       : bitmap,
            toolbarHeight: window.frame.height - window.contentLayoutRect.height,
            sidebarWidth : columnWidth(in: frame, leading: true),
            inspectorWidth: columnWidth(in: frame, leading: false),
            rooms        : rooms.count,
            lit          : pictures.count,
            allocated    : Int(allocated)
        )
        for picture in pictures { picture.removeFromSuperlayer() }
        window.close()
        return drawn
    }

    /// The width of the sidebar column (`leading`) or of the inspector's, 0 when the window has none: a
    /// subview of a split as tall as the split, at its leading edge or its trailing one.
    private static func columnWidth(
        in view: NSView,
        leading: Bool
    ) -> CGFloat {
        var splits: [NSSplitView] = []
        func collect(_ view: NSView) {
            if let split = view as? NSSplitView { splits.append(split) }
            view.subviews.forEach(collect)
        }
        collect(view)
        for split in splits {
            for column in split.subviews.map(\.frame) {
                let isTall  = column.height == split.bounds.height
                let isNarrow = column.width > 100 && column.width < split.bounds.width
                let isAtEdge = leading ? column.minX == 0 : column.maxX == split.bounds.width
                if isTall && isNarrow && isAtEdge { return column.width }
            }
        }
        return 0
    }

    private static func rooms(in view: NSView) -> [RoomLightView] {
        var found: [RoomLightView] = []
        if let room = view as? RoomLightView { found.append(room) }
        for subview in view.subviews { found += rooms(in: subview) }
        return found
    }

    private struct HouseSnapshotFailure: Error, CustomStringConvertible {

        let description: String

        init(_ description: String) { self.description = description }
    }

    // MARK: Rooms

    /// RoomPicture lights a room again for a window that is not shown, with the precomputed kernels
    /// (`PrecomputedRoomRenderer`), and wraps the image in a layer that fills the room.
    @MainActor
    private enum RoomPicture {

        /// One renderer per device, as the rooms share their pipelines.
        private static var renderers: [ObjectIdentifier: PrecomputedRoomRenderer] = [:]

        static func layer(
            for room: RoomLightView,
            scale   : CGFloat
        ) -> CALayer? {
            guard
                let device = room.device,
                let image  = light(
                    room,
                    device: device,
                    scale : scale
                )
            else { return nil }
            let picture = CALayer()
            picture.frame           = room.bounds
            picture.contents        = image
            picture.contentsGravity = .resize
            picture.contentsScale   = scale
            return picture
        }

        /// `room` lit at its size and its uniforms, at full strength, as an image.
        private static func light(
            _ room : RoomLightView,
            device : MTLDevice,
            scale  : CGFloat
        ) -> CGImage? {
            let key = ObjectIdentifier(device as AnyObject)
            if renderers[key] == nil { renderers[key] = PrecomputedRoomRenderer(device: device) }
            let width  = Int((room.bounds.width * scale).rounded(.up))
            let height = Int((room.bounds.height * scale).rounded(.up))
            guard
                let renderer = renderers[key],
                width > 0,
                height > 0
            else { return nil }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width      : width,
                height     : height,
                mipmapped  : false
            )
            descriptor.usage       = [.shaderWrite]
            descriptor.storageMode = RoomLightView.frameStorageMode(
                isAppleGPU      : device.supportsFamily(.apple1),
                hasUnifiedMemory: device.hasUnifiedMemory
            )
            guard
                let texture = device.makeTexture(descriptor: descriptor),
                let buffer  = renderer.commandQueue.makeCommandBuffer()
            else { return nil }
            renderer.encode(
                room.uniforms,
                size         : room.bounds.size,
                into         : texture,
                commandBuffer: buffer
            )
            if texture.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture)
                blit.endEncoding()
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else { return nil }

            var bytes = [UInt8](
                repeating: 0,
                count    : width * 4 * height
            )
            texture.getBytes(
                &bytes,
                bytesPerRow: width * 4,
                from       : MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(
                width            : width,
                height           : height,
                bitsPerComponent : 8,
                bitsPerPixel     : 32,
                bytesPerRow      : width * 4,
                space            : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo       : CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                ),
                provider         : provider,
                decode           : nil,
                shouldInterpolate: false,
                intent           : .defaultIntent
            )
        }
    }
}
