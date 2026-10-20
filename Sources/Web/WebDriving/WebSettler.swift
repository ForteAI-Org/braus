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
/// counted, so an animation alone does not hold every action to its cap. `prepare` also starts a watch
/// of the tab's requests (`WebRequests`): the page is not quiet while a fetch, an XMLHttpRequest or a
/// document it started is in flight. The watch ends with `settle`, or at its lifetime when no settle
/// comes; it is started and stopped on its tab's lane, one step at a time, so a stop under way and a
/// new start never cross, and a stop runs to its end even for a caller cancelled. A page that reacts later than `quiet` after it went still with nothing in flight (a timer)
/// is not waited for, and a focused field's value changed to one of the same length is not seen.
///
/// The first read waits one interval, so a page that reacts on the next frame is not judged
/// before it has drawn. The signature is read from the tab's isolated world (`WebTabs.evaluate`).
public struct WebSettler: Settling {

    let tabs    : WebTabs
    let interval: Duration
    let quiet   : Duration
    /// How long a watch of requests lasts past its last `prepare` when no `settle` ends it.
    let lifetime: Duration

    public init(tabs: WebTabs, interval: Duration = .milliseconds(50), quiet: Duration = .milliseconds(150),
                lifetime: Duration = .seconds(10)) {
        self.tabs     = tabs
        self.interval = interval
        self.quiet    = quiet
        self.lifetime = lifetime
    }

    /// Installs, once per document, the observer that counts the page's DOM changes, and starts the watch of the
    /// tab's requests, or keeps the one running for a later gesture of the same action.
    public func prepare(in processID: pid_t) async {
        guard let page = try? tabs.page(for: processID), let lane = tabs.lane(of: processID) else { return }
        _ = try? await tabs.evaluate(Self.observerScript, in: processID, timeoutSeconds: 2)
        let tabs = self.tabs
        let lifetime = self.lifetime
        await lane.run {
            if let running = tabs.requests(of: processID), !running.isClosed {
                running.extend(by: lifetime)
                return
            }
            guard let watch = await WebRequests.start(on: page, lifetime: lifetime) else { return }
            if let replaced = tabs.setRequests(watch, for: processID) {
                await replaced.stop(disabling: replaced === watch)
            }
            watch.attach(expiry: Task { await Self.expire(watch, of: processID, tabs: tabs) })
        }
    }

    /// Settled once the page held still and nothing counted is in flight; capped when the cap came first; unavailable
    /// when the tab is gone, no read of the page answered, or the page held still with no watch of its requests (no
    /// `prepare`, or its `Network.enable` failed): a still DOM alone does not say that no request is on its way.
    @discardableResult
    public func settle(in processID: pid_t, cap: Duration) async -> SettleResult {
        let clock = ContinuousClock()
        let deadline = clock.now + cap
        let watch = tabs.requests(of: processID)
        guard (try? tabs.page(for: processID)) != nil else {
            await Self.end(watch, of: processID, tabs: tabs)
            try? await Task.sleep(until: deadline)
            return .unavailable
        }
        var last: JSONValue?
        var stillSince = clock.now
        var result = SettleResult.unavailable
        while clock.now < deadline {
            try? await Task.sleep(for: min(interval, deadline - clock.now))
            guard !Task.isCancelled else { break }
            let signature = try? await tabs.evaluate(Self.signatureScript, in: processID, timeoutSeconds: 2)
            let now = clock.now
            if signature != nil, result == .unavailable { result = .capped }
            if let signature, signature == last {
                // The watch counted, inline, every request whose start came before this read's answer.
                if now - stillSince >= quiet, signature[0]?.stringValue == "complete", (watch?.inFlight ?? 0) == 0 {
                    result = watch.map { $0.isClosed ? .unavailable : .settled } ?? .unavailable
                    break
                }
            } else {
                last = signature
                stillSince = now
            }
        }
        await Self.end(watch, of: processID, tabs: tabs)
        return result
    }

    /// Stops `watch`, on its tab's lane, when it is still the tab's watch; one already replaced or stopped is left
    /// alone.
    static func end(_ watch: WebRequests?, of processID: pid_t, tabs: WebTabs) async {
        guard let watch, let lane = tabs.lane(of: processID) else { return }
        await lane.run {
            guard tabs.takeRequests(watch, of: processID) else { return }
            await watch.stop(disabling: true)
        }
    }

    /// Ends `watch` at its deadline, which a later `prepare` may move, unless something stopped it before.
    static func expire(_ watch: WebRequests, of processID: pid_t, tabs: WebTabs) async {
        while !watch.isStopped {
            let deadline = watch.deadline
            guard (try? await Task.sleep(until: deadline)) != nil else { return }
            if ContinuousClock.now >= watch.deadline { break }
        }
        await end(watch, of: processID, tabs: tabs)
    }

    /// Counts, on the isolated world's window and out of the DOM, the page's changes: nodes added or removed,
    /// text, and every attribute but `style`.
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
