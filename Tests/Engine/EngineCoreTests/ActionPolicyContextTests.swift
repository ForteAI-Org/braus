@testable import EngineCore
import Testing

@Suite("Destructive policy uses complete words and operation context")
struct ActionPolicyContextTests {

    @Test("words containing a command internally are not commands",
          arguments: ["Information", "Transformation", "Payload", "Buyer guide", "Presend preview", "Resettlement"])
    func internalSubstrings(label: String) {
        #expect(!ActionPolicy.isDestructive(label: label))
    }

    @Test("commands, phrases, morphology, case, accents and punctuation keep their guard",
          arguments: ["Format Disk", "FORMAT…", "Erase", "Removing", "Deleted", "Formatting", "Overwritten", "DeleteAll", "PayNow", "SendMessage", "SENDMessage", "ConfirmOrder", "ReplaceAll",
                      "Send message", "SENDING", "Sent", "Publish", "Submit", "Submitted", "Buy", "Bought",
                      "Pay", "Paid", "Payments", "Replace All…", "Sign-out", "Log out", "Confirm order",
                      "Invia messaggio", "Inviare", "Élimina", "Cancellazione", "Rimuovi", "Svuota",
                      "Sovrascrivi", "Formatta disco", "Disconnetti", "Acquista", "Compra", "Paga"])
    func commandsRemainGuarded(label: String) {
        #expect(ActionPolicy.isDestructive(label: label))
    }

    @Test("a native format selector is configuration only for the explicit selection operation",
          arguments: ["Format", "File format", "Track format", "Output format…", "Formato file"])
    func selectionContext(label: String) {
        #expect(!ActionPolicy.isDestructiveSelectionControl(label: label, role: "AXPopUpButton"))
        #expect(ActionPolicy.isDestructive(label: label, role: "AXPopUpButton"))
        for role in [nil, "AXButton", "AXMenuItem", "AXMenuButton", "AXLink"] as [String?] {
            #expect(ActionPolicy.isDestructiveSelectionControl(label: label, role: role))
        }
    }

    @Test("a format configuration opener grants no permission to a destructive item or label",
          arguments: ["Format Disk", "Format and Erase", "Send message", "Pay", "Delete"])
    func finalChoicesRemainGuarded(label: String) {
        #expect(ActionPolicy.isDestructiveSelectionControl(label: label, role: "AXPopUpButton"))
        #expect(ActionPolicy.isDestructiveMenuItem(
            label, openedBy: "File format", bundleID: "example.editor", role: "AXPopUpButton", container: "Export"
        ))
        #expect(IrreversiblePolicy.decision(allowed: true, readBack: .cannotConfirm) == .cannotReadBack)
    }

    @Test("ordinary safe choices remain safe while their final command is classified separately")
    func safeFormatChoice() {
        #expect(!ActionPolicy.isDestructiveMenuItem(
            "PNG", openedBy: "File format", bundleID: "example.editor", role: "AXPopUpButton", container: "Export"
        ))
    }

    @Test("history navigation needs both a whole history label and a native navigation role")
    func navigationContext() {
        for label in ["Payment history", "Purchase history", "PAYMENTS HISTORY…"] {
            for role in ["AXLink", "AXTab"] {
                #expect(!ActionPolicy.isDestructive(label: label, role: role))
            }
            for role in [nil, "AXButton", "AXMenuItem", "AXRadioButton"] as [String?] {
                #expect(ActionPolicy.isDestructive(label: label, role: role))
            }
        }
        for label in ["Pay", "Payment", "Payment history and Pay", "Publish history", "Send history"] {
            #expect(ActionPolicy.isDestructive(label: label, role: "AXLink"))
        }
    }
}
