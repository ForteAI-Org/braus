//
//  MemoryCommand.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import LocalEmbedding
import Memory
import PerceptionCore
import SQLiteMemory

/// MemoryCommand prints what the living memory holds for an application: the Brain's size and clock,
/// its most established anchors with what they do, and its groups. With `--import-json <dir>` it
/// copies the Brains of an earlier JSON Knowledge directory into the memory instead; with `--status` it
/// says what the archive file is and the Recall this process would run; with `--tasks` it lists the
/// archive's tasks; with `--task <id>` it prints what the procedures, the Brain and the Recall hold of one
/// task, read only; with `--recall-status`, `--recall-rebuild` and `--recall-explain <text>` it shows and
/// maintains the Recall's index.
enum MemoryCommand {

    static func run(_ invocation: Invocation) async throws {
        if invocation.flags.contains("status") {
            printStatus(of: Runtime.knowledgeDirectory(invocation).appendingPathComponent("memory.sqlite"))
            return
        }
        if invocation.flags.contains("tasks") {
            let limit = invocation.options["last"].flatMap(Int.init) ?? 20
            guard limit > 0 else { throw UsageError.invalid(option: "last", value: invocation.options["last"] ?? "", expected: "a number above 0") }
            let producer = invocation.options["producer"]
            if let producer, MemoryEventSource(rawValue: producer) == nil {
                throw UsageError.invalid(option: "producer", value: producer,
                                         expected: MemoryEventSource.allCases.map(\.rawValue).joined(separator: ", "))
            }
            printTasks(limit: limit, producer: producer, json: invocation.flags.contains("json"),
                       in: Runtime.knowledgeDirectory(invocation).appendingPathComponent("memory.sqlite"))
            return
        }
        if let taskID = invocation.options["task"] {
            printTask(taskID, graph: invocation.flags.contains("graph"),
                      in: Runtime.knowledgeDirectory(invocation).appendingPathComponent("memory.sqlite"))
            return
        }
        let runtime = Runtime(invocation: invocation)
        if invocation.flags.contains("recall-status") || invocation.flags.contains("recall-rebuild")
            || invocation.options["recall-explain"] != nil {
            try await recall(invocation, in: runtime)
            return
        }
        if invocation.flags.contains("apply-relations") {
            try await applyRelations(in: runtime)
            return
        }
        if invocation.options["part"] != nil || invocation.options["requalify"] != nil
            || invocation.options["quarantine-policy"] != nil {
            try await changeProcedures(invocation, in: runtime)
            return
        }
        if let source = invocation.options["import-json"] {
            try await importJSON(from: URL(fileURLWithPath: (source as NSString).expandingTildeInPath, isDirectory: true),
                                 into: runtime)
            return
        }
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let bundleID = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        let brain: UIBrain
        do {
            guard let stored = try await runtime.service.brain(of: bundleID) else {
                print("nothing remembered about \(bundleID) in \(runtime.service.url.path)")
                return
            }
            brain = stored
        } catch {
            print("the memory in \(runtime.service.url.path) cannot be read: \(MemoryService.describe(error))")
            return
        }
        print("\(bundleID): \(brain.objects.count) anchors, \(brain.groups.count) groups, "
            + "\(brain.transitions.count) transitions; observed \(brain.ingestEpoch) times")
        let established = brain.objects.sorted { $0.seenCount > $1.seenCount }.prefix(15)
        if !established.isEmpty { print("anchors, most seen first:") }
        for anchor in established {
            let name = anchor.label.isEmpty ? "(unnamed)" : anchor.label
            let source = anchor.labelSource.map { " [\($0.rawValue)]" } ?? ""
            let does = brain.does(anchorKey: anchor.anchorKey).map { ", \($0)" } ?? ""
            let states = anchor.statesSeen.isEmpty
                ? ""
                : ", states " + anchor.statesSeen.keys.sorted().joined(separator: "/")
            let at = String(format: "%.2f,%.2f", anchor.boundsTypical.x, anchor.boundsTypical.y)
            print("  \(name)\(source) ×\(anchor.seenCount) at \(at)\(does)\(states)")
        }
        for group in brain.groups {
            let members = "\(group.memberAnchors.count) \(group.sharedKind.rawValue)s"
            print("group \(group.name ?? group.axis.rawValue): \(members), seen \(group.seenCount)×")
        }
        let opportunities = brain.namingOpportunities(limit: 5)
        if !opportunities.isEmpty { print("worth naming:") }
        for opportunity in opportunities {
            print("  \(opportunity.anchor.anchorKey.prefix(8)) score \(opportunity.score): \(opportunity.context)")
        }
    }

