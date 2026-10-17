//
//  WebSettler.swift
//  Braus
//

import EngineCore
import Foundation
import WebDriver

/// WebSettler is `Settling` for tabs: after a gesture it reads a cheap signature of the page (its
/// address, load state, element count, text length, focused value length, and how many times its DOM
/// changed) and returns once the signature has held still for `quiet`, or at the cap.
///
/// The count of changes comes from an observer `prepare` installs in the page before the gesture, so a
/// text replaced by one of the same length keeps the page busy (W12). A `style` attribute is not
/// counted, so an animation alone does not hold every action to its cap. A page that reacts later
/// than `quiet` after it went still (a request still in flight, a timer) is not waited for, and a
/// focused field's value changed to one of the same length is not seen.
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

    /// Installs, once per document, the observer that counts the page's DOM changes, in the tab's isolated
    /// world, where the signature reads its count.
    public func prepare(in processID: pid_t) async {
        _ = try? await tabs.evaluate(Self.observerScript, in: processID, timeoutSeconds: 2)
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

    /// Counts, on the isolated world's window and out of the DOM, the page's changes: nodes added or removed, text, and every
    /// attribute but `style`.
    static let observerScript = """
    (() => {
      /* braus:mutations */
      if (!window.__brausMutations) {
        const state = { count: 0 };
        new MutationObserver(records => {
          for (const record of records) if (record.attributeName !== 'style') state.count++;
        }).observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
        Object.defineProperty(window, '__brausMutations', { value: state, configurable: true });
      }
      return window.__brausMutations.count;
    })()
    """

    static let signatureScript = """
    /* braus:settle */
    [document.readyState, location.href, document.getElementsByTagName('*').length,
     document.body ? document.body.innerText.length : 0,
     document.activeElement && typeof document.activeElement.value === 'string' ? document.activeElement.value.length : -1,
     window.__brausMutations ? window.__brausMutations.count : -1]
    """
}
