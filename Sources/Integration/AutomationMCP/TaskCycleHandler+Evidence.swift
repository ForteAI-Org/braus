import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

extension TaskCycleHandler {
    /// Whether a store error is a refusal of a choice's own record (a check of the archive, an identity, a lock or a wait
    /// inside the store) rather than the memory being unusable, which stays `memory_unavailable`.
    static func isChoiceRecordFault(_ error: MemoryStoreError) -> Bool {
        switch error {
            case .contract, .identity, .locked, .contention, .malformedText: true
            case .open, .schema, .failed, .snapshot, .unavailable, .cancelled: false
        }
    }

    /// Runs a query of the Recall for the open task and answers it as the agent reads it, under `recall`; a query
    /// the memory cannot run answers `recall_error`, and the task's declaration stays recorded.
    func recall(_ reason: RecallReason, _ plan: MemoryTaskTool.RecallPlan, content: TaskRevisionContent, task: OpenTask,
                        producer: TaskProducer, memory: MemoryService) async -> [String: JSONValue] {
        let service = RecallService.shared(for: memory)
        await service.schedule()
        do {
            let (needs, notes) = try await resolved(plan.needs, service: service)
            let request = try RecallRequest(taskID: task.taskID, attemptID: task.attemptID, revision: task.revision, reason: reason,
                                            remainingWork: plan.remaining ?? content.goal, needs: needs,
                                            values: content.inputs, constraints: content.constraints, notes: notes)
            let answer = try await service.recall(request, producer: producer)
            let data = try JSONEncoder().encode(answer.delivery)
            return ["recall": try JSONDecoder().decode(JSONValue.self, from: data)]
        } catch let error as TaskContextError {
            return ["recall_error": .string("The memory was not searched: \(error).")]
        } catch {
            return ["recall_error": .string("The memory could not be searched (\(MemoryService.describe(error))); plan with the current "
                                            + "scene and tools.")]
        }
    }

    /// Searches for a proposal of the experiment of the agent's choice and answers its text under `recall_proposal`; a
    /// search the memory cannot run answers `recall_error`, and the task's declaration stays recorded.
    func propose(_ reason: RecallReason, _ plan: MemoryTaskTool.RecallPlan, content: TaskRevisionContent, task: OpenTask,
                         producer: TaskProducer, memory: MemoryService) async -> [String: JSONValue] {
        let service = RecallService.shared(for: memory)
        await service.schedule()
        do {
            let (needs, notes) = try await resolved(plan.needs, service: service)
            let request = try RecallRequest(taskID: task.taskID, attemptID: task.attemptID, revision: task.revision, reason: reason,
                                            remainingWork: plan.remaining ?? content.goal, needs: needs,
                                            values: content.inputs, constraints: content.constraints, notes: notes)
            let answer = try await service.propose(request, producer: producer)
            let data = try JSONEncoder().encode(answer.delivery)
            return ["recall_proposal": try JSONDecoder().decode(JSONValue.self, from: data)]
        } catch let error as TaskContextError {
            return ["recall_error": .string("The memory was not searched: \(error).")]
        } catch {
            return ["recall_error": .string("The memory could not be searched (\(MemoryService.describe(error))); plan with the current "
                                            + "scene and tools.")]
        }
    }

    /// The needs with the applications they name resolved to bundle IDs (`RecallApplications`), before anything filters,
    /// selects or records them, and the notes of those that could not be resolved. The applications are the learned parts'
    /// and those the session offers the `apps` tool for each word named, asked once per word; nothing is opened.
    private func resolved(_ needs: [RecallNeed], service: RecallService) async throws -> ([RecallNeed], [String]) {
        let words = Set(needs.compactMap(\.bundleID))
        guard !words.isEmpty else { return (needs, []) }
        let learned = await service.learnedApplications()
        var offered: [ApplicationCandidate] = []
        for word in words.sorted() { offered += (try? await session.applications(matching: word)) ?? [] }
        let resolution = try RecallApplications.resolving(needs, among: RecallApplications.known(learned: learned, offered: offered))
        return (resolution.needs, resolution.notes)
    }

