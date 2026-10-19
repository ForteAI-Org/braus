//
//  AdapterApprovalDialog.swift
//  Braus
//

import SwiftUI

/// AdapterApprovalDialog shows, as a sheet over the team window, the first irreversible adapter call waiting for
/// the person's answer (`AdapterApprovalSheet`). Answering it shows the next one, so requests follow one at a
/// time. The sheet cannot be dismissed without an answer; a request left alone is refused after
/// `AdapterApprovals.timeout`, and every waiting request is refused when Braus quits.
struct AdapterApprovalDialog: ViewModifier {

    let approvals: AdapterApprovals?

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { approvals?.pending.first },
            // Only an answer removes a request; a sheet closed another way leaves it to the timeout.
            set: { _ in }
        )) { pending in
            AdapterApprovalSheet(
                pending     : pending,
                answerableAt: approvals?.answerableAt(pending.id),
                allowOnce   : {
                    approvals?.respond(
                        pending.id,
                        allowed: true
                    )
                },
                refuse      : {
                    approvals?.respond(
                        pending.id,
                        allowed: false
                    )
                }
            )
        }
    }
}

extension View {

    /// Shows the irreversible adapter calls waiting for the person's answer, one at a time.
    func adapterApprovals(_ approvals: AdapterApprovals?) -> some View {
        modifier(AdapterApprovalDialog(approvals: approvals))
    }
}
