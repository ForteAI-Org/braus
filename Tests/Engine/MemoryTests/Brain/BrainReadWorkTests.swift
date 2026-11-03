import Foundation
import EngineCore
@testable import Memory
import PerceptionCore
import Testing
import Synchronization
import Dispatch

struct BrainReadWorkTests {
    private func brain() -> UIBrain {
        UIBrain(objects: (0..<1000).map { i in
            ObjectAnchor(anchorKey: "a\(i)", kind: .control, label: "Open",
                         boundsTypical: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                         firstSeen: .distantPast, lastSeen: .distantPast)
        })
    }

    @Test func stopDuringColdIndexBuild() {
        let control = BrainReadControl()
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try BrainIndex(brain(), checking: {
                checks += 1
                if checks == 12 { control.requestStop() }
                try control.check()
            })
        }
        #expect(checks == 12)
    }

    @Test func stopDuringColdProjectionBuild() {
        let control = BrainReadControl()
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try BrainProjection(brain(), checking: {
                checks += 1
                if checks == 12 { control.requestStop() }
                try control.check()
            })
        }
        #expect(checks == 12)
    }

    @Test func stopDuringMatchingStopsCounter() {
        let brain = brain()
        let index = BrainIndex(brain)
        let detection = BrainDetection(kind: .control, label: "Open",
                                       bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let control = BrainReadControl()
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try BrainMatcher.match(detection, in: brain, index: index, checking: {
                checks += 1
                if checks == 12 { control.requestStop() }
                try control.check()
            })
        }
        #expect(checks == 12)
    }

    @Test func stoppedWorkerActuallyFinishes() async {
        let control = BrainReadControl()
        let entered = Mutex(false)
        let finished = Mutex(false)
        let checks = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        let brain = brain()
        let worker = Task {
            defer { finished.withLock { $0 = true } }
            do {
                _ = try BrainIndex(brain, checking: {
                    let count = checks.withLock { $0 += 1; return $0 }
                    if count == 12 {
                        entered.withLock { $0 = true }
                        release.wait()
                    }
                    try control.check()
                })
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record(error)
                return false
            }
        }
        while !entered.withLock({ $0 }) { await Task.yield() }
        control.requestStop()
        release.signal()
        #expect(await worker.value)
        #expect(finished.withLock { $0 })
        #expect(checks.withLock { $0 } == 12)
    }

    @Test func noStopPreservesResults() throws {
        let brain = brain()
        let control = BrainReadControl()
        let index = try BrainIndex(brain, checking: control.check)
        for label in ["Open", "Other", ""] {
            let detection = BrainDetection(kind: .control, label: label,
                                           bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
            #expect(try BrainMatcher.match(detection, in: brain, index: index, checking: control.check)
                    == BrainMatcher.match(detection, in: brain))
        }
    }
}
