//
//  ScreenHoverControls.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// ScreenHoverControls is the row of small buttons the worker's screen shows while the pointer is
/// over it: Stop works; Take Control and Say Something wait for later and say so in their help.
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

        /// Only Stop works yet.
        var isEnabled: Bool { self == .stop }

        var help: String {
            isEnabled ? "Stop the worker." : "Coming later"
        }
    }

    /// Which button has the keyboard; the screen keeps the row shown while one has it.
    let focus: FocusState<Control?>.Binding

    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(
                Control.allCases,
                id: \.self
            ) { control in
                Button(control.title) {
                    if control == .stop { stop() }
                }
                .disabled(!control.isEnabled)
                .help(control.help)
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
}