    /// Prints what the archive file is, read only: this command opens no memory service, so it creates,
    /// migrates, recovers and copies nothing, and it has no counters of another process's writes. It
    /// reads in one read transaction under the archive's presence lock, so it never reads while a
    /// recovery moves the files, and says so instead.
    private static func printStatus(of url: URL) {
        let report = SQLiteMemoryInspection.inspect(url)
        print("archive: \(report.path)")
        print("SQLite linked into this braus: \(SQLiteLibrary.version) (\(SQLiteLibrary.sourceID))")
        if let unmet = SQLiteLibrary.unmetRequirement() {
            print("  below the memory's requirement: \(unmet.minimumVersion)")
        }
        let known = SQLiteMemoryInspection.supportedVersion
        if let version = report.schemaVersion { print("schema version: \(version); this build opens version \(known)") }
        switch report.shape {
            case .missing:               print("this build: no archive at this path; Braus's memory would create it")
            case .empty:                 print("this build: a database with no schema yet; Braus's memory would create its schema in it, "
                                               + "a reader refuses it")
            case .current:               print("this build: opens it; version \(known) and exactly the shape this build creates")
            case .migratable(let from):
                print("this build: migrates it from version \(from) to \(known) on Braus's next open, "
                      + "after a verified copy beside it; exactly the shape of version \(from)")
            case .refused(let mismatch): print("this build: refuses it and leaves it as it is; " + describe(mismatch))
            case .unreadable(let why):   print("this build: cannot read it as a database: \(why)")
            case .unavailable(let why):  print("this build: did not read it: \(why)")
            case .interruptedRecovery(let why):
                print("this build: did not read it: \(why). Braus's memory opens nothing until a recovery completes "
                      + "it from that record, on its next open, or says why it cannot")
        }
        if let bytes = report.bytes { print("size: \(bytes) bytes" + (report.journalBytes.map { ", journal \($0) bytes" } ?? "")) }
        for table in SQLiteMemoryInspection.countedTables {
            if let count = report.counts[table] { print("  \(table): \(count) rows") }
        }
        print("copies: " + (report.backups.isEmpty ? "none" : report.backups.joined(separator: ", ")))
        if !report.quarantined.isEmpty { print("moved aside after a recovery: " + report.quarantined.joined(separator: ", ")) }
        printRecallIdentity()
        print("writes waiting, failed or dropped live in the memory of the process that offered them;")
        print("this command has its own and shows none. The app shows its own on Settings > Brain.")
    }

    /// Prints the Recall a process of this build would run on this Mac, resolved as the app and the chat
    /// resolve it (`RecallConfiguration.resolved`, from the environment): the channel, the model and whether
    /// its files are installed where they are looked for, the document format, whether the process would own
    /// the archive's index, and what a measure turned off. The same facts `memory_task status` answers from a
    /// running process; here from the terminal, before any process runs. `--knowledge` moves the archive, not
    /// the models folder, which `BRAUS_APP_SUPPORT_DIR` or `BRAUS_RECALL_MODELS` moves.
    private static func printRecallIdentity() {
        for line in RecallIdentity.resolved().lines { print(line) }
    }

