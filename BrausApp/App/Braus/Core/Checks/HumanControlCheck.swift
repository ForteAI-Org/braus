//
//  HumanControlCheck.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import SeatBroker

/// HumanControlCheck shows the human control overlay on its own, with no app lent and no workspace
/// opened, when the app is launched with BRAUS_CONTROL_CHECK=1, so it can be looked at by eye.
/// BRAUS_CONTROL_CHECK_SHAPE names the mascot's shape (`WorkerShape`'s case name; hexagon otherwise).
/// BRAUS_CONTROL_CHECK_IDLE=<seconds> first lets the worker settle, then prints the process's CPU over
/// that many idle seconds: the overlay's own cost at rest, without the window server's compositing.
/// BRAUS_CONTROL_CHECK_SHOWCASE=1 makes the worker ponder and chuckle from its first seconds
/// (`WorkerBehaviour.showcase`) and glance at the marked frame once, instead of watching calmly.
/// Hovering Yes and No shows the looks, and answering them the reactions.
///
/// The mascot floats at the top-right corner of the screen under the pointer at launch
/// (`PersonScreen`) and a border marks a window-sized frame in the middle of that screen. Click the
/// mascot and answer Yes: the exit plays. The overlay then comes back and asks with a 10 s countdown;
/// once it ends, the check prints the answer and quits.
@MainActor
enum HumanControlCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["BRAUS_CONTROL_CHECK"] == "1" }

    static func runAndQuit() async {
        let environment = ProcessInfo.processInfo.environment
        let shape       = environment["BRAUS_CONTROL_CHECK_SHAPE"].flatMap(WorkerShape.init(rawValue:)) ?? .hexagon
        let showcases   = environment["BRAUS_CONTROL_CHECK_SHOWCASE"] == "1"
        let overlay     = HumanControlOverlay(
            worker   : HouseWorker(
                id        : UUID(),
                name      : "Atlas",
                status    : .free,
                activity  : "",
                role      : "",
                shape     : shape,
                badge     : nil,
                usesScreen: true
            ),
            behaviour: showcases ? .showcase : .watching
        )
        guard let screen = PersonScreen.current() else {
            FileHandle.standardError.write(Data("control check: no screen but a Seat's\n".utf8))
            exit(1)
        }
        let border  = ControlWindowBorder()
        let visible = screen.visibleFrame
        let marked  = CGRect(
            x     : visible.midX - 450,
            y     : visible.midY - 280,
            width : 900,
            height: 560
        )
        border.show(frame: marked)

        overlay.show(on: screen)
        if showcases {
            Task {
                try? await Task.sleep(for: .seconds(8))
                overlay.lookToward(screenFrame: marked)
            }
        }
        if let seconds = environment["BRAUS_CONTROL_CHECK_IDLE"].flatMap(Double.init), seconds > 0 {
            // The entrance and the room's first renders and bakes are over well within this.
            try? await Task.sleep(for: .seconds(5))
            let share = await idleCPU(over: seconds)
            print(String(format: "control check: idle CPU %.2f%% of one core over %.0f s", share, seconds))
        }
        print("control check: click the mascot and answer Yes")
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            overlay.onFinishRequested = { finished.resume() }
        }
        overlay.onFinishRequested = nil
        print("control check: finish requested after the exit")

        try? await Task.sleep(for: .seconds(1))
        let answer = await overlay.askBeforeTakingBack(seconds: LendActivity.countdown)
        print("control check: the countdown ended with \(answer)")
        overlay.hide(animated: true)
        try? await Task.sleep(for: .seconds(1.5))
        border.hide()
        exit(0)
    }

    /// The share of one core the process used over the next `seconds`, in percent.
    static func idleCPU(over seconds: Double) async -> Double {
        func used() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user   = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return user + system
        }
        let start = (cpu: used(), wall: Date())
        try? await Task.sleep(for: .seconds(seconds))
        return 100 * (used() - start.cpu) / Date().timeIntervalSince(start.wall)
    }
}
