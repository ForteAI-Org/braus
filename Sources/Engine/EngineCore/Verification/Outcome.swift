/// Outcome separates gesture delivery, observed effect and the next safe step.
public struct Outcome: Sendable, Equatable, Hashable {
    public enum Gesture: String, Sendable, CaseIterable {
        case sent, notSent = "not_sent", uncertain
    }

    public enum Unknown: String, Sendable, CaseIterable {
        case stillChanging = "still_changing", notWatched = "not_watched"
        case notClassified = "not_classified", notReadable = "not_readable"
    }

    public enum Effect: Sendable, Hashable {
        case confirmed, absent, unknown(Unknown), notApplicable

        public var text: String {
            switch self {
            case .confirmed: "confirmed"
            case .absent: "absent"
            case .unknown(let reason): "unknown(\(reason.rawValue))"
            case .notApplicable: "not_applicable"
            }
        }
    }

    public let gesture: Gesture
    public let effect: Effect
    public let recovery: Recovery

    public init(gesture: Gesture, effect: Effect, recovery: Recovery) {
        self.gesture = gesture
        self.effect = effect
        self.recovery = recovery
    }

    public var row: String { "\(gesture.rawValue) · \(effect.text) · \(recovery.text)" }

    /// Decodes only the closed row vocabulary, without accepting extra instructions.
    public static func parse(_ row: String) -> Outcome? {
        let parts = row.split(separator: " · ").map(String.init)
        guard parts.count == 3, let gesture = Gesture(rawValue: parts[0]) else { return nil }
        let effects: [Effect] = [.confirmed, .absent, .notApplicable] + Unknown.allCases.map { .unknown($0) }
        let recoveries: [Recovery] = [.continue, .observe, .doNotRepeat, .askPerson, .retry]
            + Recovery.Blocked.allCases.map { .changeTarget($0) }
        guard let effect = effects.first(where: { $0.text == parts[1] }),
              let recovery = recoveries.first(where: { $0.text == parts[2] }) else { return nil }
        return Outcome(gesture: gesture, effect: effect, recovery: recovery)
    }

    /// Derives the historical word. A dry run is indistinguishable from an intentional no-op.
    public var legacyKind: ActOutcomeKind {
        if gesture != .notSent { return effect == .confirmed || recovery == .continue ? .foundActed : .actedUnverified }
        switch recovery {
        case .changeTarget(.notFound): return .honestMiss
        case .changeTarget(.ambiguous): return .ambiguous
        case .continue: return .actedNoop
        default: return .refused
        }
    }

    /// Converts producer evidence in priority order, then accounts for a scene already attached.
    public static func converting(
        _ kind: ActOutcomeKind,
        check: OperationCheck?,
        notSent: NotSentCause?,
        noop: NoopKind?,
        sceneAttached: Bool
    ) -> Outcome {
        var gesture: Gesture = .notSent
        var effect: Effect = .notApplicable
        var recovery: Recovery = .continue
        switch kind {
        case .foundActed:
            gesture = .sent
            effect = check?.condition == .menuItemChosen && check?.verdict == .passed
                && check?.method != .controlValue && check?.limits.contains(.commandEffectUnchecked) == true ? .unknown(.notClassified) : .confirmed
        case .actedUnverified:
            gesture = .sent
            let limits = check?.limits ?? []
            if check?.performed == .uncertain || limits.contains(.deliveryUncertain) {
                gesture = .uncertain
                effect = .unknown(.notReadable)
                recovery = .observe
            } else if check?.verdict == .failed {
                effect = .absent
                let unchanged = check?.method == .sceneDifference && check?.observed == "unchanged"
                    && !limits.contains(.settleCapped) && !limits.contains(.settleUnwatched)
                let openMenu = limits.contains(.commandEffectUnchecked) && check?.observed == "menu open"
                recovery = unchanged || openMenu ? .retry : .doNotRepeat
            } else if limits.contains(.unattributed) {
                effect = .unknown(.notClassified)
                recovery = .doNotRepeat
            } else if limits.contains(.settleCapped) {
                effect = .unknown(.stillChanging)
                recovery = .observe
            } else if limits.contains(.settleUnwatched) {
                effect = .unknown(.notWatched)
                recovery = .observe
            } else if limits.contains(.noAfterScene) || limits.contains(.readbackUnavailable) {
                effect = .unknown(.notReadable)
                recovery = .observe
            } else {
                effect = .unknown(.notClassified)
                recovery = .doNotRepeat
            }
        case .actedNoop:
            effect = noop == .statePresent ? .confirmed : .notApplicable
        case .honestMiss: recovery = .changeTarget(.notFound)
        case .ambiguous: recovery = .changeTarget(.ambiguous)
        case .dryRun: break
        case .refused:
            recovery = switch notSent {
            case .needsConsent: .askPerson
            case .destructiveUnverifiable: .changeTarget(.destructive)
            case .disabled: .changeTarget(.disabled)
            case .targetUnreachable: .changeTarget(.unreachable)
            case .seatNotReady: .retry
            case .inputAuthorityExpired: .observe
            case .humanIntervention, .other, nil: .doNotRepeat
            }
        }
        if recovery == .observe && sceneAttached { recovery = .doNotRepeat }
        return Outcome(gesture: gesture, effect: effect, recovery: recovery)
    }
}

/// NoopKind records why a producer intentionally sent no requested gesture.
public enum NoopKind: String, Sendable, CaseIterable {
    case statePresent = "state_present", listing, substituted
}