    /// Records the agent's declared uses of the selections it received; answers how many were recorded.
    /// Records each use the agent reported, and answers how many were recorded and why each other one was not. A use
    /// that names no query of the attempt is answered, never what keeps the checkpoint or the end from being recorded:
    /// thrown, it left the task open, then abandoned with nothing learned (review U2, 14 October 2026).
    func report(_ uses: [MemoryTaskTool.UseReport], task: OpenTask, memory: MemoryService) async -> (recorded: Int, problems: [String]) {
        let service = RecallService.shared(for: memory)
        var recorded = 0
        var problems: [String] = []
        for use in uses {
            do {
                try await service.report(queryID: use.queryID, attemptID: task.attemptID, needPosition: use.needPosition,
                                         declared: use.declared, cause: use.cause, note: use.note)
                recorded += 1
            } catch RecallUseError.unknownQuery(let id) {
                // A proposal's id is no query's (live run R01): say which id a use names, and that nothing was recorded.
                if await service.isProposal(id, of: task.taskID) {
                    problems.append("\(id) is a proposal, not a query: a use names the query that memory_task choose answered "
                                    + "(recall.query). A proposal you did not choose from has no use to report. This use was not recorded.")
                } else {
                    problems.append("No query \(id) with that need was made by this attempt: report the query ids recall answered. "
                                    + "This use was not recorded.")
                }
            } catch {
                problems.append("The use of query \(use.queryID) was not recorded: \(MemoryService.describe(error))")
            }
        }
        return (recorded, problems)
    }

    /// Links the attempt's calls to the steps the Recall delivered to it and answers what each selection was used
    /// for, or nil when it received none.
    func linked(_ task: OpenTask, producer: TaskProducer, memory: MemoryService) async -> JSONValue? {
        // The facts a link reads are derived after each call: let the queue write them, within a short budget.
        _ = await memory.flush(within: .seconds(2))
        guard let summaries = try? await RecallService.shared(for: memory).link(attemptID: task.attemptID, taskID: task.taskID,
                                                                                 producer: producer),
              !summaries.isEmpty else { return nil }
        return .array(summaries.map { summary in
            .object([
                "query": .string(summary.queryID), "need": .number(Double(summary.needPosition + 1)),
                "tract": summary.tract.map { .number(Double($0 + 1)) } ?? .null,
                "steps_carried_out": .array(summary.executed.map { .number(Double($0 + 1)) }),
                "verified": .array(summary.confirmed.map { .number(Double($0 + 1)) }),
                "not_carried_out": .array(summary.notExecuted.map { .number(Double($0 + 1)) }),
                "own_operations": .number(Double(summary.ownOperations)),
                "undetermined": .number(Double(summary.undetermined)),
            ])
        })
    }

    static let noOpenTask = MemoryTaskTool.Failure(
        code   : "no_open_task",
        message: "No task is open in this session: begin one, or resume your unfinished task by its id."
    )

    static func failure(of error: TaskContextError) -> MemoryTaskTool.Failure {
        switch error {
            case .invalid:
                return MemoryTaskTool.Failure(
                    code   : "invalid_task",
                    message: "The task cannot be recorded as given: \(error)."
                )
            case .unknownTask(let id):
                return MemoryTaskTool.Failure(code: "unknown_task", message: "No task \(id) of yours is recorded.")
            case .unknownAttempt:
                return MemoryTaskTool.Failure(
                    code   : "unknown_task",
                    message: "The attempt is not the task's last one: resume the task."
                )
            case .foreignTask(let id):
                return MemoryTaskTool.Failure(
                    code   : "foreign_task",
                    message: "Task \(id) belongs to another producer: it cannot be "
                        + "read or changed from here. Begin your own task."
                )
            case .closed(let id, let status):
                return MemoryTaskTool.Failure(
                    code   : "task_closed",
                    message: "Task \(id) ended as \(status.rawValue): begin a new "
                        + "task for a new request."
                )
            case .staleRevision(let id, let expected, let current):
                return MemoryTaskTool.Failure(
                    code   : "stale_revision",
                    message: "Task \(id) is at revision \(current), not "
                        + "\(expected): read it again and revise from the current revision.",
                    details: ["current_revision": .number(Double(current))]
                )
            case .attemptNotRunning:
                return MemoryTaskTool.Failure(
                    code   : "attempt_not_running",
                    message: "This attempt ended: resume the task to "
                        + "continue it."
                )
        }
    }

