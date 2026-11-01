/// WorkClassLabel names the priority a piece of memory work has today, before any scheduler decides it.
public enum WorkClassLabel: String, Sendable, CaseIterable {
    case critical, interactive, followUp, background, idle
}
