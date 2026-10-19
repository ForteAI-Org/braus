//
//  AdapterApprover.swift
//  Braus
//

import AppAdapters

/// AdapterApprover is the app's `AdapterApproving`: it asks the person about one irreversible adapter call (a
/// mail sent, an event deleted) through `AdapterApprovals`, which the team window shows as a confirmation.
struct AdapterApprover: AdapterApproving {

    let approvals: AdapterApprovals

    func approve(_ consent: AdapterConsent) async -> Bool {
        await approvals.ask(consent)
    }
}
