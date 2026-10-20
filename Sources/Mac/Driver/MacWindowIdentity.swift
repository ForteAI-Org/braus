import ApplicationServices
import Foundation

/// MacWindowIdentity is one window of an app as accessibility knows it: the same window however the app orders
/// `AXWindows`. A scene carries it from its read to every address it makes, and acting refuses when the window at
/// the address's index is not that window (`MacElementAddress.admits`), so a press never lands in another document
/// that holds the same control at the same path.
///
/// A live identity is the `AXUIElement` the read walked, compared with `CFEqual`, the way the focused window is
/// matched in `LiveMacTreeReader.windows(of:)`. A synthetic identity is a token for readers that are not live. The two
/// kinds are never equal to each other, whatever the token says. It is opaque: nothing reads the element back out.
public struct MacWindowIdentity: Sendable, Equatable {

    private enum Source: Sendable, Equatable {
        case live(LiveWindow)
        case synthetic(String)
    }

    private let source: Source

    /// The live identity of `window`, the very element a read walked or an action resolved.
    init(window: AXUIElement) {
        source = .live(LiveWindow(element: window))
    }

    /// A synthetic identity for a reader that is not live, such as a test's fake app.
    public init(synthetic token: String) {
        source = .synthetic(token)
    }
}

/// LiveWindow holds a window's `AXUIElement` for `MacWindowIdentity`. It is `@unchecked Sendable` because the
/// reference is immutable once stored and the only operation made on it is `CFEqual`, which reads the element's
/// identity (its process and remote element id) and sends no message to the app; the accessibility readers already
/// hand these references across threads (`@concurrent`).
private final class LiveWindow: @unchecked Sendable, Equatable {

    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: LiveWindow, rhs: LiveWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
