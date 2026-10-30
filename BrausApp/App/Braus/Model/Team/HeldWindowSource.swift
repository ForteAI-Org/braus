//
//  HeldWindowSource.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import SeatBroker

extension TwinWindow {

    /// The twin's view of a window the seat holds.
    init(_ held: HeldWindow) {
        let kind: Kind = switch held.kind {
        case .main  : .main
        case .dialog: .dialog
        case .sheet : .sheet
        case .panel : .panel
        case .other : .other
        }
        self.init(
            windowNumber      : held.windowNumber,
            processID         : held.processID,
            frame             : held.frame,
            level             : held.level,
            kind              : kind,
            parentWindowNumber: held.parentWindowNumber,
            title             : held.title,
            order             : held.order
        )
    }
}

/// HeldWindowSource gives the twins the windows a worker's seat holds and a live view of each, as the
/// worker's desktop session reports and streams them.
@MainActor
final class HeldWindowSource: TwinSource {
    private let session: BrokeredAutomationSession

    init(session: BrokeredAutomationSession) {
        self.session = session
    }

    var windows: [TwinWindow] { session.heldWindows.map(TwinWindow.init) }

    func makeView(
        windowNumber : Int,
        contentsScale: CGFloat
    ) -> NSView? {
        session.makeWindowView(
            windowNumber : windowNumber,
            contentsScale: contentsScale
        )
    }

    func resize(
        windowNumber: Int,
        to size     : CGSize
    ) -> CGSize? {
        session.resizeHeldWindow(
            windowNumber,
            to: size
        )
    }
}
