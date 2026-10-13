//
//  AgentChoiceExperiment.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation

/// AgentChoiceExperiment says whether this process offers the experiment of the Recall by the agent's choice
/// (Documentation/Engine/RecallAgentChoice.md): only when it was started with `BRAUS_RECALL_AGENT_CHOICE=1`. Without it,
/// `memory_task` neither describes nor accepts `recall_mode`, `proposal`, `plan` or `choose`, and every client sees the
/// contract it saw before. A test sets `enabled` for the task it runs in.
nonisolated public enum AgentChoiceExperiment {
    @TaskLocal public static var enabled: Bool?

    public static var isEnabled: Bool {
        enabled ?? (ProcessInfo.processInfo.environment["BRAUS_RECALL_AGENT_CHOICE"] == "1")
    }
}
