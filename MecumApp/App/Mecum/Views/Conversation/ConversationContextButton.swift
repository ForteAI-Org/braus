//
//  ConversationContextButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import SwiftUI

/// ConversationContextButton is the context ring as a toolbar item, before the
/// token counter in the same glass capsule: the toolbar draws its surface, so
/// the ring is bare. Its tooltip says how full the context is, or that it is
/// being compacted, and it opens a popover of the context and the context's
/// actions (`ConversationContextPopover`) below itself. Starting a fresh
/// context asks first, since it forgets.
struct ConversationContextButton: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context     : WorkerUsage.Context

    /// The worker's name, which the confirmation says.
    let worker      : String
    let isCompacting: Bool

    /// Why the actions wait, nil while the worker is free (`ConversationContextPopover.waitReason`).
    let waitReason  : String?
    let compact     : () -> Void
    let startFresh  : () -> Void

    /// Whether the popover is open: `TeamModel.showsContext`, which `/context` sets too.
    /// A button drawn alone, as a snapshot draws it, keeps it closed.
    var isShowingDetail: Binding<Bool> = .constant(false)

    @State private var isConfirmingFresh = false

    var body: some View {
        let wording = UsageWording()

        Button { isShowingDetail.wrappedValue.toggle() } label: {
            ConversationContextRing(
                fraction       : context.fraction ?? 0,
                side           : 16,
                lineWidth      : 2.2,
                isIndeterminate: isCompacting
            )
            // Room between the capsule's rim and the ring; the counter after it keeps its own.
            .padding(
                .leading,
                4
            )
        }
        .help(isCompacting ? UsageWording.compacting : wording.contextTip(context))
        .accessibilityLabel("Context")
        .accessibilityValue(isCompacting ? UsageWording.compacting : wording.contextSpoken(context))
        .popover(
            isPresented: isShowingDetail,
            arrowEdge  : .bottom
        ) {
            ConversationContextPopover(
                context   : context,
                waitReason: waitReason,
                compact   : {
                    isShowingDetail.wrappedValue = false
                    compact()
                },
                startFresh: {
                    isShowingDetail.wrappedValue = false
                    isConfirmingFresh            = true
                }
            )
        }
        .confirmationDialog(
            "Start a Fresh Context?",
            isPresented    : $isConfirmingFresh,
            titleVisibility: .visible
        ) {
            Button(
                "Start Fresh Context",
                role: .destructive
            ) {
                startFresh()
            }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text("\(worker) forgets everything before now. The chat stays.")
        }
    }
}
