//
//  HumanControlBar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/10/2026.
//

import SeatBroker
import SwiftUI

/// HumanControlBar keeps the trial's ownership and explicit exit visible, including on refusal.
struct HumanControlBar: View {
    let control: HumanPreviewControl

    var body: some View {
        VStack(spacing: 6) {
            Text(control.status)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !control.hasStarted && !control.isBlocked {
                    Button("Take Control") {
                        control.takeControl(on: PersonScreen.current(pointer: NSEvent.mouseLocation))
                    }
                    .disabled(control.isFinishing || control.isFinished)
                }
                if control.hasStarted || control.isBlocked {
                    Button("Hand Back") { Task { await control.finish() } }
                        .disabled(control.isFinishing || control.isFinished)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(6)
    }
}
