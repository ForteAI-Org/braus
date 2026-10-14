import AutomationRuntime
import AppKit
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SeatBroker
import SeatCore
import SeatSession
import WindowServerListing

/// BatchCommand owns one brokered session for a sequence in the requested window (`BrokeredSeat`). Each
/// step perceives again. A lost or changed target stops the sequence instead of acting on its parent. The
/// sequence is recorded as one batch with its steps (`CommandLineBatch`).
enum BatchCommand {

    static func run(_ invocation: Invocation) async throws {
        let plan = try BatchPlan(arguments: invocation.arguments)
        let application = try ApplicationLookup.running(plan.application)
        let processID = application.processIdentifier
        let bundleID = application.bundleIdentifier ?? "pid.\(processID)"
        let knowledge = Runtime.knowledgeDirectory(plan.invocation)
        try await BrokeredSeat.withSession(
            application,
            plan.invocation,
            knowledge: knowledge,
            recorder : Runtime.commandLineRecorder(knowledge: knowledge)
        ) { desktop, _ in
            guard let original = desktop.heldSeat?.currentTarget else {
                let name = application.localizedName ?? "?"
                throw UsageError.noSuchApplication("\(name): no window was opened on the Seat")
            }
            // One recorded batch, each step a call of its own at its position.
            let parent   = Runtime.commandLineRecorder(knowledge: knowledge)
            let children = plan.steps.indices.map {
                Runtime.recorder(knowledge: knowledge, context: parent.context.child($0))
            }
            try await CommandLineBatch.run(
                plan.steps,
                app     : AppContextIdentity(bundleID: bundleID),
                parent  : parent,
                children: children,
                prepare : { number, step in
                    let windows = try WindowServerWindowListing().windows(ownedBy: processID)
                    guard let seat = desktop.heldSeat, seat.state == .ready, seat.currentTarget?.id == original.id,
                          windows.contains(where: { $0.number == original.id }) else {
                        throw UsageError.invalid(
                            option  : "window",
                            value   : original.title,
                            expected: "the original batch window still available in a ready Seat"
                        )
                    }
                    print("batch: step \(number)/\(plan.steps.count): \(step.summary)")
                },
                perform : { number, step, recorder in
                    switch step {
                        case .select(let control, let item):
                            let directory = plan.invocation.options["evidence"].map {
                                ($0 as NSString).appendingPathComponent("step-\(number)")
                            }
                            return try await SelectCommand.perform(
                                control: control,
                                item: item,
                                bundleID: bundleID,
                                desktop: desktop,
                                invocation: plan.invocation,
                                recorder: recorder,
                                begun: true,
                                evidenceDirectory: directory
                            )
                        case .act(let action):
                            let request = ActionRequest(
                                processID: processID,
                                bundleID: bundleID,
                                appName: application.localizedName ?? "pid \(processID)",
                                target: action.target,
                                verb: action.verb,
                                section: action.section,
                                desiredState: action.desiredState
                            )
                            return try await ActCommand.perform(request, recorder: recorder, begun: true) {
                                try await ActCommand.brokered(request, on: desktop, recorder: $0)
                            }
                    }
                }
            )
            print("batch: completed \(plan.steps.count)/\(plan.steps.count) steps")
        }
    }
}