    /// Prints the archive's tasks, newest first, read only as `--status` reads the file: who opened each,
    /// its status and times (UTC), the goal of its current revision, and what the procedures and the Recall
    /// hold of it, counted. With `--json`, the same rows as a JSON array.
    private static func printTasks(limit: Int, producer: String?, json: Bool, in url: URL) {
        switch SQLiteMemoryInspection.tasks(in: url, limit: limit, source: producer) {
            case .unavailable(let why):
                print("the tasks were not read: \(why)")
            case .found(let rows):
                if json {
                    let objects: [[String: Any]] = rows.map { row in
                        var object: [String: Any] = [
                            "task": row.taskID, "producer": "\(row.source):\(row.streamID)", "status": row.status,
                            "opened_at": Self.instant(row.openedAtMS), "revision": row.currentRevision, "goal": row.goal,
                            "attempts": row.attempts, "versions": row.versions, "proposals": row.proposals, "chosen": row.choices,
                            "queries": row.queries,
                        ]
                        object["closed_at"] = row.closedAtMS.map(Self.instant) ?? NSNull()
                        return object
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) {
                        print(String(decoding: data, as: UTF8.self))
                    }
                    return
                }
                print("tasks in \(url.path): \(rows.count) shown, newest first" + (producer.map { ", producer \($0)" } ?? "")
                      + (rows.count == limit ? " (--last \(limit); pass a larger number for more)" : ""))
                for row in rows {
                    print("  \(row.taskID)  \(row.source):\(row.streamID)  \(row.status)  \(Self.instant(row.openedAtMS))"
                          + (row.closedAtMS.map { " → \(Self.instant($0))" } ?? "")
                          + "  rev \(row.currentRevision)  attempts \(row.attempts)  versions \(row.versions)"
                          + "  proposals \(row.proposals)  chosen \(row.choices)  queries \(row.queries)")
                    print("    goal: \(row.goal)")
                }
        }
    }

