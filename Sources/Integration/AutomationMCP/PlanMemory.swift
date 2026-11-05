import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import os

extension TaskCycleHandler {
    final class PlanMemoryState {
        var offers: [TodoRowID: [RecallRendering.OfferedPart]]
        var composition: [TodoRowID: [String: RecallChoice.CompositionPart]]
        var choices: [PlanChoice] = []
        var notices: [String] = []
        let validate: () throws -> Void

        init(offers: [TodoRowID: [RecallRendering.OfferedPart]],
             composition: [TodoRowID: [String: RecallChoice.CompositionPart]],
             validate: @escaping () throws -> Void = {}) {
            self.offers = offers
            self.composition = composition
            self.validate = validate
        }
    }

    func planMemoryState(validate: @escaping () throws -> Void = {}) -> PlanMemoryState {
        PlanMemoryState(offers: deliveredOffers, composition: deliveredComposition, validate: validate)
    }

    struct PlanChoice {
        let row: TodoRowID
        let key: String
        let steps: String
        let plan: RecallChoice.Plan
        let task: OpenTask
        let content: TaskRevisionContent
        let owner: TaskProducer
        let composition: RecallChoice.CompositionPart?
    }

    private static let recallLog = Logger(subsystem: "dev.forte.Braus", category: "Recall")

    func rowsNeedingMemory(_ rows: [TodoRow]) -> [TodoRow] {
        rows.filter { $0.status != .done && $0.status != .abandoned && !deliveredRows.contains($0.id) }
    }

    func planRowJSON(_ row: TodoRow) -> JSONValue {
        var result = Self.rowJSON(row).object ?? [:]
        if let part = row.part,
           let key = deliveredOffers[row.id]?.first(where: { $0.partID == part })?.key {
            result["part"] = .string(key)
        }
        return .object(result)
    }

    /// Translates the row's offered key to its archive identity before the todo's foreign key is written.
    func planPart(_ key: String?, row: TodoRowID, previous: String?, state: PlanMemoryState) throws -> String? {
        guard let key else { return previous }
        guard memoryAccess.reads, let parts = state.offers[row],
              let part = parts.first(where: { $0.key == key || $0.partID == key }) else {
            throw MemoryTaskTool.Failure(code: "unknown_part",
                message: Self.planNotice(row, ModelText.text(.init(rawValue: "task_cycle.unknown_part.v2"))))
        }
        return part.partID
    }

