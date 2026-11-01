/// LoopInstructionComposing writes the system text of a loop turn; the host owns its words.
@MainActor
public protocol LoopInstructionComposing {
    func systemText(role: String?, hasTools: Bool, tools: String) -> String
}