    /// A calendar instant of the archive (milliseconds since 1970) as ISO 8601 in UTC.
    private static func instant(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// Prints one task by its id, read only as `--status` reads the file: its attempts and calls with
    /// what each one is to the procedures, its candidates and versions with their parts, parameters,
    /// contracts and qualifications, the relations its calls proved, and the counts kept apart. With
    /// `--graph`, the same objects as one Mermaid graph.
    private static func printTask(_ taskID: String, graph: Bool, in url: URL) {
        switch SQLiteMemoryInspection.task(taskID, in: url) {
            case .found(let inspection): print(graph ? inspection.graph : inspection.text.joined(separator: "\n"))
            case .notFound:              print("no task \(taskID) in \(url.path)")
            case .unavailable(let why):  print("the task was not read: \(why)")
        }
    }

    /// Changes how the procedures are offered, without deleting anything: a part's operational state
    /// (`--part <id> --state usable|to_reevaluate|retired --reason <text>`; `retired` is final), a
    /// version evaluated again from the facts under the policy in force (`--requalify <route id>`), or a
    /// qualification policy put in quarantine (`--quarantine-policy <version> --reason <text>`), which
    /// stops offering what it admitted until a build with another policy evaluates the parts again.
    private static func changeProcedures(_ invocation: Invocation, in runtime: Runtime) async throws {
        let now = runtime.service.clock.calendarMS()
        let reason = invocation.options["reason"] ?? ""
        do {
            if let partID = invocation.options["part"] {
                let word = invocation.options["state"] ?? ""
                guard let state = PartOperationalState(rawValue: word) else {
                    throw UsageError.invalid(option: "state", value: word, expected: "usable, to_reevaluate or retired")
                }
                guard !reason.isEmpty else { throw UsageError.missing("--reason <text>") }
                let receipt = try await runtime.service.perform {
                    try await $0.procedures.setState(state, of: partID, reason: reason, by: "braus-cli", at: now)
                }
                print("\(partID): \(state.rawValue) (\(receipt == .committed ? "recorded" : "already so"))")
            } else if let routeID = invocation.options["requalify"] {
                let qualifications = try await runtime.service.perform { try await $0.procedures.requalify(routeID: routeID, at: now) }
                for qualification in qualifications {
                    let reasons = qualification.findings.map(\.reason.rawValue).joined(separator: ", ")
                    print("\(qualification.partID): \(qualification.verdict.rawValue) under \(qualification.policyVersion)"
                          + (reasons.isEmpty ? "" : " (\(reasons))"))
                }
            } else if let policy = invocation.options["quarantine-policy"] {
                guard !reason.isEmpty else { throw UsageError.missing("--reason <text>") }
                let receipt = try await runtime.service.perform {
                    try await $0.procedures.quarantine(policy: policy, reason: reason, at: now)
                }
                print("\(policy): quarantined (\(receipt == .committed ? "recorded" : "already so"))")
            }
        } catch let error as ProcedureError {
            print("not changed: \(error)")
        }
        await runtime.finish()
    }

    /// Runs the relation recovery the service runs in the background, to its end, at once: every
    /// operation never evaluated (an archive migrated from an earlier schema, a derived write lost when a
    /// process ended), every one waiting for evidence that has arrived, every one evaluated under another
    /// policy. A call counts once however often it is evaluated; a second run evaluates nothing.
    private static func applyRelations(in runtime: Runtime) async throws {
        var total = SQLiteBrainRelationRepository.CatchUp()
        while true {
            let now = runtime.service.clock.brainMS()
            let pass = try await runtime.service.perform { repositories in
                try await repositories.relations.catchUp(at: now, limit: 500) { key in
                    _ = try await repositories.scenes.associate(key, at: now)
                }
            }
            total.recovered += pass.recovered
            total.reconsidered += pass.reconsidered
            total.reevaluated += pass.reevaluated
            total.associated += pass.associated
            if !pass.remaining { break }
        }
        print("relations of \(runtime.service.url.path): \(total.recovered) operations evaluated for the first time, "
              + "\(total.reconsidered) evaluated again with new evidence, \(total.reevaluated) under the current policy, "
              + "\(total.associated) samples placed in a state")
        await runtime.finish()
    }

    /// Shows and maintains the Recall's index with the configuration this process resolves (`BRAUS_RECALL`,
    /// `BRAUS_RECALL_MODELS`): `--recall-status` prints the generations, the entries, the vectors still to compute and
    /// the index work pending, without running any; `--recall-rebuild` queues a rebuild of the whole catalogue and runs
    /// the index work until it is done or `--within <seconds>` passes; `--recall-explain <text>` scores every part of
    /// the current generation against a text and prints the most relevant (`--limit`), recording no query and
    /// selecting nothing.
    private static func recall(_ invocation: Invocation, in runtime: Runtime) async throws {
        let recall = RecallService.shared(for: runtime.service)
        let configuration = recall.configuration
        if invocation.flags.contains("recall-rebuild") {
            let now = runtime.service.clock.calendarMS()
            try await runtime.service.perform { try await $0.recall.queueRebuild(at: now) }
            let budget = Double(invocation.options["within"] ?? "") ?? 600
            print("rebuild of the whole catalogue queued; building for at most \(Int(budget)) s…")
            await recall.schedule()
            if !(await recall.waitUntilIdle(within: .seconds(budget))) {
                print("the index work did not finish in time; Braus's memory goes on with it whenever it runs")
            }
        }
        if invocation.flags.contains("recall-status") || invocation.flags.contains("recall-rebuild") {
            let status = try await recall.status()
            let model = configuration.model.map { "\($0.modelID)@\($0.revision.prefix(12))" } ?? "none"
            print("recall of \(runtime.service.url.path)")
            print("configuration: channel \(configuration.channel.rawValue), model \(model), format \(configuration.format.rawValue)")
            if configuration.channel != .lexical {
                print("models folder: \(configuration.modelsDirectory?.path ?? "none")")
            }
            if let failure = status.modelFailure { print("semantic model unavailable: \(failure); the lexical index answers") }
            if status.index.generations.isEmpty { print("no index generation yet") }
            for generation in status.index.generations {
                print("generation \(generation.generationID): \(generation.status.rawValue), format \(generation.format.rawValue), "
                      + "space \(generation.spaceID ?? "lexical only"), revision \(generation.revision)"
                      + (generation.isEnumerated ? "" : ", catalogue being enumerated"))
            }
            print("entries in the current generation: \(status.index.entries); vectors still to compute: \(status.index.vectorBacklog)")
            let work = try await runtime.service.perform { try await $0.recall.pendingWork(limit: 20) }
            print("index work pending: \(status.index.pendingWork)")
            for item in work {
                print("  \(item.reason) \(item.routeID ?? "whole catalogue")" + (item.attempts > 0 ? ", \(item.attempts) failed attempts" : ""))
            }
            if let failure = status.workerFailure { print("index work stopped: \(failure)") }
        }
        if let text = invocation.options["recall-explain"] {
            let limit = Int(invocation.options["limit"] ?? "") ?? 15
            let (channel, parts) = try await recall.explain(text, limit: limit)
            print("scored on the \(channel.rawValue) channel; no query recorded, nothing selected")
            for part in parts {
                let semantic = part.semantic.map { String(format: "%.3f", $0) } ?? "  -  "
                print(String(format: "%.3f  semantic %@  lexical %.3f  %@  ", part.combined, semantic, part.lexical, part.kind.rawValue)
                      + "\(part.partID)\n       \(part.text)")
            }
        }
        await runtime.finish()
    }

    /// Why this build refuses a file, in a sentence.
    private static func describe(_ mismatch: MemorySchemaMismatch) -> String {
        func listed(_ names: [String]) -> String { names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", …" : "") }
        switch mismatch {
            case .future(let found, let supported): return "schema \(found) is newer than the \(supported) this build knows; "
                                                           + "its shape was not compared"
            case .unknownTables(let tables):        return "version 0 with tables of somebody else's: \(listed(tables))"
            case .missingTables(let tables):        return "tables missing: \(listed(tables))"
            case .missingColumns(let columns):      return "an earlier development form, columns missing: \(listed(columns))"
            case .differentShape(let objects):      return "another shape: \(listed(objects))"
            case .uninitialized:                    return "no schema yet"
            case .migrationRequired(let found, let supported):
                return "schema \(found), which Braus's memory migrates to \(supported) on its next open; a reader does not"
            case .unsupported(let found, let supported):
                return "schema \(found), below the \(supported) this build knows, with no migration from it"
        }
    }

