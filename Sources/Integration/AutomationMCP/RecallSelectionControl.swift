//
//  RecallSelectionControl.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import Foundation

/// RecallSelectionControl keeps the automatic selector (Documentation/Engine/RecallSelection.md) as the control of the
/// Recall's comparisons and regression tests, never as a mode of the product. The product's one path is the agent's choice
/// (Documentation/Engine/RecallAgentChoice.md): `memory_task` begin and recall answer a proposal, the agent chooses, Engine
/// checks and delivers. Only a test or a benchmark running in this process sets `automatic` for the task it runs, and then
/// begin and recall answer the automatic selection (`recall`) instead. No environment variable, argument or setting
/// reaches it, so no client or person can select it, and no failure falls back to it.
nonisolated public enum RecallSelectionControl {
    @TaskLocal public static var automatic = false
}
