import Capabilities
import Memory

extension ModelText {
    enum CatalogueGroup: String, CaseIterable {
        case inspection, interaction, session, integration, guides
    }

    nonisolated static func groupName(_ group: CatalogueGroup) -> String {
        text(.init(rawValue: "catalogue.group." + group.rawValue))
    }

    nonisolated static let capabilityTexts: [Entry] = [
        Entry(key: .init(rawValue: "catalogue.reconcile_call"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 264, text: "Reconcile an uncertain adapter write with a later recorded read. Supply the blocked identifier, finding, and the read response recorded_call as evidence. Updates the ledger without sending an app action.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.reconcile_call.en"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 74, text: "How do I resolve an uncertain write with recorded read evidence?", legacy: false),
        Entry(key: .init(rawValue: "catalogue.reconcile_call.it"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 74, text: "Come riconcilio una modifica incerta con una lettura registrata?", legacy: false),
        Entry(key: .init(rawValue: "reconcile_call.archive"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 67, text: "This session has no operation archive for reconciliation.", legacy: false),
        Entry(key: .init(rawValue: "reconcile_call.finding"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 55, text: "The finding must be happened or not_happened.", legacy: false),
        Entry(key: .init(rawValue: "reconcile_call.unowned"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 84, text: "No unresolved operation with that identifier belongs to this stream.", legacy: false),
        Entry(key: .init(rawValue: "reconcile_call.unsupported"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 149, text: "The evidence does not support this finding for the affected resource. Read it again with its adapter; supply recorded_call from that response.", legacy: false),
        Entry(key: .init(rawValue: "reconcile_call.receipt"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 31, text: "recorded_call: {call}", legacy: false),
        Entry(key: .init(rawValue: "catalogue.problem"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 30, text: "{path}: {problem}", legacy: false),
        Entry(key: .init(rawValue: "catalogue.detail"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 20, text: "{detail}", legacy: false),
        Entry(key: .init(rawValue: "expect.invalidShape"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 80, text: "Expected a window or element expectation.", legacy: false),
        Entry(key: .init(rawValue: "expect.rowReadFailed"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 100, text: "Row expectation could not be read; verdict unknown: {detail}", legacy: false),

        Entry(key: .init(rawValue: "catalogue.adapter.read"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 170,
            text: "This is suitable when the task needs current data before deciding what to do. The result contains the requested data or an explicit failure.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.adapter.write"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 220,
            text: "This is suitable when the task requires the change described here. The result reports the operation outcome; check any required verification before relying on the change.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.adapter.irreversible"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 220,
            text: "This is suitable only when the task explicitly requests this irreversible change. The result reports the operation outcome; it does not make the effect reversible.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.generic.en"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 40, text: "How does this operation work?", legacy: false),
        Entry(key: .init(rawValue: "catalogue.generic.it"), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: 50, text: "Come posso eseguire questa operazione?", legacy: false),
        Entry(key: .init(rawValue: "catalogue.recordingRequired"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 70,
            text: "This capability requires confirmed memory recording before execution.", legacy: false),
        Entry(
            key: .init(rawValue: "capability.unresolvedPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 33,
            text: "An earlier effect is unresolved (",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.unresolvedSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 110,
            text: "); read the affected resource, then find reconcile_call to record supported evidence before writing.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.historicalPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 42,
            text: "This value comes from an earlier attempt: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.historicalSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 43,
            text: ". Read it again or name it as a task input.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.failurePrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 19,
            text: "Capability failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.recordingFailure"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 20,
            text: ". Recording failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.recordingPrefix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 18,
            text: "Recording failed: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "capability.completedSuffix"),
            owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "unknown"),
            budgetCharacters: 39,
            text: ". The call completed. Do not repeat it.",
            legacy: false
        ),
        Entry(key: .init(rawValue: "catalogue.find"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "find"), budgetCharacters: 130,
            text: "Find capabilities for a request. Use a short question in English or Italian. Returns matching names and complete argument schemas.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.call"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "call"), budgetCharacters: 105,
            text: "Run a discovered capability by name. Supply arguments matching its schema. Returns the capability result.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.scroll"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "scroll"), budgetCharacters: 113,
            text: "Scroll a surface in a direction. This is suitable to reveal more of a list or page. Returns the observed outcome.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.scroll.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "scroll"), budgetCharacters: 20,
            text: "scroll down the list", legacy: false),
        Entry(key: .init(rawValue: "catalogue.scroll.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "scroll"), budgetCharacters: 15,
            text: "scorri la lista", legacy: false),
        Entry(key: .init(rawValue: "catalogue.select"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "select"), budgetCharacters: 99,
            text: "Select an item in a control. This is suitable for a list or picker. Returns the observed selection.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.select.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "select"), budgetCharacters: 14,
            text: "select an item", legacy: false),
        Entry(key: .init(rawValue: "catalogue.select.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "select"), budgetCharacters: 18,
            text: "seleziona una voce", legacy: false),
        Entry(key: .init(rawValue: "catalogue.drag"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "drag"), budgetCharacters: 107,
            text: "Drag an element to a destination. This is suitable to move an item on screen. Returns the observed outcome.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.drag.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "drag"), budgetCharacters: 12,
            text: "drag an item", legacy: false),
        Entry(key: .init(rawValue: "catalogue.drag.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "drag"), budgetCharacters: 20,
            text: "trascina un elemento", legacy: false),
        Entry(key: .init(rawValue: "catalogue.context_menu"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "context_menu"), budgetCharacters: 112,
            text: "Open an element context menu. This is suitable for actions offered on that element. Returns the resulting scene.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.context_menu.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "context_menu"), budgetCharacters: 17,
            text: "open context menu", legacy: false),
        Entry(key: .init(rawValue: "catalogue.context_menu.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "context_menu"), budgetCharacters: 24,
            text: "apri il menu contestuale", legacy: false),
        Entry(key: .init(rawValue: "catalogue.insert_text"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "insert_text"), budgetCharacters: 108,
            text: "Insert text into a field. This is suitable when replacing or entering a value. Returns the observed outcome.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.insert_text.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "insert_text"), budgetCharacters: 22,
            text: "insert text in a field", legacy: false),
        Entry(key: .init(rawValue: "catalogue.insert_text.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "insert_text"), budgetCharacters: 25,
            text: "inserisci testo nel campo", legacy: false),
        Entry(key: .init(rawValue: "catalogue.press"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "press"), budgetCharacters: 106,
            text: "Press a named button. This is suitable for a button identified in the scene. Returns the observed outcome.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.press.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "press"), budgetCharacters: 14,
            text: "press a button", legacy: false),
        Entry(key: .init(rawValue: "catalogue.press.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "press"), budgetCharacters: 17,
            text: "premi un pulsante", legacy: false),
        Entry(key: .init(rawValue: "catalogue.triple_click"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "triple_click"), budgetCharacters: 123,
            text: "Click an element three times. This is suitable when a single or double click is insufficient. Returns the observed outcome.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.triple_click.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "triple_click"), budgetCharacters: 17,
            text: "click three times", legacy: false),
        Entry(key: .init(rawValue: "catalogue.triple_click.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "triple_click"), budgetCharacters: 16,
            text: "clicca tre volte", legacy: false),
        Entry(key: .init(rawValue: "catalogue.status"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "status"), budgetCharacters: 102,
            text: "Read session and permission status. This is suitable to inspect readiness. Returns the current status.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.status.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "status"), budgetCharacters: 20,
            text: "check session status", legacy: false),
        Entry(key: .init(rawValue: "catalogue.status.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "status"), budgetCharacters: 33,
            text: "controlla lo stato della sessione", legacy: false),
        Entry(key: .init(rawValue: "catalogue.windows"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "windows"), budgetCharacters: 92,
            text: "List available windows. This is suitable to inspect open surfaces. Returns matching windows.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.windows.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "windows"), budgetCharacters: 12,
            text: "list windows", legacy: false),
        Entry(key: .init(rawValue: "catalogue.windows.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "windows"), budgetCharacters: 18,
            text: "elenca le finestre", legacy: false),
        Entry(key: .init(rawValue: "catalogue.apps"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "apps"), budgetCharacters: 102,
            text: "List available applications. This is suitable to locate an application. Returns matching applications.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.apps.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "apps"), budgetCharacters: 17,
            text: "list applications", legacy: false),
        Entry(key: .init(rawValue: "catalogue.apps.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "apps"), budgetCharacters: 22,
            text: "elenca le applicazioni", legacy: false),
        Entry(key: .init(rawValue: "catalogue.close_session"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "close_session"), budgetCharacters: 101,
            text: "Close the current session. This is suitable when interaction is finished. Returns the closing status.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.close_session.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "close_session"), budgetCharacters: 17,
            text: "close the session", legacy: false),
        Entry(key: .init(rawValue: "catalogue.close_session.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "close_session"), budgetCharacters: 18,
            text: "chiudi la sessione", legacy: false),
        Entry(key: .init(rawValue: "catalogue.collect_posts"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "collect_posts"), budgetCharacters: 122,
            text: "Collect entries from a page while scrolling. This is suitable for reading multiple entries. Returns the collected entries.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.collect_posts.en"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "collect_posts"), budgetCharacters: 20,
            text: "collect page entries", legacy: false),
        Entry(key: .init(rawValue: "catalogue.collect_posts.it"), owner: "AutomationMCP",
            delivery: .toolAnswer(tool: "collect_posts"), budgetCharacters: 29,
            text: "raccogli le voci della pagina", legacy: false),
        Entry(key: .init(rawValue: "catalogue.noSuitable"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 17, text: "No suitable tool.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.unknown"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 13, text: "Unknown tool.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.invalid"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 15, text: "Invalid schema.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.unsupported"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 27, text: "Unsupported schema keyword.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.deep"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 19, text: "Schema is too deep.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.type"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 15, text: "Expected type: ", legacy: false),
        Entry(key: .init(rawValue: "catalogue.enum"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 32, text: "Value is not in the allowed set.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.alternative"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 45, text: "Value does not match the schema alternatives.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.missing"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 31, text: "A required argument is missing.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.extra"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 17, text: "Unknown argument.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.finite"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 25, text: "Expected a finite number.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.minimum"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 27, text: "Value is below the minimum.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.maximum"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 27, text: "Value is above the maximum.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.short"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 18, text: "Text is too short.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.long"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 17, text: "Text is too long.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.few"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 14, text: "Too few items.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.many"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 15, text: "Too many items.", legacy: false),
        Entry(key: .init(rawValue: "catalogue.duplicate"), owner: "AutomationMCP",
            delivery: .summary, budgetCharacters: 15, text: "Duplicate item.", legacy: false),
    ] + CatalogueGroup.allCases.map { group in
        Entry(key: .init(rawValue: "catalogue.group." + group.rawValue), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: group.rawValue.count, text: group.rawValue, legacy: false)
    } + ["strict", "capabilities", "groups"].map { key in
        Entry(key: .init(rawValue: "catalogue.key." + key), owner: "AutomationMCP", delivery: .summary,
            budgetCharacters: key.count, text: key, legacy: false)
    }
}

extension ModelText {
    static func schemaProblem(_ problem: SchemaValidation.Problem, minimizing: ValueMinimization = .init()) -> String {
        let key: String
        var suffix = ""
        switch problem.code {
        case .invalidSchema, .invalidSchemaType, .valueNotAllowed: key = "invalid"
        case .unsupportedSchemaKeyword: key = "unsupported"
        case .schemaTooDeep: key = "deep"
        case .expectedType(let types): key = "type"; suffix = types.joined(separator: " or ")
        case .enumMismatch: key = "enum"
        case .alternativeMismatch: key = "alternative"
        case .requiredArgumentMissing: key = "missing"
        case .unknownArgument: key = "extra"
        case .nonFiniteNumber: key = "finite"
        case .belowMinimum: key = "minimum"
        case .aboveMaximum: key = "maximum"
        case .textTooShort: key = "short"
        case .textTooLong: key = "long"
        case .tooFewItems: key = "few"
        case .tooManyItems: key = "many"
        case .duplicateItem: key = "duplicate"
        }
        return render(.init(rawValue: "catalogue.problem"), [
            "path": .minimized(minimizing.minimize(text: problem.path).0),
            "problem": .minimized(minimizing.minimize(text: text(.init(rawValue: "catalogue." + key)) + suffix).0)
        ])
    }
}
