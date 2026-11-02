//
//  ScreenHoverControls.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SeatBroker
import SwiftUI

/// ScreenHoverControls is the row of small buttons the worker's screen shows while the pointer is
/// over it: Stop ends the task and Take Control pauses the worker and lends you the application.
/// Given the `lending` under way, Take Control reads Hand Back while the person has the
/// application, as `HumanControlBar` does.
struct ScreenHoverControls: View {

    /// Control is one of the row's buttons.
    enum Control: CaseIterable {
        case stop, takeControl, saySomething

        var title: String {
            switch self {
            case .stop        : "Stop"
            case .takeControl : "Take Control"
            case .saySomething: "Say Something"
            }
        }

        /// Voice input is not part of the interactive preview trial.
        var isEnabled: Bool { self != .saySomething }

        /// The button's help, naming ⌃⌥Tab only while a press of it would act (`ControlToggle.namesKey`).
        func help(namingKey: Bool) -> String {
            switch self {
            case .stop: "Stop the worker."
            case .takeControl where namingKey: "Pause the worker and use the application yourself (\(ControlShortcut.label))."
            case .takeControl: "Pause the worker and use the application yourself."
            case .saySomething: "Coming later"
            }
        }

        /// The help of Take Control while it reads Hand Back.
        static func endHelp(namingKey: Bool) -> String {
            namingKey
                ? "Give the application back to the worker (\(ControlShortcut.label))."
                : "Give the application back to the worker."
        }
    }

    /// Which button has the keyboard; the screen keeps the row shown while one has it.
    let focus: FocusState<Control?>.Binding

    let stop: () -> Void
    var takeControl: () -> Void = {}

    /// The person's control of the application, once offered; nil keeps Take Control as it is.
    var lending: HumanPreviewControl?

    /// Whether the help names ⌃⌥Tab: only while a press of it would act for this worker.
    var namesKey = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(
                Control.allCases,
                id: \.self
            ) { control in
                let ends = control == .takeControl && Self.isUnderway(lending)
                Button(ends ? "Hand Back" : control.title) {
                    if control == .stop { stop() }
                    if control == .takeControl {
                        if ends { Task { await lending?.finish() } } else { takeControl() }
                    }
                }
                .disabled(!control.isEnabled || (control == .takeControl && lending?.isFinishing == true))
                .help(ends ? Control.endHelp(namingKey: namesKey) : control.help(namingKey: namesKey))
                .focused(
                    focus,
                    equals: control
                )
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// True while the person has the application or is getting it: from Take Control until it ends.
    static func isUnderway(_ lending: HumanPreviewControl?) -> Bool {
        guard let lending, !lending.isFinished else { return false }

        return lending.hasStarted || lending.isBlocked
    }
}
