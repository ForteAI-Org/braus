import Foundation

extension ModelText {
    nonisolated static let toolAnswerTexts: [Entry] = [
        Entry(key: .init(rawValue: "call_dispatcher.batch_failure.v2"), owner: "AutomationMCP", delivery: .toolAnswer(tool: "batch"),
              budgetCharacters: 160, text: "The step failed. Check the current state before continuing.", legacy: false),
        Entry(key: .init(rawValue: "profile.observe_only.v1"), owner: "AutomationMCP",
              delivery: .refusal(tool: "call"), budgetCharacters: 45,
              text: "The session profile permits observation only.", legacy: false),
        Entry(key: .init(rawValue: "profile.memory_not_read.v1"), owner: "AutomationMCP",
              delivery: .toolAnswer(tool: "plan"), budgetCharacters: 40,
              text: "the session profile does not read memory", legacy: false),
        Entry(key: .init(rawValue: "profile.learning_disabled.v1"), owner: "AutomationMCP",
              delivery: .toolAnswer(tool: "memory_task"), budgetCharacters: 46,
              text: "The session profile does not learn from calls.", legacy: false),
        Entry(key: .init(rawValue: "batch.error.v2"), owner: "AutomationMCP", delivery: .toolAnswer(tool: "batch"),
              budgetCharacters: 7, text: "Error: ", legacy: false),
        Entry(key: .init(rawValue: "batch.stopped.v2"), owner: "AutomationMCP", delivery: .toolAnswer(tool: "batch"),
              budgetCharacters: 9, text: "stopped: ", legacy: false),
        Entry(
            key: .init(rawValue: "task_cycle_handler.directory.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 71,
            text: "The stopped task could not be closed because its memory is unavailable.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.draft.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 19,
            text: "Braus stopped task ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.draft.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 53,
            text: " and closed its attempt as abandoned, not completed. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.draft.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 93,
            text: "Begin a new task for the current request, including any remaining work toward the same goal. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.draft.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 102,
            text: "The abandoned task cannot be resumed. Observe current effects first; never repeat an uncertain action.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.candidate.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 38,
            text: "Braus: memory_task answered candidate ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.candidate.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 51,
            text: ", and you did not interpret it, so nothing of that ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.candidate.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 99,
            text: "task is learned. Call memory_task interpret with that candidate now, as its answer describes. Then ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.candidate.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 26,
            text: "reply with one short line.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.interpretNext.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 42,
            text: "Call memory_task interpret with candidate ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.interpretNext.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 50,
            text: " in your next call, before you answer the person: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.interpretNext.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 43,
            text: "until then nothing of this task is learned.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.closeChangedCopies.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 79,
            text: "Before you answer the person: a document this task changed and saved only as a ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.closeChangedCopies.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 102,
            text: "copy (Save a Copy, Export) is still open with the change. Close it now from the File menu (Close) and ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.closeChangedCopies.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 75,
            text: "choose not to save (Don't Save). Leave any other window or prompt as it is.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.error.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 40,
            text: "Braus's memory did not record the task (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.error.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 21,
            text: "). App actions still ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler.error.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 31,
            text: "require the memory; use status.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.directory.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 60,
            text: "This session has no memory: nothing about tasks is recorded.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.current.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 45,
            text: "A task is already open: update it, or end it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.current.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 25,
            text: "before beginning another.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.recorded.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: "already recorded",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.current.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 36,
            text: "Another task is open: end it before ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.current.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 18,
            text: "resuming this one.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.extra.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 73,
            text: "A new attempt began. Observe the present state before acting: nothing of ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.extra.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 32,
            text: "the earlier attempt is replayed.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.calls.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 47,
            text: "A new attempt began. The earlier attempts left ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.calls.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 12,
            text: " without an ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.calls.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 92,
            text: "end: each may have run, or still be running. Observe its effect in the present state before ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.calls.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 74,
            text: "acting, and do not repeat it: nothing of the earlier attempts is replayed.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.summary.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 12,
            text: "no candidate",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.summary.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 46,
            text: "The task's last attempt started no app action.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.completed.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 15,
            text: "already checked",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.completed.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 63,
            text: "The attempt's result was checked before: nothing more was read.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.data.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 14,
            text: "already chosen",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.refusal.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 56,
            text: "The plan was not admitted; nothing was recorded or run: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.error.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 36,
            text: "Braus could not record this choice (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.error.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 15,
            text: "): nothing was ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.error.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 84,
            text: "recorded or delivered, and this call ran no app action. Plan with the current scene ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.error.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 28,
            text: "and tools, or propose again.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.owned.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 51,
            text: "The call is not unresolved in this producer stream.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.fact.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 36,
            text: "The reconciliation was not recorded ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.fact.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: "(",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.fact.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 65,
            text: "): use a successful read of this effect and resource in the same ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.fact.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 91,
            text: "producer and data context. Unsupported or inconclusive evidence leaves the call unresolved.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.used.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 12,
            text: "use recorded",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__answer.answer.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 12,
            text: "no open task",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 29,
            text: "The memory was not searched: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 34,
            text: "The memory could not be searched (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 25,
            text: "); plan with the current ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: "scene and tools.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 29,
            text: "The memory was not searched: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.7"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.8"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 34,
            text: "The memory could not be searched (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.9"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 25,
            text: "); plan with the current ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.error.v1.10"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: "scene and tools.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 84,
            text: " is a proposal, not a query: a use names the query that memory_task choose answered ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 99,
            text: "(recall.query). A proposal you did not choose from has no use to report. This use was not recorded.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 9,
            text: "No query ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 80,
            text: " with that need was made by this attempt: report the query ids recall answered. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 26,
            text: "This use was not recorded.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 17,
            text: "The use of query ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.7"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 19,
            text: " was not recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.noOpenTask.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 85,
            text: "No task is open in this session: begin one, or resume your unfinished task by its id.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.failure.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 38,
            text: "The task cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.failure.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.8"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 8,
            text: "No task ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.9"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 22,
            text: " of yours is recorded.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.10"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 56,
            text: "The attempt is not the task's last one: resume the task.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.11"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 5,
            text: "Task ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.12"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 43,
            text: " belongs to another producer: it cannot be ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.13"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 47,
            text: "read or changed from here. Begin your own task.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.status.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 5,
            text: "Task ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.status.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 10,
            text: " ended as ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.status.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 14,
            text: ": begin a new ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.status.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 23,
            text: "task for a new request.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 5,
            text: "Task ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: " is at revision ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 6,
            text: ", not ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 53,
            text: ": read it again and revise from the current revision.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 39,
            text: "This attempt ended: resume the task to ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 12,
            text: "continue it.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.14"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 13,
            text: "No candidate ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.id.v1.15"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 27,
            text: " of your tasks is recorded.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.7"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 10,
            text: "Candidate ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.8"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 40,
            text: " is not the attempt's latest: interpret ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.current.v1.9"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 33,
            text: ", which covers the later actions.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.revision.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 9,
            text: "Revision ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.revision.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 78,
            text: " of this interpretation was recorded with other statements: omit the revision ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.revision.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 20,
            text: "to record a new one.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.expected.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 44,
            text: "The next revision of this interpretation is ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.expected.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.what.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 68,
            text: "The candidate and its actions have nothing the interpretation names ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 5,
            text: "Step ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 45,
            text: " is not the same operation in both versions (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 15,
            text: "): they do not ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 82,
            text: "share the steps before the divergence you named. Name the first step that differs.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 48,
            text: "The interpretation cannot be recorded as given: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.why.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.resultMissing.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 89,
            text: "No result_check was given, so nothing proves this task's result and its procedure can be ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.resultMissing.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 115,
            text: "admitted only if every step was verified on its own. Give result_check in your interpret call: what Braus can read ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.resultMissing.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 105,
            text: "to verify the result the person asked for ({file_written|file_changed|file_unchanged|file_absent: path}, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.resultMissing.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 162,
            text: "{file_moved|file_copied: path, to: path}, {file: path, contains: text}, {window: title, app, open}, {element: label, value|state|present} while the app's session ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.resultMissing.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 62,
            text: "is open), or {none: why} when the task leaves nothing to read.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.verdict.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 108,
            text: "Only window presence was checked. This does not verify an applied value, a saved change or task completion. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.verdict.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 97,
            text: "Compare with the requested result; read the actual applied state before claiming a value change. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.verdict.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 71,
            text: "A dialog field can retain the last input even when Apply had no effect.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.verdict.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 82,
            text: "These verdicts apply only to the named predicates, not automatically to the goal. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.verdict.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 103,
            text: "A completed outcome is your declaration. Report uncertainty if the requested result is not established.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.answer.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 67,
            text: "added by Braus and shown; it does not admit or refuse the procedure",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.answer.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 33,
            text: "The check could not be recorded: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.answer.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.word.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 74,
            text: "no application was named and no session holds one, so no window was listed",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.running.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 54,
            text: "the name given answers to several running applications",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.windows.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 45,
            text: "the application's windows could not be listed",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.known.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 93,
            text: "Call memory_task interpret with this candidate: labels and outcomes of the procedure, of the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.known.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 102,
            text: "blocks when there are several, and of the steps; the parameters with their roles and values; the uses ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.known.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 75,
            text: "of parameters in steps' arguments as templates. Steps and blocks are fixed.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.answer.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: "already recorded",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.repeats.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 87,
            text: "This task repeated the method of an earlier procedure: this version replaces it in the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.repeats.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 76,
            text: "catalogue, and its steps verified in the earlier run count as verified here.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 24,
            text: "This run repeats source ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 57,
            text: " of the proposal you received without choosing it: it is ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 110,
            text: "counted as followed without a choice. When a source does the very work, choose it first (its readyPlan), then ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 28,
            text: "adapt it and report adapted.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 83,
            text: "The procedure keeps the steps that did the work; the steps in left_out stay in the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "task_cycle_handler__evidence.source.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 54,
            text: "candidate as evidence and are not repeated by a reuse.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "human_step_tool.description.v1"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "human_step"),
            budgetCharacters: 25,
            text: "\nPicture attached (HEIC).",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.CallDispatcher.first.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 7,
            text: "{app: \"",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.CallDispatcher.first.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 3,
            text: "\"}.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.MemoryTaskTool.error.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.MemoryTaskTool.field.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 16,
            text: " has a duplicate",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.MemoryTaskTool.text.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 7,
            text: "output ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.MemoryTaskTool.text.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 14,
            text: " needs a value",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Answer.calls.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 6,
            text: " calls",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Answer.suspended.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 11,
            text: "suspended: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.what.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 3,
            text: "as ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.what.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ".",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.bounds.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 6,
            text: "steps ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.bounds.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: "–",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.fields.v1.fragment.0"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 7,
            text: " (step ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.TaskCycleHandler.Evidence.fields.v1.fragment.2"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "memory_task"),
            budgetCharacters: 1,
            text: ")",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.batch"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "batch"),
            budgetCharacters: 15,
            text: "Batch",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.step"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "batch"),
            budgetCharacters: 22,
            text: "Step {count}",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.unexecuted"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "batch"),
            budgetCharacters: 40,
            text: "First unexecuted step: {count}",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.reason"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 8,
            text: "reason: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.memory"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 8,
            text: "memory: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.keySeparator"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 2,
            text: ": ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.outcomeSeparator"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 3,
            text: " · ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.outcome.open"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 10,
            text: "<outcome>\n",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.outcome.close"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 11,
            text: "\n</outcome>",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.scene.open"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 8,
            text: "<scene>\n",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.scene.close"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 9,
            text: "\n</scene>",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.ampersand"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 1,
            text: "&",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.lessThan"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 1,
            text: "<",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.greaterThan"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 1,
            text: ">",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.escapedAmpersand"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 5,
            text: "&amp;",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.escapedLessThan"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 4,
            text: "&lt;",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.escapedGreaterThan"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 4,
            text: "&gt;",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.rowSeparator"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 1,
            text: "\n",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "answer.surface.v2.blockSeparator"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "observe"),
            budgetCharacters: 2,
            text: "\n\n",
            legacy: false
        ),
    ]
}
