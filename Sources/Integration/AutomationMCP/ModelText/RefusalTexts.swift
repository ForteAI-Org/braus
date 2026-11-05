import Foundation

extension ModelText {
    nonisolated static let refusalTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "call_dispatcher.guidance.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 65,
            text: "Open the application with open_session, then observe.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.guidance.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 25,
            text: "Observe before any retry.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.it.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 61,
            text: "Braus's memory cannot represent this call, so it was not run.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.it.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 74,
            text: "This call was not recorded: Braus's memory cannot represent its arguments.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.value.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 28,
            text: "This call was not recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.value.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.notice.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 36,
            text: "Part of this call was not recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.notice.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.notice.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 36,
            text: "Part of this call was not recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.notice.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.noSession.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 80,
            text: "This call needs an open session and none is open, so nothing was done. Open one ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.noSession.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 35,
            text: "with open_session, then call again.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.unconfirmed.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 62,
            text: "Braus's memory did not confirm this call before it could act (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.unconfirmed.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 24,
            text: "), so nothing was done. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.unconfirmed.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 100,
            text: "Braus records every action before taking it; use status, and try again once the memory is available.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.suspended.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 62,
            text: "The action ran, but Braus's memory could not save its record (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.suspended.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 46,
            text: "). Do not repeat the action: observe instead. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.suspended.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 56,
            text: "Braus takes no further action until the record is saved.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.hold.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 141,
            text: "Not run: another write in this producer context is running, or its coordination lock is unavailable. Wait for it to finish; nothing was sent.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 25,
            text: "Not run: it repeats call ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 29,
            text: ", whose effect is not known (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 8,
            text: "). Read ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 164,
            text: "whether it happened. Read the affected resource with its adapter, then find reconcile_call and use the read's recorded_call as evidence; nothing was sent.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.5"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 30,
            text: "Not run: it acts on what call ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.6"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 52,
            text: " reached, whose effect is not known. Read it first, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.repeats.v1.7"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 106,
            text: "then find reconcile_call and use the adapter read's recorded_call as evidence; nothing was sent.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.value.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 10,
            text: "Not run: '",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.value.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 91,
            text: "' is an identifier another run produced, and nothing in this run read or named it. Read it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.value.v1.5"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 83,
            text: "in this run (or name it as an input of the task) before using it; nothing was sent.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.values.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 23,
            text: "Invalid tool arguments.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.allowed.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 22,
            text: "Unknown tool argument.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.key.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 31,
            text: "A required argument is missing.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.id.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 90,
            text: "No current session. Open the application with open_session, then observe.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.first.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 64,
            text: " is not running, so it has no window: open it with open_session ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.listing.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 44,
            text: " more not listed; pass a query to find them.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.verb.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 65,
            text: "The adapter failed; its confidential error details were withheld.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.content.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 28,
            text: "named must be true or false.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.id.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 69,
            text: "The person took control after the session opened. No scene was read. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.id.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 57,
            text: "Observe this session after control returns before acting.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.id.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 27,
            text: "full must be true or false.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seconds.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 23,
            text: "Invalid tool arguments.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.rows.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 28,
            text: "batch requires 1...20 steps.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.gap.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 13,
            text: "Part of step ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.gap.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 19,
            text: " was not recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.gap.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.child.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 46,
            text: "This step was not run. Earlier effects remain.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.guidance.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 89,
            text: "Earlier effects remain. Open the application with open_session, then observe.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.guidance.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 62,
            text: "Earlier effects remain. Observe before deciding the next step.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.result.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 27,
            text: "Application session closed.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.warning.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 27,
            text: "Application session closed.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.warning.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 14,
            text: "Unknown tool: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.adapters.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "unknown"),
            budgetCharacters: 83,
            text: "App adapters are not enabled in this Braus: open the app with open_session instead.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool.human_step.v1.refusal"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "human_step"),
            budgetCharacters: 89,
            text: "Use one of steps (1 or 3-5, at most 20), diff (window § ID or number), or picture (step).",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool.canvas.v1.refusal"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 79,
            text: "canvas needs id from the scene (canvas 2 or canvas2), and optional zoom 1 or 2.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "canvas_tool.history.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 54,
            text: "No canvas history. Observe the held Seat window first.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "canvas_tool.unknown.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 18,
            text: "Unknown canvas id ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "canvas_tool.unknown.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 41,
            text: ". Use an id from the last observed scene.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "canvas_tool.privacy.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 90,
            text: "Canvas privacy refusal: the crop touches a secure or withheld field. No pictures returned.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "canvas_tool.pixels.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 71,
            text: "No retained pixels for this canvas. Observe the held Seat window first.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.canvasSession.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 42,
            text: "No held Seat window. Open a session first.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.canvasHistory.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "canvas"),
            budgetCharacters: 61,
            text: "No canvas history for the held Seat window. Observe it first.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.object.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 27,
            text: "arguments must be an object",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.allowed.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 16,
            text: "unknown argument",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.operation.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: "operation must be one of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.propose.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 39,
            text: "recall_mode is propose, the only search",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.goal.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 18,
            text: "begin needs a goal",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.whole.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 62,
            text: "revision must be a whole number from 1, within 64-bit integers",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.outcome.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 48,
            text: "end needs outcome completed, failed or abandoned",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.checks.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 36,
            text: "result_check is for a completed task",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.task.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 24,
            text: "resume needs the task id",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.task.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 27,
            text: "candidate needs the task id",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.secrets.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 29,
            text: "interpret needs the candidate",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.reason.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 91,
            text: "recall needs reason request_changed, input_changed, new_need or path_unusable: the initial ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.reason.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 23,
            text: "search is made by begin",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.uses.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 34,
            text: "use needs [{query, need, outcome}]",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.finding.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 90,
            text: "reconcile needs call, finding (happened, not_happened or unknown) and evidence, the id of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.finding.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 35,
            text: "a later completed call that read it",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.error.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 38,
            text: "The task cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.error.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.error.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 48,
            text: "The interpretation cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.field.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 9,
            text: " is empty",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.field.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 12,
            text: " is too long",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.field.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 19,
            text: "there are too many ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.field.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 16,
            text: " is out of range",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.of.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 13,
            text: "the steps of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.of.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 36,
            text: " do not follow the candidate's order",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.of.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 34,
            text: "the blocks are not the candidate's",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.of.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 16,
            text: "it names no step",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.candidate.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 29,
            text: "interpret needs the candidate",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 48,
            text: "an outcome is completed, failed or not_completed",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.bounds.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 63,
            text: " is not a part: procedure, b1, b2, …, s1, s2, … or a phase f2-5",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.integer.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: " is a whole number from 1",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.word.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: "every part names its part",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.from.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 20,
            text: "a phase's first step",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.from.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 19,
            text: "a phase's last step",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.from.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 51,
            text: "a phase runs from a step to the same or a later one",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.role.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 37,
            text: "every parameter has a name and a role",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 26,
            text: "unknown kind of parameter ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 21,
            text: "unknown direction of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 18,
            text: "unknown source of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.template.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 41,
            text: "every use names its argument and template",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.integer.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 41,
            text: "a use's position is a whole number from 0",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.proposal.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: "choose needs the proposal",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 75,
            text: "choose needs plan [{need, tracts [{source, from, to}], covered, uncovered}]",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.integer.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: " is a whole number from 1",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.need.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 14,
            text: "a planned need",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.covered.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 5,
            text: "need ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.covered.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 41,
            text: ": covered is all, part, none or ambiguous",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.list.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 5,
            text: "need ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.list.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 2,
            text: ": ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.list.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 32,
            text: " is a list of {source, from, to}",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.source.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 5,
            text: "need ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.source.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 30,
            text: ": every tract names its source",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.value.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 5,
            text: "need ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.value.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 2,
            text: ": ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.value.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 12,
            text: " is too long",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 32,
            text: "needs must be a list of at most ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 12,
            text: " {text, app}",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.text.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 21,
            text: "every need has a text",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 44,
            text: "use must be a list of {query, need, outcome}",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.query.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 25,
            text: "every use names its query",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.whole.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 37,
            text: "a use's need is a whole number from 1",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.outcome.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 63,
            text: "a use's outcome is followed, adapted, abandoned or not_executed",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.cause.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 69,
            text: "a use's cause is method, driver, application, agent, input or unknown",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.5"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 35,
            text: "result_check names at most 8 checks",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.expanded.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 41,
            text: "a result check's file is an absolute path",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.fields.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 31,
            text: "every result check is an object",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.to.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 30,
            text: " needs to, the path it reached",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.state.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 38,
            text: "an element's state is on, off or mixed",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.reason.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 107,
            text: "a result check is one of file_written, file_changed, file_unchanged, file_absent, file_moved, file_copied, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.reason.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 45,
            text: "file (with contains), window, element or none",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.invalidInterpretation.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 48,
            text: "The interpretation cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.invalidInterpretation.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.6"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 15,
            text: " must be a list",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.name.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 24,
            text: "every value needs a name",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.allowed.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 23,
            text: "unknown field of value ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1.5"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 24,
            text: "unknown source of value ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.known.v1.6"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 22,
            text: "unknown kind of value ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.text.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 13,
            text: "the value of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.text.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 13,
            text: " must be text",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.items.v1.7"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 24,
            text: " must be a list of texts",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.text.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 24,
            text: " must be a list of texts",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.invalid.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 38,
            text: "The task cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.invalid.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.needLimit.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "memory_task"),
            budgetCharacters: 7,
            text: "{count}",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_text_policy.unanswered.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 65,
            text: "No scene of this session has been answered yet: observe it first.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_text_policy.stale.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 79,
            text: "A call may have changed the application since its last scene: observe it first.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.section.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 31,
            text: "Pass section or full, not both.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.section.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 52,
            text: "section must be the title of a section of the scene.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_answer_budget.titles.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 22,
            text: "No section is titled \"",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_answer_budget.titles.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 20,
            text: "\". The sections are ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_answer_budget.titles.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 1,
            text: ".",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_answer_budget.pages.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 9,
            text: "Section \"",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "scene_answer_budget.pages.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "observe"),
            budgetCharacters: 22,
            text: "\" has {count} page(s).",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 21,
            text: "Braus could not hold ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1.2"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 35,
            text: " on the seat, so nothing was done: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1.3"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 13,
            text: "Braus opened ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1.4"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 50,
            text: " but the seat does not hold it (the session holds ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1.5"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 7,
            text: "nothing",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "call_dispatcher.seat.v1.6"),
            owner: "AutomationMCP",
            delivery: .refusal(tool: "app_call"),
            budgetCharacters: 23,
            text: "), so nothing was done.",
            legacy: false
        ),
    ]
}