    static func failure(of error: ProcedureError) -> MemoryTaskTool.Failure {
        switch error {
            case .unknownCandidate(let id):
                return MemoryTaskTool.Failure(code: "unknown_candidate", message: "No candidate \(id) of your tasks is recorded.")
            case .staleCandidate(let id, let current):
                return MemoryTaskTool.Failure(
                    code   : "stale_candidate",
                    message: "Candidate \(id) is not the attempt's latest: interpret \(current), which covers the later actions.",
                    details: ["current_candidate": .string(current)]
                )
            case .conflictingInterpretation(_, let revision):
                return MemoryTaskTool.Failure(
                    code   : "interpretation_conflict",
                    message: "Revision \(revision) of this interpretation was recorded with other statements: omit the revision "
                        + "to record a new one."
                )
            case .revisionOutOfOrder(_, let expected):
                return MemoryTaskTool.Failure(code: "revision_out_of_order",
                                              message: "The next revision of this interpretation is \(expected).",
                                              details: ["next_revision": .number(Double(expected))])
            case .unknownReference(let what):
                return MemoryTaskTool.Failure(code: "unknown_reference",
                                              message: "The candidate and its actions have nothing the interpretation names "
                                                + "as \(what).")
            case .contradictedPrefix(let step, let why):
                return MemoryTaskTool.Failure(code: "contradicted_prefix",
                                              message: "Step \(step + 1) is not the same operation in both versions (\(why)): they do not "
                                                + "share the steps before the divergence you named. Name the first step that differs.",
                                              details: ["step": .number(Double(step + 1))])
            default:
                return MemoryTaskTool.Failure(code: "invalid_interpretation",
                                              message: "The interpretation cannot be recorded as given: "
                                                + "\(MemoryTaskTool.words(error)).")
        }
    }

    /// What the end of a completed task that named no result is told: how to name it with the interpretation.
    static let resultMissing = "No result_check was given, so nothing proves this task's result and its procedure can be "
        + "admitted only if every step was verified on its own. Give result_check in your interpret call: what Braus can read "
        + "to verify the result the person asked for ({file_written|file_changed|file_unchanged|file_absent: path}, "
        + "{file_moved|file_copied: path, to: path}, {file: path, contains: text}, {window: title, app, open}, {element: label, value|state|present} while the app's session "
        + "is open), or {none: why} when the task leaves nothing to read."

    /// The disk as the task's inputs that name an absolute path stood when it declared them, by path, from the call's own
    /// arguments (a value the record withholds is still read, in memory only): what a check of a file changed, kept or
    /// removed compares with. Secret inputs are not read. Read only.
    ///
    /// On the concurrent pool: each file is hashed up to `ProcedureProducer.digestLimit`.
    @concurrent
    nonisolated static func fingerprints(of inputs: JSONValue) async -> [String: TaskResultCheck.FileFacts] {
        var found: [String: TaskResultCheck.FileFacts] = [:]
        for input in inputs.array ?? [] where input["secret"].bool != true {
            guard let text = input["value"].string else { continue }
            let path = ((text as NSString).expandingTildeInPath as NSString).standardizingPath
            guard path.hasPrefix("/"), !path.contains("\n"), FileManager.default.fileExists(atPath: path) else { continue }
            found[path] = ProcedureProducer.read(path: path)
            // The folder a file input lies in is listed too: where a task saves beside its input.
            let folder = (path as NSString).deletingLastPathComponent
            if found[path]?.listing == nil, found[folder] == nil { found[folder] = ProcedureProducer.read(path: folder) }
        }
        return found
    }