    /// Previews each changed row independently with the existing choice checks and the current task values.
    func preparePlanChoices(_ rows: [TodoRow], task: OpenTask, content: TaskRevisionContent,
                            owner: TaskProducer, memory: MemoryService, state supplied: PlanMemoryState? = nil) async -> PlanMemoryState {
        let state = supplied ?? planMemoryState()
        guard memoryAccess.reads else { return state }
        for row in rows where row.part != nil && deliveredPlanParts[row.id] != row.part {
            guard let part = row.part, let offered = rowMemory[row.id], let range = offered.parts[part],
                  let summary = state.offers[row.id]?.first(where: { $0.partID == part }) else { continue }
            let plan = RecallChoice.Plan(proposalID: offered.proposal, needs: [
                .init(position: 0, tracts: [.init(key: range.source, first: range.first, last: range.last)],
                      declared: .all, uncovered: nil)
            ])
            do {
                if let app = row.app {
                    let known = RecallApplications.known(learned: [summary.bundleID], offered: try await session.applications(matching: app))
                    guard RecallApplications.resolve(app, among: known) == .resolved(summary.bundleID) else {
                        state.notices.append(Self.planNotice(row.id, ModelText.text(.init(rawValue: "task_cycle.unknown_part.v2"))))
                        continue
                    }
                }
                let answer = try await RecallService.shared(for: memory).choose(plan, taskID: task.taskID,
                    attemptID: task.attemptID, revision: task.revision, values: content.inputs,
                    constraints: content.constraints, producer: owner, preview: true)
                guard answer.delivery.delivery != "not_delivered" else {
                    state.notices.append(Self.planNotice(row.id, ModelText.text(.init(rawValue: "recall.channelLimit"))))
                    continue
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let steps = String(decoding: try encoder.encode(answer.delivery.needs), as: UTF8.self)
                state.choices.append(PlanChoice(row: row.id, key: summary.key, steps: steps, plan: plan,
                    task: task, content: content, owner: owner, composition: state.composition[row.id]?[part]))
            } catch {
                Self.recallLog.error("Plan choice preview failed: \(MemoryService.describe(error), privacy: .private)")
                state.notices.append(Self.planNotice(row.id, ModelText.text(.init(rawValue: "recall.choiceInvalid"))))
            }
        }
        for (first, next) in zip(rows, rows.dropFirst()) {
            guard let left = first.part.flatMap({ state.composition[first.id]?[$0] }),
                  let right = next.part.flatMap({ state.composition[next.id]?[$0] }) else { continue }
            for warning in RecallChoice.compositionWarnings(left, right) {
                state.notices.append(ModelText.render(.init(rawValue: "recall.rowPairNotice"),
                    ["first": .rowID(first.id), "next": .rowID(next.id)])
                    + ModelText.text(.init(rawValue: "recall." + warning.rawValue)))
            }
        }
        return state
    }

    /// Reserves guide heads, then delivers memory in rounds and only complete chosen parts, then guide sections.
    func deliverPlanMemory(for rows: [TodoRow], content: TaskRevisionContent, task: OpenTask,
                           owner: TaskProducer, memory: MemoryService, baseAnswer: [String: JSONValue],
                           state supplied: PlanMemoryState? = nil) async -> [String: JSONValue] {
        let state = supplied ?? planMemoryState()
        do {
            try state.validate()
            let service = RecallService.shared(for: memory)
            let texts = ModelText.recallRenderingTexts
            let encoder = JSONValue.canonicalEncoder()
            let deliveryKey = memoryAccess.reads ? "memory" : "guidance"
            var envelope = baseAnswer
            envelope[deliveryKey] = .string("")
            if !state.choices.isEmpty {
                let failures = state.choices.map {
                    Self.planNotice($0.row, ModelText.text(.init(rawValue: "recall.choiceNotRecorded")))
                }
                envelope["recall_error"] = .string(failures.joined(separator: "\n"))
            }
            let envelopeBytes = try encoder.encode(JSONValue.object(envelope)).count
            let renderBudget = max(0, planMemoryBudget - envelopeBytes)
            let measure = Self.encodedPlanTextBytes
            var offers: [RecallRendering.RowParts] = []
            var proposals: [(TodoRowID, RecallService.PlanProposal)] = []
            if memoryAccess.reads, !rows.isEmpty {
                let learned = await service.learnedApplications()
                var searched: [(TodoRow, RecallNeed)] = []
                for row in rows {
                    if let named = row.app {
                        let known = RecallApplications.known(learned: learned, offered: try await session.applications(matching: named))
                        switch RecallApplications.resolve(named, among: known) {
                        case .resolved(let bundle): searched.append((row, try RecallNeed(text: row.title, bundleID: bundle)))
                        case .unknown:
                            offers.append(.init(row: row.id, parts: [], unknownApp: .init(named: named,
                                candidates: RecallApplications.candidates(for: named, among: known))))
                        case .ambiguous(let bundles):
                            offers.append(.init(row: row.id, parts: [], unknownApp: .init(named: named, candidates: bundles)))
                        }
                    } else { searched.append((row, try RecallNeed(text: row.title))) }
                }
                for start in stride(from: 0, to: searched.count, by: RecallContract.maximumNeeds) {
                    let batch = Array(searched[start..<min(start + RecallContract.maximumNeeds, searched.count)])
                    let request = try RecallRequest(taskID: task.taskID, attemptID: task.attemptID, revision: task.revision,
                        reason: .initial, remainingWork: content.goal, needs: batch.map(\.1), values: content.inputs,
                        constraints: content.constraints, notes: [])
                    let found = try await service.proposeRows(request, producer: owner, access: memoryAccess,
                        availableChannels: availableRecallChannels())
                    for (entry, proposal) in zip(batch, found) {
                        offers.append(.init(row: entry.0.id, parts: proposal.parts))
                        if !proposal.searchAvailable {
                            state.notices.append(Self.planNotice(entry.0.id, ModelText.text(.init(rawValue: "recall.searchUnavailable"))))
                        }
                        proposals.append((entry.0.id, proposal))
                    }
                }
                let order = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                offers.sort { (order[$0.row] ?? 0) < (order[$1.row] ?? 0) }
            }
            var heads: [String] = []
            var apps: [OpenedApp] = []
            if let guides = appGuides {
                let all = (todo?.rows ?? rows).filter { $0.status == .pending || $0.status == .inProgress }
                for bundle in Set(all.compactMap(\.app)).sorted() {
                    let known = RecallApplications.known(learned: offers.flatMap { $0.parts.map(\.bundleID) },
                        offered: try await session.applications(matching: bundle))
                    let resolved: String
                    if case .resolved(let id) = RecallApplications.resolve(bundle, among: known) { resolved = id }
                    else { continue }
                    guard !deliveredGuideApps.contains(resolved), !apps.contains(where: { $0.bundleID == resolved }) else { continue }
                    let app = resolveGuideApp(resolved)
                    if let head = guides.head(for: app) {
                        heads.append(ModelText.guideContent(head: head))
                        apps.append(app)
                    }
                }
            }
            let head = heads.isEmpty ? nil : heads.joined(separator: "\n")
            let chosen = state.choices.map { RecallRendering.ChosenPart(row: $0.row, key: $0.key, steps: $0.steps) }
            let notices = state.notices + (memoryAccess.reads ? [] : [ModelText.text(.init(rawValue: "recall.notRead"))])
            let memoryDelivery = RecallRendering.Delivery(memory: offers, guideHead: head, chosen: chosen,
                notices: notices, texts: texts)
            let preliminary = RecallRendering.render(memoryDelivery, budget: renderBudget, measure: measure)
            let summaries = RecallRendering.summaries(RecallRendering.deliveredMemory(offers,
                omittingFromEnd: preliminary.leftOut?.parts ?? 0), texts: texts)
            var sections: [String] = []
            var deliveredSections: [(app: OpenedApp, title: String)] = []
            var guideSectionsLeftOut = 0
            var events: [RecallRendering.DeliveryEvent] = []
            var sectionBytes = 0
            if let guides = appGuides {
                for app in apps {
                    let remaining = max(0, renderBudget - measure(preliminary.text) - sectionBytes)
                    let selection = await guides.sections(for: app, todo: (todo?.rows ?? rows).map(\.title),
                        budgetTokens: TokenEstimate.tokens(characterCount: remaining), coveredBy: summaries)
                    sections += selection.sections.map(\.text)
                    sectionBytes += selection.sections.reduce(0) { $0 + measure($1.text) + 2 }
                    deliveredSections += selection.sections.map { (app, $0.title) }
                    guideSectionsLeftOut += selection.leftOut
                    events += selection.overlaps.map { .guideSectionCovered(bundleID: app.bundleID, partID: $0.memoryPartID) }
                }
            }
            func rendered() -> (text: String, leftOut: RecallRendering.LeftOut?, events: [RecallRendering.DeliveryEvent]) {
                RecallRendering.render(.init(memory: offers, guideHead: head, guide: sections, chosen: chosen,
                    notices: notices, leftOut: .init(parts: 0, guideSections: guideSectionsLeftOut, chosenParts: []),
                    texts: texts), budget: renderBudget, measure: measure)
            }
            let answer = rendered()
            events += answer.events
            for event in events { Self.logPlanDelivery(event) }
            let deliveredRows = Dictionary(uniqueKeysWithValues: RecallRendering.deliveredMemory(offers,
                omittingFromEnd: answer.leftOut?.parts ?? 0).map { ($0.row, $0.parts) })
            for (row, proposal) in proposals {
                let delivered = deliveredRows[row] ?? []
                let ids = Set(delivered.map(\.partID))
                let proposalID = try await service.recordPlanProposal(proposal, delivered: ids, bytes: answer.text.utf8.count)
                var parts: [String: (source: String, first: Int, last: Int)] = [:]
                for part in delivered {
                    if let range = proposal.ranges[part.partID] { parts[part.partID] = (part.key, range.lowerBound, range.upperBound) }
                }
                try state.validate()
                rowMemory[row] = RowMemory(proposal: proposalID, need: 0, parts: parts)
                deliveredOffers[row] = delivered
                deliveredComposition[row] = proposal.composition.filter { ids.contains($0.key) }
            }
            let chosenCount = max(0, state.choices.count - (answer.leftOut?.chosenParts.count ?? 0))
            var choiceErrors: [String] = []
            for choice in state.choices.prefix(chosenCount) {
                do {
                    _ = try await service.choose(choice.plan, taskID: choice.task.taskID, attemptID: choice.task.attemptID,
                        revision: choice.task.revision, values: choice.content.inputs, constraints: choice.content.constraints,
                        producer: choice.owner)
                    try state.validate()
                    deliveredPlanParts[choice.row] = todo?.rows.first(where: { $0.id == choice.row })?.part
                        ?? deliveredOffers[choice.row]?.first(where: { $0.key == choice.key })?.partID
                } catch {
                    Self.recallLog.error("Plan choice could not be recorded: \(MemoryService.describe(error), privacy: .private)")
                    choiceErrors.append(Self.planNotice(choice.row, ModelText.text(.init(rawValue: "recall.choiceNotRecorded"))))
                }
            }
            try state.validate()
            noteDeliveredGuides(text: answer.text, apps: apps, sections: deliveredSections,
                omittedSections: max(0, (answer.leftOut?.guideSections ?? 0) - guideSectionsLeftOut))
            var result: [String: JSONValue] = answer.text.isEmpty ? [:] : [deliveryKey: .string(answer.text)]
            if !choiceErrors.isEmpty { result["recall_error"] = .string(choiceErrors.joined(separator: "\n")) }
            return result
        } catch {
            return ["recall_error": .string(MemoryService.describe(error))]
        }
    }

    func noteDeliveredGuides(text: String, apps: [OpenedApp], sections: [(app: OpenedApp, title: String)],
                             omittedSections: Int) {
        guard !text.isEmpty, let guides = appGuides else { return }
        for app in apps {
            guides.noteDelivered(for: app, sections: [])
            deliveredGuideApps.insert(app.bundleID)
        }
        for section in sections.prefix(max(0, sections.count - omittedSections)) {
            guides.noteDelivered(for: section.app, sections: [section.title], head: false)
        }
    }

    static func encodedPlanTextBytes(_ text: String) -> Int {
        text.utf8.reduce(0) { count, byte in
            switch byte {
            case 0x22, 0x5c, 0x08, 0x0c, 0x0a, 0x0d, 0x09: count + 2
            case 0..<0x20: count + 6
            default: count + 1
            }
        }
    }

    static func planNotice(_ row: TodoRowID, _ detail: String) -> String {
        ModelText.render(.init(rawValue: "recall.rowNotice"), ["row": .rowID(row)]) + detail
    }

    private static func logPlanDelivery(_ event: RecallRendering.DeliveryEvent) {
        switch event {
        case .planDeliveryTrimmed(let cut):
            let partsCount = cut.parts
            let guideSectionsCount = cut.guideSections
            let chosenPartsCount = cut.chosenParts.count
            recallLog.info("planDeliveryTrimmed parts=\(partsCount, privacy: .public) guides=\(guideSectionsCount, privacy: .public) chosen=\(chosenPartsCount, privacy: .public)")
        case .guideSectionCovered(let bundleID, let partID):
            recallLog.info("guideSectionCovered app=\(bundleID, privacy: .private) part=\(partID, privacy: .private)")
        }
    }

    func learnedForPlanApp(_ bundleID: String?) async -> Int? {
        guard memoryAccess.reads,
              let bundleID, let directory = session.memoryDirectory else { return nil }
        return await RecallService.shared(for: MemoryService.shared(for: directory))
            .admittedProcedureCount(bundleID: bundleID, access: memoryAccess,
                                    availableChannels: availableRecallChannels())
    }
}
