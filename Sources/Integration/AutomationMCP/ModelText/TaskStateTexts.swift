extension ModelText {
    nonisolated static let taskStateTexts: [Entry] = {
        let sections: [(String, String)] = [
            ("request", "Request"),
            ("facts", "Task facts"),
            ("decisions", "Decisions"),
            ("failedAttempts", "Failed attempts"),
            ("loaded", "Loaded tools and guides"),
            ("todo", "Todo"),
            ("lastOutcome", "Last outcome"),
            ("scene", "Current scene"),
            ("goal", "Goal and next item"),
            ("personIntervention", "Person intervention")
        ]
        let labels: [(String, String)] = [
            ("unobserved", "Unobserved: "),
            ("noEvidence", "No evidence supplied."),
            ("digestUnobserved", "Effects not stated in the digest."),
            ("reasonUnobserved", "Reason not supplied."),
            ("stopped", "Task stopped."),
            ("revised", "Plan revised: "),
            ("finished", "Finished."),
            ("noOutcome", "No gesture outcome supplied."),
            ("schema", "Schema: "),
            ("guide", "Guide: "),
            ("goal", "Goal: "),
            ("next", "Next: "),
            ("separator", " | "),
            ("pathSeparator", " / "),
            ("provenance", " [c{count}]"),
            ("ellipsis", "…")
        ]
        var blocks: [(String, String)] = []
        for (name, heading) in sections {
            blocks.append((name + ".heading", heading))
            blocks.append((name + ".open", "<" + name + ">"))
            blocks.append((name + ".close", "</" + name + ">"))
        }
        return (blocks + labels).map { name, text in
            Entry(key: .init(rawValue: "task_state." + name), owner: "Turn", delivery: .summary,
                  budgetCharacters: text.count, text: text, legacy: false)
        }
    }()
}
