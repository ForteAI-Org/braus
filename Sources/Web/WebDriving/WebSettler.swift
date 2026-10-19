//
//  WebSettler.swift
//  Braus
//

import EngineCore
import Foundation
import WebDriver

/// WebSettler is `Settling` for tabs: after a gesture it reads a cheap signature of the page (its
/// address, load state, element count, text length and focused value) and returns once the
/// signature has held still for `quiet`, or at the cap.
///
/// The first read waits one interval, so a page that reacts on the next frame is not judged
/// before it has drawn. The signature is read from the tab's isolated world (`WebTabs.evaluate`).
public struct WebSettler: Settling {

    let tabs    : WebTabs
    let interval: Duration
    let quiet   : Duration

    public init(tabs: WebTabs, interval: Duration = .milliseconds(50), quiet: Duration = .milliseconds(150)) {
        self.tabs     = tabs
        self.interval = interval
        self.quiet    = quiet
    }

    public func settle(in processID: pid_t, cap: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + cap
        guard (try? tabs.page(for: processID)) != nil else {
            try? await Task.sleep(until: deadline)
            return
        }
        var last: JSONValue?
        var stillSince = clock.now
        while clock.now < deadline {
            try? await Task.sleep(for: min(interval, deadline - clock.now))
            guard !Task.isCancelled else { return }
            let signature = try? await tabs.evaluate(Self.signatureScript, in: processID, timeoutSeconds: 2)
            let now = clock.now
            if let signature, signature == last {
                if now - stillSince >= quiet, signature[0]?.stringValue == "complete" { return }
            } else {
                last = signature
                stillSince = now
            }
        }
    }

    static let signatureScript = """
    [document.readyState, location.href, document.getElementsByTagName('*').length,
     document.body ? document.body.innerText.length : 0,
     document.activeElement && typeof document.activeElement.value === 'string' ? document.activeElement.value.length : -1]
    """
}
