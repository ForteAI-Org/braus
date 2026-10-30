//
//  ScreenWindowContent.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import SeatBroker
import SwiftUI

/// ScreenWindowContent fills a worker's screen window: the held window on its stage (`ScreenStage`)
/// and the control bar (`ScreenControlBar`) at the foot. The
/// worker and what it says sit on the window's corner, in a panel of their own
/// (`ScreenWorkerPresence`).
///
/// The bar shows when the window opens and on any pointer movement over it, and fades once the
/// pointer has rested `idleDelay`. It stays while the pointer is on it, a button has the keyboard,
/// the person has the application, or VoiceOver runs, so every action is reachable without hover.
struct ScreenWindowContent: View {
    let worker: HouseWorker
    let team  : TeamModel

    /// What draws the window in place of the live view; the window check passes a still.
    var makePicture: ScreenStage.Picture?

    let openInBraus: () -> Void

    /// The window's frame in AppKit's screen space, where the application lands as control is taken.
    var windowFrame: () -> CGRect? = { nil }

    /// Gives the window the held window's size, as it is known and as it changes.
    var fitWindow: (CGSize) -> Void = { _ in }

    /// Closes the window, which has no close button of its own.
    var close: () -> Void = {}

    /// How long the pointer rests before the bar fades.
    static let idleDelay: Duration = .seconds(3)

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRuns

    /// Shown from the last movement until the pointer has rested `idleDelay`; shown when opened.
    @State private var pointerMoved = true
    @State private var isOverBar    = false
    @State private var lastMovement = Movement()

    /// Shown from the click that takes control until the application has reached the person, and
    /// held until it fades off the picture just before the swap (`TakeControlBeats`).
    @State private var showsCurtain = false
    @State private var curtainHolds = false

    @FocusState private var focusedControl: ScreenHoverControls.Control?
    @FocusState private var opensFocused  : Bool

    var body: some View {
        let lending  = team.humanControls[worker.id]
        let showsBar = pointerMoved
            || isOverBar
            || focusedControl != nil
            || opensFocused
            || voiceOverRuns
            || ScreenHoverControls.isUnderway(lending)

        ScreenStage(
            team       : team,
            workerID   : worker.id,
            makePicture  : makePicture,
            onPictureSize: fitWindow
        )
        // A new main window, as the old one closes, gets a stage of its own: its stream and its size.
        .id(team.mainWindow(of: worker.id)?.windowNumber)
        .ignoresSafeArea()
        .overlay {
            if showsCurtain {
                // Until the application starts on its way, the worker is finishing its step.
                let begun = team.lendingBegun.contains(worker.id) || lending?.lentWindow != nil
                Curtain(
                    title  : begun ? TakeControlCurtain.controlTitle : TakeControlCurtain.waitingTitle,
                    picture: { team.screenView(in: .window) },
                    holds  : (curtainHolds || !begun) && Self.isLending(lending),
                    onGone : { showsCurtain = false }
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            ScreenControlBar(
                worker     : liveWorker,
                lending    : lending,
                namesKey   : ControlToggle.namesKey(
                    ControlShortcut.state(
                        of: worker.id,
                        in: team
                    ),
                    voiceOver: voiceOverRuns
                ),
                focus      : $focusedControl,
                opensFocus : $opensFocused,
                stop       : stop,
                takeControl: takeControl,
                openInBraus: openInBraus,
                close      : close
            )
            .onHover { isOverBar = $0 }
            .padding(
                .horizontal,
                12
            )
            .padding(
                .bottom,
                14
            )
            .opacity(showsBar ? 1 : 0)
            .animation(
                .easeOut(duration: 0.25),
                value: showsBar
            )
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                lastMovement.at = .now
                if !pointerMoved { pointerMoved = true }
            case .ended:
                pointerMoved = false
            }
        }
        .task(id: pointerMoved) { await fadeWhenIdle() }
        .onChange(of: team.takeControlAsked) { _, asked in
            if asked?.workerID == worker.id { takeControl() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(liveWorker.name)'s screen")
    }

    /// The worker as the house shows it now, or as it was when the window opened.
    private var liveWorker: HouseWorker {
        HouseRoster.workers(of: team).first { $0.id == worker.id } ?? worker
    }

    /// Waits until the pointer has rested `idleDelay` since its last movement, then hides the bar.
    private func fadeWhenIdle() async {
        guard pointerMoved else { return }

        lastMovement.at = .now
        while !Task.isCancelled {
            let rest = lastMovement.at + Self.idleDelay - .now
            if rest <= .zero {
                pointerMoved = false
                return
            }
            try? await Task.sleep(for: rest)
        }
    }

    /// Takes control for the person and covers the picture while the application comes to them;
    /// nothing new while they already have it or are getting it.
    private func takeControl() {
        guard !ScreenHoverControls.isUnderway(team.humanControls[worker.id]) else { return }

        team.beginHumanControl(
            worker.id,
            from: windowFrame()
        )
        showsCurtain = Self.isLending(team.humanControls[worker.id])
        curtainHolds = showsCurtain
        Task {
            try? await Task.sleep(for: .seconds(TakeControlBeats.revealStart))
            curtainHolds = false
        }
    }

    /// True from Take Control until the application is lent, or the lend ends otherwise: refused,
    /// blocked or finished.
    static func isLending(_ lending: HumanPreviewControl?) -> Bool {
        guard let lending, lending.hasStarted else { return false }

        return lending.lentWindow == nil
            && !lending.lendingRefused
            && !lending.isBlocked
            && !lending.isFinishing
            && !lending.isFinished
    }

    private func stop() {
        team.stopAnswering(worker.id)
        Task { await team.releaseComputer(worker.id) }
    }

    /// Curtain hosts the curtain that covers the picture while control is taken (`TakeControlCurtain`):
    /// it plays as it appears, says each new `title`, and fades out once it no longer `holds`.
    private struct Curtain: NSViewRepresentable {
        let title  : String
        let picture: () -> NSView?
        let holds  : Bool
        let onGone : () -> Void

        func makeNSView(context: Context) -> TakeControlCurtain {
            let curtain = TakeControlCurtain(
                title  : title,
                picture: picture()
            )
            curtain.onGone = onGone
            curtain.play()
            return curtain
        }

        func updateNSView(
            _ curtain: TakeControlCurtain,
            context  : Context
        ) {
            curtain.retitle(title)
            if !holds { curtain.release() }
        }
    }

    /// Movement is when the pointer last moved. A reference, so a movement redraws nothing.
    private final class Movement {
        var at = ContinuousClock.now
    }
}
