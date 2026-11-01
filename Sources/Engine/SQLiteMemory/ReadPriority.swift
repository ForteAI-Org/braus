/// ReadPriority chooses a reader queue; existing reads use the common reader.
package enum ReadPriority: Sendable {
    case critical
    case interactive
    case common
    case bulk

    var index: Int {
        switch self {
        case .critical, .interactive: 0
        case .common: 1
        case .bulk: 2
        }
    }
}