    /// Copies the Brain of every application file in an earlier JSON Knowledge directory into the
    /// memory, as that application's projection, when the memory holds no Brain of it yet
    /// (`JSONBrainImport`). The JSON files are only read, never changed. An archive this command creates
    /// first imports the JSON Brains beside it on its own, as every opener of a new archive does, and the
    /// command says so before its own lines.
    private static func importJSON(from source: URL, into runtime: Runtime) async throws {
        let knowledge = JSONBrainImport.applications(in: source)
        guard !knowledge.isEmpty else {
            print("no application files in \(source.path)")
            return
        }
        let repositories = try await runtime.service.ready()
        let created = await runtime.service.status().lastImport
        if let created { print(created) }
        let report = await JSONBrainImport.run(knowledge, into: repositories.brains, now: Date())
        for entry in report.entries {
            switch entry.outcome {
                case .imported(let anchors, let groups, let transitions):
                    print("imported \(entry.bundleID): \(anchors) anchors, \(groups) groups, \(transitions) transitions")
                case .kept:
                    print("kept \(entry.bundleID): the memory already holds its Brain")
                case .failed(let why):
                    print("could not import \(entry.bundleID): \(why)")
            }
        }
        await runtime.finish()
        print("\(report.imported) of \(knowledge.count) applications imported into \(runtime.service.url.path)"
              + (created == nil ? "" : " by this command, after the archive's creation imported those beside it"))
    }
}