    /// A completed task's checks as Braus records them, with what it reads on disk itself added (14 October 2026, after
    /// test runs where agents checked «Saved: <path>» on screen, or gave `none`, for files Braus could read):
    /// - a file the screen checks name by an absolute path (a status bar's «Salvato: /…/lavoro_A.png») is read too: changed
    ///   when it was a file input Braus read at the start, written otherwise;
    /// - every file the outputs declare by an absolute path is checked written;
    /// - the guards (`guards`), recorded as guards: shown, never what admits or refuses a procedure (14 October 2026: a
    ///   stray temporary file of TextEdit's save kept a right procedure out).
    static func completed(_ named: [MemoryTaskTool.ResultCheck], fingerprints: [String: TaskResultCheck.FileFacts], outputs: JSONValue,
                          minimization: ValueMinimization) -> [MemoryTaskTool.ResultCheck] {
        var checks = named
        func onDisk() -> Set<String> {
            Set(checks.flatMap { check -> [String] in
                switch check.read {
                    case .fileMoved(let from, let to), .fileCopied(let from, let to): [from, to]
                    default: check.read.path.map { [$0] } ?? []
                }
            })
        }
        func add(_ read: TaskResultCheck.Expectation) {
            guard let path = read.path, !onDisk().contains(path) else { return }
            checks.append(MemoryTaskTool.ResultCheck(read: read, kept: MemoryTaskTool.kept(read, by: minimization)))
        }
        for check in named {
            switch check.read {
                case .window, .element:
                    for path in Self.paths(in: check.read.texts) where fingerprints[path] != nil || FileManager.default.fileExists(atPath: path) {
                        var isFolder: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
                        add(fingerprints[path]?.exists == true ? .fileChanged(path: path) : .fileWritten(path: path))
                    }
                default: break
            }
        }
        for output in MemoryTaskTool.declaredFiles(outputs, minimization: minimization) { add(output.read) }
        // A folder listed at the start that the task wrote in holds no new file but those named.
        let written = onDisk().union((outputs.array ?? []).compactMap { item in
            item["value"].string.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        })
        for (folder, facts) in fingerprints.sorted(by: { $0.key < $1.key }) where facts.listing != nil {
            let named = written.filter { ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent }
            guard !named.isEmpty else { continue }
            let read = TaskResultCheck.Expectation.noOtherFiles(folder: folder, named: named.sorted())
            checks.append(MemoryTaskTool.ResultCheck(read: read, kept: MemoryTaskTool.kept(read, by: minimization), isGuard: true))
        }
        return checks + Self.guards(for: checks, fingerprints: fingerprints, outputs: outputs, minimization: minimization)
    }

