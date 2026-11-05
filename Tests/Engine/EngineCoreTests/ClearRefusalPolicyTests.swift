import EngineCore
import Testing

struct ClearRefusalPolicyTests {
    @Test func ambiguousClearControlsNeedPositiveTransientTargetEvidence() {
        for label in ["Cancella", "Cancella tutto", "Clear", "Clear all", "Effacer", "Löschen", "Borrar"] {
            for role: String? in [nil, "AXButton", "AXMenuItem"] {
                #expect(ActionPolicy.isDestructive(label: label, role: role))
            }
            for container in ["Input", "Saved history"] {
                #expect(ActionPolicy.isDestructive(label: label, role: "AXButton", container: container))
            }
        }
    }

    @Test func genericAbbreviationsDoNotProveDeletion() {
        for label in ["C", "AC", "CE"] {
            #expect(!ActionPolicy.isDestructive(label: label, role: "AXButton"))
        }
    }

    @Test func persistentAndAmbiguousOperationsRemainProtected() {
        for label in ["Cancella account", "Clear all data", "Delete", "Send", "Pay", "Erase disk", "Clear-account", "Clear…"] {
            #expect(ActionPolicy.isDestructive(label: label, role: "AXButton"))
        }
    }
}
