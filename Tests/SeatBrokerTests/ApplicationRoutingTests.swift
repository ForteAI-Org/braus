import Foundation
import TaskRouting
import Testing
@testable import SeatBroker

/// A name in the person's language reaches the router as the bundle id `open` resolves it to, so it routes as the
/// app's own name does.
@Suite("The resolver feeds the task router")
struct ApplicationRoutingTests {

    private static func app(_ name: String, _ bundleID: String, bundleName: String? = nil) -> TargetApp {
        TargetApp(pid: nil, bundleID: bundleID, name: name,
                  bundleURL: URL(fileURLWithPath: "/Applications/\(bundleName ?? name).app"), windows: [],
                  bundleName: bundleName)
    }

    private static let installed = [
        app("Calendario", "com.apple.iCal", bundleName: "Calendar"),
        app("Promemoria", "com.apple.reminders", bundleName: "Reminders"),
        app("Calendar Pro", "com.example.CalendarPro"),
    ]

    @Test("a localized name and the app's own name resolve to one bundle id, which routes to its adapter",
          arguments: [("Calendario", "calendar"), ("Calendar", "calendar"), ("promemoria", "reminders"),
                      ("Reminders.app", "reminders")])
    func localizedNameRoutes(name: String, adapter: String) async throws {
        let bundleID = try ApplicationOpening.resolve(name, in: Self.installed).bundleID
        let decision = await TaskRouter().route(opening: name, bundleID: bundleID, named: false) { _ in .ready }
        guard case .use(.adapter(let routed), _) = decision else {
            Issue.record("\(name) (\(bundleID)) was not routed")
            return
        }
        #expect(routed == adapter)
    }

    @Test("a third party's app whose name contains a routed one's resolves to itself and opens as asked")
    func thirdPartyOpens() async throws {
        let bundleID = try ApplicationOpening.resolve("Calendar Pro", in: Self.installed).bundleID
        #expect(bundleID == "com.example.CalendarPro")
        #expect(await TaskRouter().route(opening: "Calendar Pro", bundleID: bundleID, named: false) { _ in .ready }
                == .open(note: nil))
    }
}