    /// The absolute paths written in texts (a home-relative one expanded), standardized, without trailing punctuation.
    static func paths(in texts: [String]) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?:~|/)[^\s"'«»<>|,;]+"#) else { return [] }
        var found: [String] = []
        for text in texts {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                var path = String(text[range])
                while let last = path.last, ".:)]".contains(last) { path.removeLast() }
                path = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
                if path.hasPrefix("/"), path.count > 1, !found.contains(path) { found.append(path) }
            }
        }
        return found
    }

    /// The guards Braus adds to a completed task's checks: every file input it read at the beginning (a regular file whose
    /// content it read) and that no check or output names stays as it was. An export that also rewrote its original is
    /// caught here, which no check of the export shows; so is an application that saved over its input by itself while the
    /// task changed only what it shows (review A6-4, 14 October 2026). Guards are shown, never part of the result.
    static func guards(for checks: [MemoryTaskTool.ResultCheck], fingerprints: [String: TaskResultCheck.FileFacts], outputs: JSONValue,
                       minimization: ValueMinimization) -> [MemoryTaskTool.ResultCheck] {
        let named = Set(checks.flatMap { $0.read.path.map { [$0] } ?? [] } + checks.compactMap { check -> String? in
            if case .fileMoved(_, let to) = check.read { return to }
            if case .fileCopied(_, let to) = check.read { return to }
            return nil
        } + (outputs.array ?? []).compactMap { item in
            item["value"].string.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        })
        return fingerprints.filter { path, facts in facts.digest != nil && !named.contains(path) }.keys.sorted().map { path in
            let read = TaskResultCheck.Expectation.fileUnchanged(path: path)
            return MemoryTaskTool.ResultCheck(read: read, kept: MemoryTaskTool.kept(read, by: minimization), isGuard: true)
        }
    }

    /// Separates a declared completion from the predicates actually checked. Window presence
    /// cannot certify a value change; matching those predicates to the goal remains the agent's job.
    static func completionEvidence(_ checks: [MemoryTaskTool.ResultCheck], checked: JSONValue?) -> JSONValue {
        let resultChecks = checks.filter { !$0.isGuard }
        let windowOnly = !resultChecks.isEmpty && resultChecks.allSatisfy {
            if case .window = $0.read { return true }
            return false
        }
        let answers = (checked?.array ?? []).filter { $0["guard"] == .null }
        let verdict: String
        if answers.isEmpty { verdict = "not_checked_here" }
        else if answers.contains(where: { $0["verdict"].string == "failed" }) { verdict = "failed" }
        else if answers.allSatisfy({ $0["verdict"].string == "passed" }) { verdict = "passed" }
        else { verdict = "unknown" }
        return .object([
            "checks": .string(verdict),
            "scope": .string(windowOnly ? "window_presence_only" : "declared_predicates_only"),
            "goal_match": .string("not_assessed"),
            "guidance": .string(windowOnly
                ? "Only window presence was checked. This does not verify an applied value, a saved change or task completion. "
                    + "Compare with the requested result; read the actual applied state before claiming a value change. "
                    + "A dialog field can retain the last input even when Apply had no effect."
                : "These verdicts apply only to the named predicates, not automatically to the goal. "
                    + "A completed outcome is your declaration. Report uncertainty if the requested result is not established.")
        ])
    }

    /// Reads and records each result check the agent named for an attempt (`TaskResultCheck`): the disk for a file,
    /// against its reading from the task's beginning when Braus has one; the window server's titles for a window; the
    /// session's scene for an element. Answers what Braus found for each, never the content it read.
    func check(_ checks: [MemoryTaskTool.ResultCheck], attemptID: String, producer: TaskProducer,
                       memory: MemoryService) async -> JSONValue {
        var answers: [JSONValue] = []
        for named in checks {
            var screen: TaskResultCheck.Reading?
            switch named.read {
                case .window(let app, _, _): screen = await windowReading(of: app)
                case .element(let app, _, _): screen = .screen(windows: nil, scene: await currentScene(of: app))
                default: break
            }
            do {
                let check = try await ProcedureProducer.checkResult(named.kept, read: named.read,
                                                                    before: named.read.path.flatMap { fingerprints[$0] }, screen: screen,
                                                                    asGuard: named.isGuard, attemptID: attemptID, producer: producer,
                                                                    memory: memory)
                var answer: [String: JSONValue] = ["check": .string(named.kept.line), "verdict": .string(check.verdict.rawValue),
                                                   "found": .string(check.observed)]
                if named.isGuard { answer["guard"] = .string("added by Braus and shown; it does not admit or refuse the procedure") }
                answers.append(.object(answer))
            } catch {
                answers.append(.object(["check": .string(named.kept.line),
                                        "error": .string("The check could not be recorded: \(MemoryService.describe(error)).")]))
            }
        }
        return .array(answers)
    }

    /// The titles of the windows of an application the window server lists, the session's own when none is named; nil
    /// when it is not running.
    private func windowReading(of app: String?) async -> TaskResultCheck.Reading {
        guard let word = app ?? session.memoryApplication else {
            return .unread("no application was named and no session holds one, so no window was listed")
        }
        guard let running = try? RunningApplicationLookup.running(word) else {
            // Only a name no running application answers to says it is not running; an ambiguous one says nothing.
            return RunningApplicationLookup.isNotRunning(word) ? .screen(windows: nil, scene: nil)
                : .unread("the name given answers to several running applications")
        }
        guard let windows = try? await session.windowCandidates(ownedBy: running.processIdentifier) else {
            return .unread("the application's windows could not be listed")
        }
        return .screen(windows: windows.map { $0.title ?? "" }, scene: nil)
    }

    /// The scene the session reads now, when it holds the application named (or any, when none is named); nil otherwise.
    private func currentScene(of app: String?) async -> SceneSnapshot? {
        guard session.id != nil, let held = session.memoryApplication else { return nil }
        if let app, app != held {
            guard let running = try? RunningApplicationLookup.running(app), running.bundleIdentifier == held else { return nil }
        }
        await CallDispatcher.noteDispatch(session: session)
        return try? await session.observe()
    }

    /// A candidate as the agent reads it: its steps with their block, application, tool, arguments as
    /// recorded, how each ended and how its check judged it, and the blocks.
    static func candidate(_ summary: ProcedureProducer.CandidateSummary) -> JSONValue {
        let steps: [JSONValue] = summary.steps.map { step in
            var arguments: [String: JSONValue] = [:]
            for argument in step.arguments {
                let value: JSONValue = switch argument.value {
                    case .text(let text): .string(text)
                    case .integer(let number): .number(Double(number))
                    case .real(let number): .number(number)
                    case .boolean(let flag): .bool(flag)
                }
                if AgentCallArguments.specs(of: step.tool).first(where: { $0.name == argument.name })?.rows == .list {
                    arguments[argument.name] = .array((arguments[argument.name]?.array ?? []) + [value])
                } else {
                    arguments[argument.name] = value
                }
            }
            var fields: [String: JSONValue] = [
                "step": .number(Double(step.number)), "block": .string("b\(step.block)"), "tool": .string(step.tool.rawValue),
                "arguments": .object(arguments), "status": .string(step.status.rawValue),
            ]
            if let bundle = step.bundleID { fields["app"] = .string(bundle) }
            if let condition = step.condition, let verdict = step.verdict {
                fields["check"] = .string("\(condition.rawValue) \(verdict.rawValue)")
            }
            return .object(fields)
        }
        let blocks: [JSONValue] = summary.candidate.blocks.map { block in
            var fields: [String: JSONValue] = ["part": .string("b\(block.index + 1)"),
                                               "steps": .array([.number(Double(block.firstPosition + 1)),
                                                                .number(Double(block.lastPosition + 1))])]
            if let bundle = block.bundleID { fields["app"] = .string(bundle) }
            return .object(fields)
        }
        var known: [String: JSONValue] = [:]
        if !summary.knownPhases.isEmpty {
            known["known_phases"] = .array(summary.knownPhases.map { phase in
                .object(["from": .number(Double(phase.firstPosition + 1)), "to": .number(Double(phase.lastPosition + 1)),
                         "label": .string(phase.label), "procedures": .number(Double(phase.procedures))])
            })
        }
        return .object([
            "id": .string(summary.candidate.candidateID),
            "new": .bool(summary.isNew),
            "steps": .array(steps),
            "blocks": .array(blocks),
            "interpret": .string("Call memory_task interpret with this candidate: labels and outcomes of the procedure, of the "
                + "blocks when there are several, and of the steps; the parameters with their roles and values; the uses "
                + "of parameters in steps' arguments as templates. Steps and blocks are fixed."),
        ].merging(known, uniquingKeysWith: { $1 }))
    }

    /// The answer to an interpretation: its revision and version, each part's qualification with its
    /// reasons, and the uses the recorded actions contradicted.
    static func interpreted(_ outcome: InterpretationOutcome, candidateID: String) -> JSONValue {
        func reference(_ partID: String) -> String {
            if partID.hasSuffix("/procedure") { return "procedure" }
            if let range = partID.range(of: "/block-", options: .backwards), let index = Int(partID[range.upperBound...]) {
                return "b\(index + 1)"
            }
            if let range = partID.range(of: "/step-", options: .backwards), let index = Int(partID[range.upperBound...]) {
                return "s\(index + 1)"
            }
            if let range = partID.range(of: "/phase-", options: .backwards) {
                let bounds = partID[range.upperBound...].split(separator: "-").compactMap { Int($0) }
                if bounds.count == 2 { return "steps \(bounds[0] + 1)–\(bounds[1] + 1)" }
            }
            return partID
        }
        // The qualification counts the version's steps; the agent reads the candidate's numbers.
        func step(_ position: Int) -> Int {
            (outcome.candidatePositions.flatMap { $0.indices.contains(position) ? $0[position] : nil } ?? position) + 1
        }
        let parts: [JSONValue] = outcome.qualifications.map { qualification in
            var fields: [String: JSONValue] = ["part": .string(reference(qualification.partID)),
                                               "admitted": .bool(qualification.verdict == .admitted)]
            if !qualification.findings.isEmpty {
                fields["reasons"] = .array(qualification.findings.map { finding in
                    .string(finding.reason.rawValue + (finding.stepPosition.map { " (step \(step($0)))" } ?? ""))
                })
            }
            return .object(fields)
        }
        var answer: [String: JSONValue] = [
            "status": .string(outcome.receipt == .committed ? "interpreted" : "already recorded"),
            "candidate": .string(candidateID), "revision": .number(Double(outcome.revision)), "version": .string(outcome.routeID),
            "parts": .array(parts),
        ]
        if let repeats = outcome.repeats {
            answer["repeats"] = .string(repeats)
            answer["run"] = .string("This task repeated the method of an earlier procedure: this version replaces it in the "
                + "catalogue, and its steps verified in the earlier run count as verified here.")
        }
        if let source = outcome.followedUnchosen {
            answer["reuse"] = .string("This run repeats source \(source) of the proposal you received without choosing it: it is "
                + "counted as followed without a choice. When a source does the very work, choose it first (its readyPlan), then "
                + "adapt it and report adapted.")
        }
        if !outcome.leftOut.isEmpty {
            answer["left_out"] = .array(outcome.leftOut.keys.sorted().map { position in
                .object(["step": .number(Double(position + 1)), "why": .string(outcome.leftOut[position]?.rawValue ?? "")])
            })
            answer["method"] = .string("The procedure keeps the steps that did the work; the steps in left_out stay in the "
                + "candidate as evidence and are not repeated by a reuse.")
        }
        if !outcome.findings.isEmpty {
            answer["findings"] = .array(outcome.findings.map { finding in
                .object(["step": .number(Double(finding.stepPosition + 1)), "argument": .string(finding.argumentName),
                         "finding": .string(finding.kind.rawValue)])
            })
        }
        return .object(answer)
    }

    static func taskFailure(_ failure: MemoryTaskTool.Failure) -> JSONValue {
        .object(["status": .string("error"), "error": .string(failure.code), "message": .string(failure.message)]
            .merging(failure.details, uniquingKeysWith: { $1 }))
    }

    /// The arguments as the transcript shows them: every secret value of an input or output masked.
    static func masked(_ arguments: JSONValue) -> JSONValue {
        func mask(_ list: JSONValue) -> JSONValue {
            guard let items = list.array else { return list }
            return .array(items.map { item in
                guard case .object(var fields) = item, item["secret"].bool == true,
                      fields["value"] != nil else { return item }
                fields["value"] = .string(ValueMinimization.marker)
                return .object(fields)
            })
        }
        guard case .object(var object) = arguments else { return .object([:]) }
        for key in ["inputs", "outputs", "parameters"] where object[key] != nil { object[key] = mask(object[key] ?? .null) }
        return .object(object)
    }

    /// The calls of this producer whose effect is not known and no later fact resolved (P2-06), after the sweep of the
    /// started calls whose process ended.
    func unresolvedCalls(memory: MemoryService) async -> [UnresolvedCall] {
        let executor = MemoryExecutor.current(for: memory.directory, source: producer.source)
        if let executor { await MemoryExecutor.sweep(memory, folder: memory.directory, current: executor) }
        return (try? await memory.unresolvedCalls(source: producer.source, streamID: producer.streamID,
                                                   excludingExecutor: executor?.record.executorID)) ?? []
    }

    static func unresolvedJSON(_ call: UnresolvedCall) -> JSONValue {
        .object(["call": .string(call.eventID), "tool": .string(call.request.tool.rawValue),
                 "reason": .string(call.reason.rawValue)])
    }

}
