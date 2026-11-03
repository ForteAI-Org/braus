# Schema 22

Proposed DDL for DB1. This resource is not active: SQLiteMemorySchema.version remains 19.
Tommaso must approve the full DDL before DB2 activates the single conversion. No source archive was opened or converted for this increment.

The source audit uses revision `0e594d722e139a29e1801d0fc4b9afebab200d46`.
All 121 source tables have a destination. The 40 new tables bring the proposed total to 161.
The file has 91 explicit indexes and 330 triggers: 119 retained source triggers, 98 source triggers transferred to code, and 211 new triggers.
Old tables: 110 changed, 11 frozen, 0 unchanged, 0 out. Frozen takes precedence over physical key changes in these counts.

## Conversion contract

DB2 creates `tables`, transfers and derives rows, then executes `indexes` and `triggers` in that order inside its controlled conversion.
The same destination applies to 19, private 20 and 21. Preserve rows and resolve local integer identities before adding constraints.
An added surrogate for a formerly composite parent has a simple FK; the retained contextual columns are checked by SchemaCoherence.
Each removed source trigger needs a pure DB2 check with that trigger name in its doc comment and a coverage case.
UUIDs occur once per globally identified entity; dependent rows refer to integer PKs. Rows keyed by parent and position remain ordered associations.
Private 20 operations become generic capability calls. The private 21 memory_learned_facts table, person preferences, parameter defaults and conversation state are outside this DDL (R-C-44, R-X-14, R-X-41).
ME1 §3.5 answers DB1’s value-retention question: ordinary values retain text_value; personal and secret values use reference plus value_digest. Historic text remains until the declared VK4 exception is used.
No historic caption can be distinguished from a value label: retain value; caption is for new rows only (RF2).

## Table inventory

Each row gives the source, destination, decision, future writer, readers and conversion for all three source versions.
The reference evidence below includes every Swift reference under Sources and Tools; SQL scripts are test consumers, not production writers.
General conversion: preserve scalar content and observable ordering, allocate integer identities, resolve simple FKs, and move contextual agreement to DB2. New facts start empty unless explicitly derived below.

| Table | Source | Destiny | Decisions | Writer increments | Readers | DB2 conversion | Source writer and reference evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `brain_apps` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteObservationRows.swift:38`, `Probe.swift:337`, `Probe.swift:540`. All references: `SQLiteBrainApplicationRepository.swift:480`; `SQLiteBrainGraphRepository.swift:239,363,393`; `SQLiteBrainRelationRepository.swift:481,528`; `SQLiteBrainRows.swift:13,43,46,320`; `SQLiteMemoryInspection.swift:70`; `SQLiteMenuCommandRepository.swift:120`; `SQLiteObservationRows.swift:33,38,65,85`; `SQLiteProcedureRepository.swift:582,736,1059,1097,1515,1568`; `SQLiteRecallRepository.swift:388`; `SQLiteRecallRows.swift:494,513`; `SQLiteRouteRepository.swift:371`; `SQLiteSceneRepository.swift:68`; `Probe.swift:38,43,337,525,540` |
| `brain_app_window_epochs` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteBrainRows.swift:328`. All references: `SQLiteBrainRows.swift:13,50,328,336` |
| `brain_app_contexts` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteObservationRows.swift:57`. All references: `SQLiteBrainGraphRepository.swift:404`; `SQLiteObservationRows.swift:50,57,86` |
| `brain_scenes` | 19 (also 20/21) | changed | R-G-08, R-G-10, R-G-13, R-G-18 | SQLiteSceneRepository after DB2, BR4, BR6 | Brain, archive inspection, VK3 | Preserve UUID and counters; title_bucket becomes a nullable historical hint. Only scene_kind determines app scope; legacy title hints do not constrain scene kind. skeleton_digest = SkeletonDigest(skeleton).bytes = Digest16.of(SceneSkeleton.canonical); retain equivalent historical scenes. Resolve set_id after deduplication. | Direct writes: `SQLiteBrainRows.swift:552`, `SQLiteSceneRepository.swift:314`. All references: `SQLiteBrainGraphRepository.swift:154,209,227,321,336,344,408`; `SQLiteBrainRows.swift:100,544,552`; `SQLiteMemorySchema.swift:153`; `SQLiteRouteRepository.swift:328`; `SQLiteSceneRepository.swift:14,138,292,314` |
| `brain_scene_roles` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteSceneRepository.swift:326`. All references: `SQLiteMemorySchema.swift:152`; `SQLiteSceneRepository.swift:326` |
| `brain_scene_labels` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteSceneRepository.swift:336`. All references: `SQLiteSceneRepository.swift:336` |
| `brain_anchors` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:398`, `SQLiteBrainRows.swift:491`. All references: `BrainDecayReport.swift:12`; `SQLiteBrainGraphRepository.swift:39,219,322,405`; `SQLiteBrainRepository.swift:186`; `SQLiteBrainRows.swift:13,57,66,88,114,128,143,149,377,398,489,491,587,628,631,659,678,717,829`; `SQLiteMemoryInspection.swift:70`; `SQLiteMemorySchema.swift:220`; `SQLiteRouteRepository.swift:327` |
| `brain_anchor_aliases` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:750`. All references: `SQLiteBrainRows.swift:56,591,694,734,738,745,750` |
| `brain_anchor_states` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:761`. All references: `SQLiteBrainRows.swift:65,761,768` |
| `brain_scene_elements` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteSceneRepository.swift:349`. All references: `SQLiteBrainGraphRepository.swift:13,36,45,168,174,221,323,341,409`; `SQLiteBrainRelationRepository.swift:443`; `SQLiteSceneRepository.swift:180,349` |
| `brain_groups` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:359`, `SQLiteBrainRows.swift:498`. All references: `BrainDecayReport.swift:18`; `SQLiteBrainGraphRepository.swift:324,406`; `SQLiteBrainRepository.swift:187`; `SQLiteBrainRows.swift:14,87,115,177,183,189,190,348,359,496,498,664,676,852` |
| `brain_group_members` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:798`. All references: `SQLiteBrainRows.swift:86,663,677,706,717,782,786,793,798` |
| `brain_menu_commands` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteMenuCommandRepository.swift:95`. All references: `SQLiteArchiveTransfer.swift:69`; `SQLiteBrainGraphRepository.swift:224,325,411`; `SQLiteMenuCommandRepository.swift:12,53,72,95,120`; `SQLiteRouteRepository.swift:329` |
| `brain_menu_path_segments` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteMenuCommandRepository.swift:106`. All references: `SQLiteMenuCommandRepository.swift:12,106,134` |
| `brain_transitions` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainGraphRepository.swift:68`, `SQLiteBrainRows.swift:454`, `SQLiteBrainRows.swift:483`. All references: `BrainDecayReport.swift:25`; `SQLiteBrainApplicationRepository.swift:150`; `SQLiteBrainGraphRepository.swift:13,57,68,98,114,151,239,250,326,344,407,410`; `SQLiteBrainRows.swift:14,116,220,230,240,246,271,277,425,432,454,481,483`; `SQLiteMemoryInspection.swift:71`; `SQLiteMemorySchema.swift:229` |
| `brain_transition_menu_items` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainGraphRepository.swift:81`, `SQLiteBrainRows.swift:473`. All references: `TransitionEffectRecord.swift:15`; `SQLiteBrainGraphRepository.swift:14,81,265`; `SQLiteBrainRows.swift:219,473` |
| `memory_events` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Use local_order as event_id, preserve the old event_id in event_uuid; resolve parent and origin references by integer identity. | Direct writes: `SQLiteObservationRows.swift:180`, `Probe.swift:494`, `Probe.swift:594`, `Probe.swift:670`. All references: `SQLiteAgentCallRepository.swift:14,47,73,86,174,352,416`; `SQLiteArchiveTransfer.swift:285,477,557,828,1069,1074`; `SQLiteBrainGraphRepository.swift:413,414,425`; `SQLiteBrainRelationRepository.swift:309,334,348,377`; `SQLiteCaptureRepository.swift:12`; `SQLiteExperienceRepository.swift:75,196`; `SQLiteMemoryInspection.swift:70`; `SQLiteMemorySchema.swift:227`; `SQLiteObservationRows.swift:74,84,149,173,180,211`; `SQLiteObservedInputRepository.swift:83,214`; `SQLiteProcedureRepository.swift:1515,1567`; `SQLiteRecallRows.swift:494,513`; `SQLiteReconciliationRows.swift:78,121,144`; `SQLiteStepOccurrenceRepository.swift:184`; `SQLiteTaskRepository.swift:197`; `SQLiteTraceRepository.swift:10,37,47,68,77,81,96,109`; `Probe.swift:489,494,514,594,650,670` |
| `memory_input_events` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteObservedInputRepository.swift:107`. All references: `SQLiteArchiveTransfer.swift:67`; `SQLiteObservedInputRepository.swift:13,47,107,122,124` |
| `memory_agent_actions` | 19 (also 20/21) | changed | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES1, ES2, ES4, ES5, AT1, EC2, EC3, SC4 | ES4, qualification, BR5 | DB2 calls Outcome.converting(..., noop:) from ES1; acted_noop follows ES1 readers, historical new NotSentCause cases stay nil. Mark converted or converted_partial; preserve result_kind only for tools without gestures. | Direct writes: `SQLiteAgentCallRepository.swift:173`. All references: `SQLiteAgentCallRepository.swift:15,73,86,96,173,189,231,416`; `SQLiteArchiveTransfer.swift:720`; `SQLiteBrainRelationRepository.swift:309,334,397`; `SQLiteMemoryInspection.swift:70`; `SQLiteMemorySchema.swift:222,225,226,230`; `SQLiteProcedureRepository.swift:581,590,1514,1525,1568`; `SQLiteRecallRows.swift:466`; `SQLiteReconciliationRows.swift:77,143`; `SQLiteTraceRepository.swift:68` |
| `memory_agent_action_effect_labels` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:248`. All references: `SQLiteAgentCallRepository.swift:248,437` |
| `memory_agent_action_status` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:271`. All references: `SQLiteAgentCallRepository.swift:271,513` |
| `memory_agent_action_listings` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:279`. All references: `SQLiteAgentCallRepository.swift:279,523` |
| `memory_agent_action_applications` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:285`. All references: `SQLiteAgentCallRepository.swift:285,537` |
| `memory_agent_action_windows` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:298`. All references: `SQLiteAgentCallRepository.swift:298,529` |
| `memory_agent_action_observations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:320`. All references: `SQLiteAgentCallRepository.swift:320,562` |
| `memory_event_observations` | 19 (also 20/21) | changed | R-G-07, R-G-10, R-G-18 | SQLiteObservationRows after DB2, BR2, RF2, ID6 | Brain, archive inspection, VK3 | Preserve capture/diagnostic observation_id values; derive shared element content and sets from historical element observations and attach set_id. The owner must decide how per-sample bounds and before/after-state evidence survive before DB2 removes or compacts those rows (Open questions). window_number is the captured window (a sheet uses its parent). Derive only capture-time reject_reason; never append a later association result. Existing value label origins stay value. | Direct writes: `SQLiteObservationRows.swift:542`, `SQLiteObservationRows.swift:566`, `SQLiteObservationRows.swift:588`. All references: `ObservationKind.swift:8`; `SQLiteAgentCallRepository.swift:310`; `SQLiteArchiveTransfer.swift:919,939`; `SQLiteBrainApplicationRepository.swift:259`; `SQLiteBrainGraphRepository.swift:414`; `SQLiteCaptureRepository.swift:13`; `SQLiteObservationRows.swift:200,217,322,542,566,588`; `SQLiteOperationFactRepository.swift:533` |
| `memory_event_scenes` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteSceneRepository.swift:275`. All references: `SceneStructureMatcher.swift:39`; `SQLiteBrainGraphRepository.swift:350`; `SQLiteProcedureRepository.swift:626`; `SQLiteRecallRows.swift:171,503`; `SQLiteSceneRepository.swift:14,245,275` |
| `memory_verifications` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:505`, `SQLiteProcedureRepository.swift:300`, `SQLiteTaskRepository.swift:34`. All references: `OperationFact.swift:88`; `TaskResultCheck.swift:13`; `SQLiteArchiveTransfer.swift:67`; `SQLiteMemoryInspection.swift:280,305`; `SQLiteOperationFactRepository.swift:505,561`; `SQLiteProcedureRepository.swift:300,682,688,1253,1541`; `SQLiteRecallRows.swift:478`; `SQLiteStepOccurrenceRepository.swift:100`; `SQLiteTaskRepository.swift:12,34,55,136,139` |
| `memory_action_correlations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteObservedInputRepository.swift:67`. All references: `SQLiteArchiveTransfer.swift:67`; `SQLiteObservedInputRepository.swift:14,67,83,172,175` |
| `brain_applications` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainApplicationRepository.swift:407`. All references: `BrainApplication.swift:14,278`; `SQLiteArchiveTransfer.swift:950`; `SQLiteBrainApplicationRepository.swift:19,186,246,281,370,407,480`; `SQLiteMemoryInspection.swift:71` |
| `brain_evidence` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteBrainApplicationRepository.swift:349`, `SQLiteBrainGraphRepository.swift:131`. All references: `SQLiteBrainApplicationRepository.swift:27,243,343,349`; `SQLiteBrainGraphRepository.swift:14,131,363,368,396,399` |
| `memory_task_occurrences` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskRepository.swift:166`. All references: `SQLiteArchiveTransfer.swift:67`; `SQLiteBrainGraphRepository.swift:423`; `SQLiteTaskContextRepository.swift:13,120,159,442,453`; `SQLiteTaskRepository.swift:67,92,166,175,178` |
| `memory_task_events` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskRepository.swift:210`. All references: `SQLiteArchiveTransfer.swift:68`; `SQLiteCallFieldRows.swift:101,102,118,127`; `SQLiteMemoryInspection.swift:279,304`; `SQLiteOperationFactRepository.swift:268`; `SQLiteProcedureRepository.swift:306,580,1253,1276,1514,1570`; `SQLiteRecallRows.swift:466`; `SQLiteTaskContextRepository.swift:208`; `SQLiteTaskRepository.swift:67,210,217,222,227` |
| `memory_task_labels` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskRepository.swift:244`. All references: `SQLiteArchiveTransfer.swift:68`; `SQLiteTaskRepository.swift:67,244,256,260,270,277` |
| `memory_routes` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:192`. All references: `SQLiteArchiveTransfer.swift:68`; `SQLiteBrainGraphRepository.swift:419`; `SQLiteProcedureRepository.swift:345,346,840,1021,1171,1215,1322,1624,1654`; `SQLiteRecallChoices.swift:135`; `SQLiteRouteRepository.swift:13,72,97,192,356,365,398` |
| `memory_route_parameters` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:201`. All references: `SQLiteRouteRepository.swift:14,177,201,340,344` |
| `memory_route_steps` | 19 (also 20/21) | changed | R-F-16, R-F-25, R-F-27, R-I-29, R-X-41 | PP1, PP2, EE3, EE4, EA2, TU9 | qualification, provenance, procedure runner | Allocate integer step_id per (route_id, position); historical actor = agent, segment_id NULL. Person steps are goal rows; no operation or occurrence for person (writer check). | Direct writes: `SQLiteRouteRepository.swift:211`. All references: `SQLiteExperienceRepository.swift:33`; `SQLiteProcedureRepository.swift:980,1172`; `SQLiteRouteRepository.swift:14,179,211,371,378,385`; `SQLiteStepOccurrenceRepository.swift:59` |
| `memory_step_checks` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:230`. All references: `SQLiteRouteRepository.swift:14,180,230,423,429` |
| `memory_step_operations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:271`. All references: `SQLiteRouteRepository.swift:14,182,183,271,461,466,469,472,480,487` |
| `memory_operation_arguments` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteAgentCallRepository.swift:188`, `SQLiteBrainApplicationRepository.swift:383`, `SQLiteRouteRepository.swift:314`. All references: `AgentCallArguments.swift:12`; `SQLiteAgentCallRepository.swift:15,188,586`; `SQLiteBrainApplicationRepository.swift:187,247,383,561`; `SQLiteMemorySchema.swift:221`; `SQLiteOperationFactRepository.swift:684,696`; `SQLiteRouteRepository.swift:15,314,560,566` |
| `memory_route_call_bindings` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:257`. All references: `SQLiteRouteRepository.swift:15,257,403,405,590` |
| `memory_step_occurrences` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:664`, `SQLiteStepOccurrenceRepository.swift:31`. All references: `SQLiteArchiveTransfer.swift:68`; `SQLiteBrainGraphRepository.swift:424`; `SQLiteProcedureRepository.swift:657,664`; `SQLiteStepOccurrenceRepository.swift:12,31,46,75,161,166,172,176`; `SQLiteTaskRepository.swift:47` |
| `memory_step_events` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteStepOccurrenceRepository.swift:204`. All references: `SQLiteProcedureRepository.swift:1032,1156,1272,1361,1536`; `SQLiteRecallRows.swift:170,181,200`; `SQLiteStepOccurrenceRepository.swift:12,204,213,218,224` |
| `memory_route_evidence` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteStepOccurrenceRepository.swift:128`. All references: `SQLiteStepOccurrenceRepository.swift:13,128,234` |
| `memory_step_evidence` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteStepOccurrenceRepository.swift:132`. All references: `SQLiteStepOccurrenceRepository.swift:13,132,236` |
| `memory_experiences` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteExperienceRepository.swift:40`. All references: `SQLiteArchiveTransfer.swift:68`; `SQLiteBrainGraphRepository.swift:422`; `SQLiteExperienceRepository.swift:12,40,94,102,140,179` |
| `memory_experience_bindings` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteExperienceRepository.swift:61`. All references: `SQLiteExperienceRepository.swift:12,61,144,149` |
| `memory_experience_uses` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteExperienceRepository.swift:82`. All references: `SQLiteExperienceRepository.swift:15,82,196,203` |
| `memory_schema_migrations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteMemoryStore.swift:860`, `SQLiteMemoryStore.swift:1017`. All references: `SQLiteMemoryStore.swift:860,1017` |
| `memory_tasks` | 19 (also 20/21) | changed | R-A-42, R-F-06, R-G-17 | TU6, TU13, EC3, EC5, EE4, PP1 | task cycle, person review | Preserve UUID, revisions and terminal status; historical open rows remain open. No invented postponed history. | Direct writes: `SQLiteTaskContextRepository.swift:226`. All references: `SQLiteArchiveTransfer.swift:69`; `SQLiteMemoryInspection.swift:309`; `SQLiteTaskContextRepository.swift:11,78,124,226,241,248` |
| `memory_task_revisions` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskContextRepository.swift:283`. All references: `SQLiteMemoryInspection.swift:288`; `SQLiteTaskContextRepository.swift:283,316,324` |
| `memory_task_constraints` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskContextRepository.swift:294`. All references: `SQLiteTaskContextRepository.swift:294,327` |
| `memory_task_message_refs` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskContextRepository.swift:302`. All references: `SQLiteTaskContextRepository.swift:302,331` |
| `memory_task_attempts` | 19 (also 20/21) | changed | R-A-42, R-F-06, R-G-17 | TU6, TU13, EC3, EC5, EE4, PP1 | task cycle, person review | Reuse the occurrence integer identity; preserve ordinal and resume chain; takeover = none for historical rows. | Direct writes: `SQLiteTaskContextRepository.swift:423`. All references: `SQLiteCallFieldRows.swift:134`; `SQLiteMemoryInspection.swift:279,289,290,304`; `SQLiteRecallRows.swift:257`; `SQLiteTaskContextRepository.swift:13,423,441,452,464` |
| `memory_task_checkpoints` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteTaskContextRepository.swift:487`. All references: `SQLiteProcedureRepository.swift:1173,1216`; `SQLiteTaskContextRepository.swift:487,505,512,516` |
| `memory_task_values` | 19 (also 20/21) | changed | R-C-14, R-C-15, R-C-20, R-C-35, R-C-40 | ME1, PE3 | Recall, ME5, VK4 | Preserve historical text_value, content, kind and source; resolve optional task_revision_id or checkpoint_id according to its owner. Derive value_digest only from an available canonical value; missing/withheld have NULL digest. | Direct writes: `SQLiteTaskContextRepository.swift:361`. All references: `SQLiteCallFieldRows.swift:134`; `SQLiteTaskContextRepository.swift:361,383,393,400` |
| `memory_task_call_revisions` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:276`. All references: `SQLiteOperationFactRepository.swift:276,287` |
| `memory_call_effects` | 19 (also 20/21) | changed | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES1, ES2, ES4, ES5, AT1, EC2, EC3, SC4 | ES4, qualification, BR5 | Preserve the distinct delivery detail and target evidence; canonical typed outcome is on memory_agent_actions. Do not reinterpret result_kind as an execution state. | Direct writes: `SQLiteOperationFactRepository.swift:332`. All references: `SQLiteArchiveTransfer.swift:69`; `SQLiteOperationFactRepository.swift:332,471,477`; `SQLiteReconciliationRows.swift:79` |
| `memory_call_routes` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:356`. All references: `SQLiteArchiveTransfer.swift:72`; `SQLiteMemorySchema.swift:62`; `SQLiteOperationFactRepository.swift:356,364,368` |
| `memory_call_adapter_dispatches` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:384`. All references: `SQLiteArchiveTransfer.swift:73`; `SQLiteMemorySchema.swift:66`; `SQLiteOperationFactRepository.swift:384,454,458` |
| `memory_call_rungs` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:404`. All references: `SQLiteArchiveTransfer.swift:73`; `SQLiteOperationFactRepository.swift:404,412,416` |
| `memory_call_route_advice` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:433`. All references: `SQLiteArchiveTransfer.swift:74`; `SQLiteOperationFactRepository.swift:433,441,446` |
| `memory_operation_verifications` | 19 (also 20/21) | changed | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES1, ES2, ES4, ES5, AT1, EC2, EC3, SC4 | ES4, qualification, BR5 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:514`. All references: `SQLiteBrainRelationRepository.swift:393`; `SQLiteOperationFactRepository.swift:158,514,561,576`; `SQLiteProcedureRepository.swift:578,675,1139,1306,1540`; `SQLiteRecallRows.swift:478`; `SQLiteReconciliationRows.swift:121` |
| `memory_operation_verification_limits` | 19 (also 20/21) | changed | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES1, ES2, ES4, ES5, AT1, EC2, EC3, SC4 | ES4, qualification, BR5 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:526`. All references: `SQLiteMemorySchema.swift:58`; `SQLiteOperationFactRepository.swift:526,579,584` |
| `memory_operation_verification_samples` | 19 (also 20/21) | changed | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES1, ES2, ES4, ES5, AT1, EC2, EC3, SC4 | ES4, qualification, BR5 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:544`. All references: `SQLiteOperationFactRepository.swift:544,590,597` |
| `memory_call_recording_gaps` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:648`. All references: `SQLiteArchiveTransfer.swift:70`; `SQLiteOperationFactRepository.swift:648,658,663` |
| `memory_value_redactions` | 19 (also 20/21) | changed | R-G-07, R-G-08, R-G-09, R-G-10, R-G-11, R-G-13, R-G-14, R-G-18, R-G-20 | BR2, BR3, BR4, BR5, BR6, RF2, ID6 | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteOperationFactRepository.swift:624`. All references: `SQLiteArchiveTransfer.swift:69`; `SQLiteBrainRelationRepository.swift:387`; `SQLiteMemorySchema.swift:54`; `SQLiteOperationFactRepository.swift:615,624,711,717,727,743,751,755`; `SQLiteProcedureRepository.swift:603,614` |
| `memory_archive_origins` | 19 (also 20/21) | changed | R-C-44, R-C-67, R-G-32 | VK4, VK5, DB2, RA1 | catalogue, Recall, archive import | Preserve origin_uuid, location and journal progress; retain mcp_profile and previous_product, add archive_import for new imports. | Direct writes: `SQLiteArchiveTransfer.swift:480`, `SQLiteArchiveTransfer.swift:995`. All references: `SQLiteArchiveTransfer.swift:35,89,93,100,247,256,348,364,480,995,1015,1036,1056,1094,1104` |
| `memory_origin_events` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve source_event_id as the external UUID text and resolve event_id locally. DB2 compares source_event_id to event_uuid when checking renamed disposition. | Direct writes: `SQLiteArchiveTransfer.swift:668`. All references: `SQLiteArchiveTransfer.swift:22,668,905,1015` |
| `memory_origin_brain_contributions` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteArchiveTransfer.swift:751`, `SQLiteBrainRepository.swift:200`. All references: `SQLiteArchiveTransfer.swift:70,88,92,99,751,852`; `SQLiteBrainRepository.swift:200` |
| `memory_procedure_candidates` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:703`. All references: `SQLiteArchiveTransfer.swift:70`; `SQLiteMemoryInspection.swift:296,297`; `SQLiteProcedureRepository.swift:77,703,727,752,759,1582` |
| `memory_candidate_steps` | 19 (also 20/21) | changed | R-F-16, R-F-25, R-F-27, R-I-29, R-X-41 | PP1, PP2, EE3, EE4, EA2, TU9 | qualification, provenance, procedure runner | Historical rows are actor = agent with their call and occurrence; segment_id and person_evidence NULL. Convert the private operation to capability_call in 20/21. | Direct writes: `SQLiteProcedureRepository.swift:714`. All references: `SQLiteProcedureRepository.swift:714,736,746,991` |
| `memory_procedure_interpretations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:795`. All references: `SQLiteMemoryInspection.swift:298`; `SQLiteProcedureRepository.swift:778,785,795,940,950` |
| `memory_interpretation_findings` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:805`. All references: `SQLiteProcedureRepository.swift:805,1080,1086` |
| `memory_procedure_versions` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:850`. All references: `SQLiteMemoryInspection.swift:290`; `SQLiteProcedureRepository.swift:140,342,416,465,819,825,839,850,940,953,1169,1189,1214,1586,1624`; `SQLiteRecallChoices.swift:135`; `SQLiteRecallRepository.swift:418` |
| `memory_procedure_parts` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:861`. All references: `SQLiteProcedureRepository.swift:433,480,861,1059,1068,1195,1338,1649,1656,1668`; `SQLiteRecallRepository.swift:209,387`; `SQLiteRecallRows.swift:283` |
| `memory_part_contract_items` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:884`. All references: `SQLiteProcedureRepository.swift:884,1097,1104` |
| `memory_parameter_details` | 19 (also 20/21) | changed | R-C-14, R-C-15, R-C-20, R-C-35, R-C-40 | ME1, PE3 | Recall, ME5, VK4 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:872`. All references: `SQLiteProcedureRepository.swift:872,920,928` |
| `memory_operation_argument_segments` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRouteRepository.swift:286`. All references: `SQLiteRouteRepository.swift:286,502,516,527` |
| `memory_parameter_bindings` | 19 (also 20/21) | changed | R-C-14, R-C-15, R-C-20, R-C-35, R-C-40 | ME1, PE3 | Recall, ME5, VK4 | Preserve historical binding content and text_value; derive value_digest only when available. source_ref denotes an event or output, never a task value. | Direct writes: `SQLiteProcedureRepository.swift:900`. All references: `RecallSource.swift:208`; `SQLiteProcedureRepository.swift:900,960,971`; `SQLiteRecallRows.swift:256` |
| `memory_procedure_step_occurrences` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:910`. All references: `SQLiteProcedureRepository.swift:910,979,1155,1365`; `SQLiteRecallRows.swift:169,180,199` |
| `memory_qualification_policies` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:524`, `SQLiteProcedureRepository.swift:1119`. All references: `SQLiteProcedureRepository.swift:513,518,524,1119,1127,1652` |
| `memory_part_qualifications` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Resolve integer policy_id; preserve verdict and sequence; convert every historical complete to 1. ME7 readers use only complete = 1. | Direct writes: `SQLiteProcedureRepository.swift:1432`. All references: `SQLiteProcedureRepository.swift:434,435,1196,1197,1338,1428,1432,1463,1650,1651`; `SQLiteRecallRows.swift:145` |
| `memory_part_qualification_reasons` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:1441`. All references: `SQLiteProcedureRepository.swift:1441,1471,1477` |
| `memory_part_qualification_evidence` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:1451`. All references: `SQLiteProcedureRepository.swift:1198,1451,1483` |
| `memory_part_states` | 19 (also 20/21) | changed | R-C-44, R-C-67, R-G-32 | VK4, VK5, DB2, RA1 | catalogue, Recall, archive import | Convert CLI authorship to recorded_by = braus and historical reason text to reason_code = migrated; preserve state and sequence. No off state. Imported rows carry origin_id; do not infer a person preference. | Direct writes: `SQLiteProcedureRepository.swift:496`. All references: `SQLiteProcedureRepository.swift:484,496,1335,1336,1494,1497,1661`; `SQLiteRecallRows.swift:147` |
| `brain_relations` | 19 (also 20/21) | changed | R-G-08, R-G-18, R-G-20 | SQLiteBrainRelationRepository after DB2, BR5 | Brain, archive inspection, VK3 | Preserve UUID and scene rows; materialize distinct (app, element_key) in brain_element_keys and resolve element_key_id. kind_id NULL on historical rows; the later BR5 writer adds type rows. Arrival scene belongs to proof evidence for type rows. | Direct writes: `SQLiteBrainRelationRepository.swift:449`. All references: `SQLiteArchiveTransfer.swift:71`; `SQLiteBrainRelationRepository.swift:255,449,465,481,490,528`; `SQLiteProcedureRepository.swift:1606`; `SQLiteRecallRows.swift:183,522` |
| `brain_relation_proofs` | 19 (also 20/21) | changed | R-G-08, R-G-18 | BR5 | Brain, archive inspection, VK3 | Preserve historical proof rows; BR5 resumes writes and records to_scene_id. A lack of a writer in 19 does not freeze this future fact table. | Direct writes: No direct insert; see indirect/rare cases below. All references:  |
| `brain_relation_applications` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: No direct insert; see indirect/rare cases below. All references: `SQLiteArchiveTransfer.swift:71`; `SQLiteBrainRelationRepository.swift:333`; `SQLiteProcedureRepository.swift:1553` |
| `brain_scene_shapes` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteMemorySchema.swift:150`, `SQLiteSceneRepository.swift:331`. All references: `SceneSkeleton.swift:153`; `SQLiteMemorySchema.swift:150`; `SQLiteSceneRepository.swift:129,132,331` |
| `brain_relation_evaluations` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteBrainRelationRepository.swift:272`. All references: `SQLiteArchiveTransfer.swift:71`; `SQLiteBrainRelationRepository.swift:18,169,272,291,293,308,311,337,348,350,502,550,558,562`; `SQLiteProcedureRepository.swift:1548,1600` |
| `brain_relation_evidence` | 19 (also 20/21) | changed | R-G-18, R-G-20, R-X-13 | DB2 adaptation of the inventoried repository | Brain, archive inspection, VK3 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteBrainRelationRepository.swift:248`. All references: `SQLiteBrainRelationRepository.swift:168,248,501,567`; `SQLiteProcedureRepository.swift:1599`; `SQLiteRecallRows.swift:182,522` |
| `brain_anchor_label_keys` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | Brain, archive inspection, VK3 | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: `SQLiteBrainRows.swift:575`, `SQLiteBrainRows.swift:577`, `SQLiteBrainRows.swift:597`. All references: `SQLiteBrainRows.swift:575,577,597,627`; `SQLiteMemoryStore.swift:852` |
| `memory_variant_prefixes` | 19 (also 20/21) | frozen | R-G-09, R-X-13, R-G-20 | DB2 transfer only; BR3 declared content exception where applicable | existing repositories, archive inspection | Copy historical rows before freeze triggers; retain their observable ordering. | Direct writes: No direct insert; see indirect/rare cases below. All references: `SQLiteArchiveTransfer.swift:71` |
| `memory_variant_prefix_checks` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteProcedureRepository.swift:243`. All references: `SQLiteArchiveTransfer.swift:72`; `SQLiteProcedureRepository.swift:243,1038,1041,1044` |
| `memory_recall_spaces` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Allocate space_int_id; retain the full space_id and every original specification, including 64-character weights/tokenizer digests and float32 precision. Never merge by model_id alone. | Direct writes: `SQLiteRecallRepository.swift:50`. All references: `SQLiteRecallRepository.swift:50` |
| `memory_recall_generations` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRepository.swift:74`. All references: `SQLiteRecallRepository.swift:74,78,92,96,99,103,113,123,215,367,406`; `SQLiteRecallRows.swift:24,31` |
| `memory_recall_documents` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Rebuild derived documents with integer document_id and shared text_id. The document has no duplicate text column. Recall generation cursor_route_id is also an integer reference to the enumerated procedure version. | Direct writes: `SQLiteRecallRows.swift:119`. All references: `SQLiteRecallRepository.swift:241,386`; `SQLiteRecallRows.swift:119` |
| `memory_recall_vectors` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Rebuild vectors keyed by (text_id, space_int_id), WITHOUT ROWID. Never reuse across different complete spaces. | Direct writes: `SQLiteRecallRepository.swift:266`. All references: `SQLiteRecallRepository.swift:242,266,354,389`; `SQLiteRecallRows.swift:46` |
| `memory_recall_entries` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRows.swift:127`. All references: `SQLiteMemoryInspection.swift:382`; `SQLiteRecallRepository.swift:240,385,396,599`; `SQLiteRecallRows.swift:45,94,127,140` |
| `memory_recall_work` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteMemoryStore.swift:853`, `SQLiteRecallRepository.swift:177`, `SQLiteRecallRepository.swift:178`. All references: `SQLiteMemoryInspection.swift:377`; `SQLiteMemoryStore.swift:853`; `SQLiteRecallRepository.swift:146,158,167,177,178,338,370,596,613` |
| `memory_recall_queries` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve query history and producer; minimize stored remaining_work with the same SG1 function during DB2 conversion. | Direct writes: `SQLiteRecallRows.swift:325`. All references: `SQLiteArchiveTransfer.swift:72`; `SQLiteMemoryInspection.swift:295`; `SQLiteProcedureRepository.swift:343,1318`; `SQLiteRecallInspectionRows.swift:77`; `SQLiteRecallRepository.swift:568`; `SQLiteRecallRows.swift:325,437` |
| `memory_recall_needs` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRows.swift:340`. All references: `SQLiteRecallInspectionRows.swift:89`; `SQLiteRecallRepository.swift:571`; `SQLiteRecallRows.swift:340,395` |
| `memory_recall_selections` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRows.swift:348`. All references: `SQLiteProcedureRepository.swift:344,1320`; `SQLiteRecallChoices.swift:175`; `SQLiteRecallInspectionRows.swift:99`; `SQLiteRecallRows.swift:280,348,401,437` |
| `memory_recall_requirements` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRows.swift:358`. All references: `SQLiteRecallInspectionRows.swift:109`; `SQLiteRecallRows.swift:358,409,448` |
| `memory_recall_links` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRepository.swift:534`. All references: `SQLiteRecallInspectionRows.swift:123`; `SQLiteRecallRepository.swift:534`; `SQLiteRecallRows.swift:285` |
| `memory_recall_reports` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRepository.swift:556`. All references: `SQLiteProcedureRepository.swift:340`; `SQLiteRecallInspectionRows.swift:138`; `SQLiteRecallRepository.swift:551,556` |
| `memory_recall_proposals` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve proposal history and producer; minimize stored remaining_work with the same SG1 function during DB2 conversion. | Direct writes: `SQLiteRecallChoices.swift:46`. All references: `SQLiteMemoryInspection.swift:292,293`; `SQLiteProcedureRepository.swift:266`; `SQLiteRecallChoices.swift:46,90`; `SQLiteRecallInspectionRows.swift:23` |
| `memory_recall_proposal_needs` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallChoices.swift:60`. All references: `SQLiteRecallChoices.swift:60,104`; `SQLiteRecallInspectionRows.swift:33` |
| `memory_recall_proposal_sources` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallChoices.swift:70`. All references: `SQLiteProcedureRepository.swift:267`; `SQLiteRecallChoices.swift:70,109,164`; `SQLiteRecallInspectionRows.swift:39` |
| `memory_recall_choices` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallChoices.swift:200`. All references: `SQLiteMemoryInspection.swift:293`; `SQLiteProcedureRepository.swift:269,1319`; `SQLiteRecallChoices.swift:160,200`; `SQLiteRecallInspectionRows.swift:49,76`; `SQLiteRecallRows.swift:436` |
| `memory_recall_choice_needs` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallChoices.swift:204`. All references: `SQLiteRecallChoices.swift:168,204`; `SQLiteRecallInspectionRows.swift:52` |
| `memory_recall_choice_links` | 19 (also 20/21) | changed | R-C-14, R-C-22, R-C-33, R-G-18 | ME3, ME4, ME8, RA3, DB2 | Recall, VK2 | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteRecallRepository.swift:522`. All references: `SQLiteRecallInspectionRows.swift:127`; `SQLiteRecallRepository.swift:522`; `SQLiteRecallRows.swift:287` |
| `memory_call_argument_fields` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteCallFieldRows.swift:68`. All references: `SQLiteArchiveTransfer.swift:74`; `SQLiteCallFieldRows.swift:68,147`; `SQLiteProcedureRepository.swift:579,1384` |
| `memory_call_result_fields` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteCallFieldRows.swift:33`. All references: `SQLiteArchiveTransfer.swift:74`; `SQLiteCallFieldRows.swift:33,44,100,118,127` |
| `memory_operation_argument_fields` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: No direct insert; see indirect/rare cases below. All references: `SQLiteArchiveTransfer.swift:75` |
| `memory_call_data_contexts` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteCallFieldRows.swift:195`. All references: `SQLiteArchiveTransfer.swift:75`; `SQLiteCallFieldRows.swift:195,219`; `SQLiteReconciliationRows.swift:80` |
| `memory_identity_salts` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteCallFieldRows.swift:233`, `SQLiteCallFieldRows.swift:234`. All references: `SQLiteArchiveTransfer.swift:75`; `SQLiteCallFieldRows.swift:233,234` |
| `memory_executors` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteReconciliationRows.swift:17`. All references: `SQLiteArchiveTransfer.swift:75`; `SQLiteReconciliationRows.swift:17` |
| `memory_call_executors` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteReconciliationRows.swift:29`. All references: `SQLiteArchiveTransfer.swift:76`; `SQLiteReconciliationRows.swift:20,29,81,145` |
| `memory_call_reconciliations` | 19 (also 20/21) | changed | R-G-17, R-G-18, R-G-20, R-X-13, R-X-14 | DB2; existing repositories | existing repositories, archive inspection | Preserve rows; apply the general integer-key and simple-FK conversion. | Direct writes: `SQLiteReconciliationRows.swift:46`. All references: `SQLiteArchiveTransfer.swift:76`; `SQLiteReconciliationRows.swift:42,46,58,147` |
| `memory_todo_revisions` | new | new | R-A-10, R-A-12, R-A-15, R-A-42 | TU6, TU13, EC5 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_todo_items` | new | new | R-A-15, R-A-50, R-A-51 | TU6 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_todo_item_states` | new | new | R-A-15, R-C-28, R-A-50 | TU6, TU8, ES8 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_todo_item_expectations` | new | new | R-A-15, R-A-50 | ES8 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_call_steps` | new | new | R-A-11, R-A-51 | TU6 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_task_end_checks` | new | new | R-A-13 | TU6 | task UI, TU6, ES8, ME7, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_gesture_evidence` | new | new | R-E-01, R-E-11, R-E-15, R-E-18, R-E-22, R-E-40 | ES2, ES4, AT1, ES10, ES11 | ES4, qualification, BR5 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_gesture_changes` | new | new | R-E-11, R-E-15, R-E-18 | ES4, ES5, BR5 | ES4, qualification, BR5 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_batch_stops` | new | new | R-E-01 | EC2 | ES4, qualification, BR5 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_operation_argument_links` | new | new | R-C-40 | ME1 | Recall, ME5, VK4 | Empty at migration; ME1 records new reference/template/derived/to_provide links. Format derivation templates contain tokens and separators, never values. | Future writer only; DB1 A–E. |
| `memory_step_signatures` | new | new | R-C-17, R-C-45 | ME5 | ME5, repeated parts, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_step_signature_members` | new | new | R-C-17, R-C-45 | ME5 | ME5, repeated parts, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_phase_families` | new | new | R-C-17, R-C-22, R-C-45 | ME5 | ME5, repeated parts, VK2 | Empty at migration; ME5 reconstructs by app, kind and masked class. labels is the specified ordered JSON [[label,count],…] encoded as TEXT; the schema has no JSON column type or column named json. | Future writer only; DB1 A–E. |
| `memory_phase_family_attempts` | new | new | R-C-17, R-C-45 | ME5 | ME5, repeated parts, VK2 | Empty at migration; ME5 rebuilds per-attempt contributions; deletion of a family cascades to its contributions. | Future writer only; DB1 A–E. |
| `memory_recall_texts` | new | new | R-C-22, R-G-18 | DB2, ME4 | Recall, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_recall_text_pieces` | new | new | R-C-22, R-G-18 | ME4 | Recall, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_recall_calibration` | new | new | R-C-26, R-C-33 | ME3, ME6 | ME3, ME6, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_part_misses` | new | new | R-C-45 | ME5 | ME5, repeated parts, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_part_reuse` | new | new | R-C-33 | ME6 | ME3, ME6, VK2 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_attempt_reused_parts` | new | new | R-C-31 | ME10 | qualification, VK2 | Empty at migration; ME10 permits item_id NULL for a v1 reuse mark and deduplicates it with ifnull(item_id,0). | Future writer only; DB1 A–E. |
| `memory_elements` | 19/20/21 observations (derived) | new | R-G-07, R-G-13, R-G-18 | DB2 repository conversion; BR3 controlled replacement | Brain, archive inspection, VK3 | DB2 derives deduplicated element content and its digests from memory_event_observations in 19/20/21. Per-sample bounds and before/after-state retention require the owner decision recorded under Open questions. | DB2 derives initial rows; repository writes and BR3 follow the declared ownership. |
| `memory_element_sets` | 19/20/21 observations (derived) | new | R-G-07, R-G-13, R-G-18 | DB2 repository conversion; BR3 controlled replacement | Brain, archive inspection, VK3 | DB2 derives element sets and their digests from historical observations, stores ordered member IDs, and fills memory_event_observations.set_id and the associated brain_scenes.set_id. Per-sample evidence retention remains subject to owner approval. | DB2 derives initial rows; repository writes and BR3 follow the declared ownership. |
| `brain_element_keys` | new | new | R-G-13, R-G-18, R-G-20 | DB2, BR5, PP2; BR3 controlled replacement | Brain, archive inspection, VK3 | Create from distinct (app, brain_relations.element_key) pairs in 19/20/21; key_text is DurableKey method text, digest = Digest16.of(key_text). Scene-local element_key remains distinct. | Future writer only; DB1 A–E. |
| `brain_screen_kinds` | new | new | R-G-08, R-G-11, R-G-13 | BR4, BR6 | Brain, archive inspection, VK3 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `brain_scene_kind_members` | new | new | R-G-08, R-G-11 | BR4, BR6 | Brain, archive inspection, VK3 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `brain_scene_merges` | new | new | R-G-11, R-G-32 | BR6 | Brain, archive inspection, VK3 | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_brain_command_inputs` | new | new | DB1 §3 approval gate; SK4 command contract; integrator direction | SK4 producer integration; DB2 storage/conversion | SK4 brain_observe and brain_record | No child row for historical 19/20/21 facts: every added input field is NULL through a LEFT JOIN. Never substitute an event timestamp or infer a resolved target. | Future writer: SK4 inserts with the essential sample/call-end transaction; DB2 installs the typed storage. |
| `memory_brain_command_detections` | new | new | DB1 §3 approval gate; SK4 command contract; integrator direction | SK4 producer integration; DB2 storage/conversion | SK4 brain_observe and brain_record | No historical child rows; bounds/state/kind remain NULL through a LEFT JOIN. Do not reconstruct pixel-only detections or a resolved target from structural elements. | SK4 writes every normalized detection in order, including pixel-only detections; record writes the exact resolved target at position zero. |
| `memory_consolidation_queue` | new | new | R-G-03 | DB2, SK4 and each job producer | consolidator | Empty at migration, then DB2 enqueues index_rebuild. Unknown lowercase job kinds remain queued, unprocessed and undeleted. | Future writer only; DB1 A–E. |
| `memory_consolidation_cursors` | new | new | R-G-03 | SK4, ME7 | consolidator | Empty at migration; SK4 owns recovery bounds and generation; ME7 owns opaque continuation within one version. | Future writer only; DB1 A–E. |
| `memory_part_judgments` | new | new | R-C-67, R-G-32 | VK4, VK5 | catalogue, Recall, archive import | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_forget_tombstones` | new | new | R-C-44, R-C-67 | VK4 | catalogue, Recall, archive import | Empty at migration; local tombstones are consulted on import and never exported. Person preferences remain outside this archive. | Future writer only; DB1 A–E. |
| `memory_part_origins` | new | new | R-G-14, R-C-67 | VK4 import, DB2 | catalogue, Recall, archive import | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_procedure_provenance` | new | new | R-F-16, R-I-29 | EE4, PM2, VK4 import | qualification, provenance, procedure runner | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_procedure_exit_points` | new | new | R-F-16 | EE4 | qualification, provenance, procedure runner | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_person_segments` | new | new | R-F-16, R-F-25, R-F-27 | PP1 | qualification, provenance, procedure runner | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_segment_checks` | new | new | R-F-27 | PP1 | qualification, provenance, procedure runner | No historical source; start empty for its named writer. | Future writer only; DB1 A–E. |
| `memory_person_commands` | new | new | R-F-27 | PP2 | qualification, provenance, procedure runner | Empty at migration, including arrival_kind/arrival_state/arrival_parameter. PP2 writes only correct/teach segments; MethodText admits menu_path and parameter names. No typed text or screen coordinates. | Future writer only; DB1 A–E. |
| `memory_call_capabilities` | new | new | R-X-41, R-I-29 | EA2, TU9; DB2 private 20/21 conversion | qualification, provenance, procedure runner | 19 has no rows. Convert private 20/21 calls with origin = registered, channel = command and registered origin_name; capability_id remains the registered tool name, never a closed AgentTool list. | Future writer only; DB1 A–E. |
| `memory_step_capabilities` | new | new | R-X-41 | TU9 procedure recording; DB2 private 20/21 conversion | qualification, provenance, procedure runner | 19 has no rows; convert private 20/21 operation definitions to generic capability_call links; preserve state_read_back. | Future writer only; DB1 A–E. |
## Writer audit details

`git grep -n -w <table> -- Sources Tools` was evaluated for every source table, not only insert statements. The table inventory records Swift hit lines; the complete reference index below also records script and resource hits, including read paths, dynamic table arguments, import exclusion lists and initialization.
Normal write paths were also inspected for UPDATE, DELETE, INSERT OR IGNORE, INSERT OR REPLACE, ON CONFLICT and composed SQL. Reads and exclusion-list entries are not classified as writers.

| Family | Evidence and classification |
| --- | --- |
| Normal projection | SQLiteBrainRows.write and SQLiteBrainGraphRepository write anchors, aliases, states, groups, membership and transitions in 19. R-G-09 explicitly freezes these destinations; they are not claimed to have no source writer. |
| Normal facts | SQLiteAgentCallRepository, SQLiteObservationRows, SQLiteOperationFactRepository, SQLiteTaskContextRepository, SQLiteRouteRepository, SQLiteProcedureRepository, SQLiteRecallRows and SQLiteCallFieldRows own the direct fact writes listed above. |
| Import | SQLiteArchiveTransfer:668 inserts memory_origin_events; :751 inserts memory_origin_brain_contributions. Its untransferred list at :66–75 refuses populated fact families; the presence of a table in that list is not an import writer. Actual imports of calls/captures and projection applications go through their repositories. |
| Initialization | SQLiteObservationRows ensures brain_apps and brain_app_contexts. SQLiteRecallRepository records embedding spaces and generations. SQLiteMemoryStore records memory_schema_migrations. |
| Migration and reconstruction | SQLiteMemorySchema.derivedRows fills brain_scene_shapes. SQLiteBrainRows.fillLabelKeys and SQLiteMemoryStore fill anchor label keys before activation. These paths do not grant ordinary mutation rights. |
| Rare path | SQLiteCallFieldRows:233 uses INSERT OR IGNORE for memory_identity_salts on first need. This table remains a writable fact table even when empty. |
| Future writers | The A–E writer column includes BR5 proof writes, ME1 argument links, ME5 families, ME7 partial qualifications, PP1/PP2 episodes, TU9 capabilities and VK4 tombstones. A future writer prevents freezing for absence of a current writer. |

## Source mutation inventory

Every normal UPDATE/DELETE and the modifying UPSERTs are listed below. The generic migration rebuild and derived initialization occur before triggers and grant no ordinary mutation rights. Frozen destinations deliberately stop their old projection mutations; other destinations retain exactly the inventoried columns, plus the named new transitions.

| Table | Statement owner | Operation | Columns | Destination policy |
| --- | --- | --- | --- | --- |
| `brain_anchor_aliases` | `SQLiteBrainRows.swift:734` | DELETE | row | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchor_aliases` | `SQLiteBrainRows.swift:738` | UPDATE | position | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchor_aliases` | `SQLiteBrainRows.swift:745` | UPDATE | position | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchor_label_keys` | `SQLiteBrainRows.swift:575` | DELETE | row | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchor_states` | `SQLiteBrainRows.swift:761` | UPSERT | seen_count | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchor_states` | `SQLiteBrainRows.swift:768` | DELETE | row | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchors` | `SQLiteBrainRows.swift:377` | UPDATE | kind, label, label_source, typical_x, typical_y, typical_width, typical_height, window_family, first_seen_ms, last_seen_ms, seen_count, last_seen_epoch, current_group_id | Frozen by R-G-09; ordinary mutation ends. |
| `brain_anchors` | `SQLiteBrainRows.swift:816 (retire dispatch at :481,:489,:496)` | UPDATE | retired_at_ms, retired_epoch, retirement_cause | Frozen by R-G-09; ordinary mutation ends. |
| `brain_app_window_epochs` | `SQLiteBrainRows.swift:328` | UPSERT | epoch | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_app_window_epochs` | `SQLiteBrainRows.swift:336` | DELETE | row | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_apps` | `SQLiteBrainRows.swift:320` | UPDATE | ingest_epoch, last_epoch_advance_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_group_members` | `SQLiteBrainRows.swift:782` | DELETE | row | Frozen by R-G-09; ordinary mutation ends. |
| `brain_group_members` | `SQLiteBrainRows.swift:786` | UPDATE | position | Frozen by R-G-09; ordinary mutation ends. |
| `brain_group_members` | `SQLiteBrainRows.swift:793` | UPDATE | position | Frozen by R-G-09; ordinary mutation ends. |
| `brain_groups` | `SQLiteBrainRows.swift:348` | UPDATE | axis, shared_kind, cell_width, cell_height, name, last_seen_ms, seen_count, last_seen_epoch | Frozen by R-G-09; ordinary mutation ends. |
| `brain_groups` | `SQLiteBrainRows.swift:816 (retire dispatch at :481,:489,:496)` | UPDATE | retired_at_ms, retired_epoch, retirement_cause | Frozen by R-G-09; ordinary mutation ends. |
| `brain_menu_commands` | `SQLiteMenuCommandRepository.swift:53` | UPDATE | top_level_title, accessibility_identifier, has_submenu, last_observed_enabled, mark_char, cmd_char, last_seen_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_relations` | `SQLiteBrainRelationRepository.swift:255` | UPDATE | last_seen_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_scene_elements` | `SQLiteBrainGraphRepository.swift:45` | UPDATE | anchor_id | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_scenes` | `SQLiteSceneRepository.swift:292` | UPDATE | observation_count, last_seen_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `brain_transitions` | `SQLiteBrainGraphRepository.swift:98` | UPDATE | status, evidence_count, last_seen_ms, last_observed_epoch | Frozen by R-G-09; ordinary mutation ends. |
| `brain_transitions` | `SQLiteBrainRows.swift:432` | UPDATE | evidence_count, last_seen_ms, last_observed_epoch, status | Frozen by R-G-09; ordinary mutation ends. |
| `brain_transitions` | `SQLiteBrainRows.swift:816 (retire dispatch at :481,:489,:496)` | UPDATE | retired_at_ms, retired_epoch, retirement_cause | Frozen by R-G-09; ordinary mutation ends. |
| `memory_agent_actions` | `SQLiteAgentCallRepository.swift:231` | UPDATE | execution_status, started_at_ms, completed_at_ms, duration_ms, result_kind, result_message, attempted_count, verified_count, observed_effect_kind, observed_effect_text, observed_state_before, observed_state_after, observed_effect_label, observed_effect_value | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_archive_origins` | `SQLiteArchiveTransfer.swift:1094` | UPDATE | updated_at_ms, status, brains_imported, detail | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_archive_origins` | `SQLiteArchiveTransfer.swift:247` | UPDATE | status, updated_at_ms, detail | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_archive_origins` | `SQLiteArchiveTransfer.swift:348` | UPDATE | updated_at_ms, source_schema_version, high_local_order, events_added, events_duplicate, events_renamed, applications_added, applications_duplicate, status, brains_imported, detail | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_archive_origins` | `SQLiteArchiveTransfer.swift:364` | UPDATE | detail | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_archive_origins` | `SQLiteArchiveTransfer.swift:995` | UPSERT | status, updated_at_ms, source_schema_version, detail | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_events` | `SQLiteObservationRows.swift:211` | UPDATE | capture_status | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_operation_arguments` | `SQLiteOperationFactRepository.swift:696` | UPDATE | text_value | Retained by Mutable tables for event rows only; DB2 adapts integer references. |
| `memory_qualification_policies` | `SQLiteProcedureRepository.swift:1127` | UPDATE | status, reason, changed_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_qualification_policies` | `SQLiteProcedureRepository.swift:518` | UPDATE | status, reason, changed_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_entries` | `SQLiteRecallRows.swift:140` | DELETE | row | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_generations` | `SQLiteRecallRepository.swift:103` | UPDATE | status, ready_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_generations` | `SQLiteRecallRepository.swift:113` | UPDATE | status, ended_at_ms, reason | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_generations` | `SQLiteRecallRepository.swift:123` | UPDATE | status, ended_at_ms, reason | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_generations` | `SQLiteRecallRepository.swift:215` | UPDATE | cursor_route_id, enumerated | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_generations` | `SQLiteRecallRepository.swift:99` | UPDATE | status, ended_at_ms, reason | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_work` | `SQLiteRecallRepository.swift:158` | UPDATE | done_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_recall_work` | `SQLiteRecallRepository.swift:167` | UPDATE | attempts, last_error | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_routes` | `SQLiteRouteRepository.swift:72` | UPDATE | status, last_used_ms, demoted_at_ms, demotion_cause | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_step_occurrences` | `SQLiteProcedureRepository.swift:657` | UPDATE | ended_at_ms, status | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_step_occurrences` | `SQLiteStepOccurrenceRepository.swift:46` | UPDATE | ended_at_ms, status | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_step_occurrences` | `SQLiteStepOccurrenceRepository.swift:75` | UPDATE | task_occurrence_id, step_id, assigned_by | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_task_occurrences` | `SQLiteTaskContextRepository.swift:120` | UPDATE | status, ended_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_task_occurrences` | `SQLiteTaskContextRepository.swift:159` | UPDATE | status, ended_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_task_occurrences` | `SQLiteTaskRepository.swift:92` | UPDATE | ended_at_ms, status | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_tasks` | `SQLiteTaskContextRepository.swift:124` | UPDATE | status, closed_at_ms | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_tasks` | `SQLiteTaskContextRepository.swift:78` | UPDATE | current_revision | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_verifications` | `SQLiteProcedureRepository.swift:688` | UPDATE | step_occurrence_id | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_verifications` | `SQLiteStepOccurrenceRepository.swift:100` | UPDATE | step_occurrence_id | Retained by Mutable tables; DB2 adapts integer references. |
| `memory_verifications` | `SQLiteTaskRepository.swift:55` | UPDATE | step_occurrence_id | Retained by Mutable tables; DB2 adapts integer references. |

Composed dispatch details: SQLiteArchiveTransfer.concluding (:86–104) sets status, brains_imported and detail in updates at :348 and :1094; the origin counters are incremented at :348. SQLiteBrainRows.retire (:805–819) dispatches only to anchors, groups and transitions. The three ON CONFLICT writers are shown explicitly, rather than inferred from their table name.

Read-only query strings and the words UPDATE/DELETE in comments do not authorize mutation. The table references include Tools test writers; they are separated from the normal product writer policy above.

## Complete source references

Each entry is the result of git grep -n -w for that table at the audited source revision under Sources and Tools. Resource references describe shape and constraints; tool scripts are test/read consumers unless the writer audit says otherwise. This index does not infer writability from an empty table.

| Table | Every reference by file and line |
| --- | --- |
| `brain_apps` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:82,91,100,113,151,234,269,295,353,631,761,777,810,833,2083,2158,2181,2329,2371,2749,2790`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:480`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:239,363,393`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:481,528`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:13,43,46,320`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteMenuCommandRepository.swift:120`; `Sources/Engine/SQLiteMemory/SQLiteObservationRows.swift:33,38,65,85`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:582,736,1059,1097,1515,1568`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:388`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:494,513`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:371`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:68`; `Tools/Engine/Scripts/verify-memory-schema.py:94`; `Tools/Engine/memory-probe/Probe.swift:38,43,337,525,540` |
| `brain_app_window_epochs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:90`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:13,50,328,336`; `Tools/Engine/Scripts/verify-memory-schema.py:258,259,260,262,264,265,266,1848` |
| `brain_app_contexts` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:98,372,2349`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:404`; `Sources/Engine/SQLiteMemory/SQLiteObservationRows.swift:50,57,86`; `Tools/Engine/Scripts/verify-memory-schema.py:95` |
| `brain_scenes` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:111,132,139,227,317,318,597,691,795,996,1035,1037,1043,1049,1055,1062,1068,1075,1081,1087,1094,1101,1108,1115,2189,2350,2351,2388,2678,2679,2719`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:154,209,227,321,336,344,408`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:100,544,552`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:153`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:328`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:14,138,292,314`; `Tools/Engine/Scripts/verify-memory-schema.py:96,122,194,325,328,329,330,331,332,333,334,335,589,619,971,1853` |
| `brain_scene_roles` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:131,1052,1059`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:152`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:326`; `Tools/Engine/Scripts/verify-memory-schema.py:338,585,975` |
| `brain_scene_labels` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:138,1065,1072`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:336`; `Tools/Engine/Scripts/verify-memory-schema.py:339` |
| `brain_anchors` | `Sources/Engine/Memory/Brain/BrainDecayReport.swift:12`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:50,149,181,189,228,264,319,668,692,796,865,991,2783,2789,2823,2826,2879`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:39,219,322,405`; `Sources/Engine/SQLiteMemory/SQLiteBrainRepository.swift:186`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:13,57,66,88,114,128,143,149,377,398,489,491,587,628,631,659,678,717,829`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:220`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:327`; `Tools/Engine/Scripts/verify-memory-schema.py:98,271,275,276,279,280,281,282,283,289,300,303,313,316,317,320,364,365,367,368,372,1849,1852` |
| `brain_anchor_aliases` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:180,2783`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:56,591,694,734,738,745,750`; `Tools/Engine/Scripts/verify-memory-schema.py:356,357,358,360,361,362,1851` |
| `brain_anchor_states` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:188`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:65,761,768`; `Tools/Engine/Scripts/verify-memory-schema.py:319` |
| `brain_scene_elements` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:198,226,325,693,1040,1046,2353`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:13,36,45,168,174,221,323,341,409`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:443`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:180,349`; `Tools/Engine/Scripts/verify-memory-schema.py:108,110,336,337,584,590,591,592,593,594,595,596,601,627` |
| `brain_groups` | `Sources/Engine/Memory/Brain/BrainDecayReport.swift:18`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:51,173,232,263,694,992`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:324,406`; `Sources/Engine/SQLiteMemory/SQLiteBrainRepository.swift:187`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:14,87,115,177,183,189,190,348,359,496,498,664,676,852`; `Tools/Engine/Scripts/verify-memory-schema.py:268,272,273,290,304,370` |
| `brain_group_members` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:147,256,2827`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:86,663,677,706,717,782,786,793,798`; `Tools/Engine/Scripts/verify-memory-schema.py:269,274,277,373,374,375,376,377,378,379` |
| `brain_menu_commands` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:267,284,320,695,866,1025`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:69`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:224,325,411`; `Sources/Engine/SQLiteMemory/SQLiteMenuCommandRepository.swift:12,53,72,95,120`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:329` |
| `brain_menu_path_segments` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:283`; `Sources/Engine/SQLiteMemory/SQLiteMenuCommandRepository.swift:12,106,134` |
| `brain_transitions` | `Sources/Engine/Memory/Brain/BrainDecayReport.swift:25`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:60,293,333,669,696,993,1023,1024,1104,1111,1426`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:150`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:13,57,68,98,114,151,239,250,326,344,407,410`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:14,116,220,230,240,246,271,277,425,432,454,481,483`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:71`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:229`; `Tools/Engine/Scripts/verify-memory-schema.py:125,200,291,301,302,305,310,343,344,345,352,353,371` |
| `brain_transition_menu_items` | `Sources/Engine/Memory/Brain/TransitionEffectRecord.swift:15`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:332`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:14,81,265`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:219,473` |
| `memory_events` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:342,350,362,376,403,409,453,454,540,596,601,609,614,615,665,690,711,908,981,1018,1019,1020,1126,1128,1134,1285,1288,1297,1300,1423,1739,1789`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:14,47,73,86,174,352,416`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:285,477,557,828,1069,1074`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:413,414,425`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:309,334,348,377`; `Sources/Engine/SQLiteMemory/SQLiteCaptureRepository.swift:12`; `Sources/Engine/SQLiteMemory/SQLiteExperienceRepository.swift:75,196`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:227`; `Sources/Engine/SQLiteMemory/SQLiteObservationRows.swift:74,84,149,173,180,211`; `Sources/Engine/SQLiteMemory/SQLiteObservedInputRepository.swift:83,214`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1515,1567`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:494,513`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:78,121,144`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:184`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:197`; `Sources/Engine/SQLiteMemory/SQLiteTraceRepository.swift:10,37,47,68,77,81,96,109`; `Tools/Engine/Scripts/measure-memory-store.sh:39`; `Tools/Engine/Scripts/verify-memory-schema.py:75,182,191,254,390,391,392,486,490,533`; `Tools/Engine/memory-probe/Probe.swift:489,494,514,594,650,670` |
| `memory_input_events` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:375`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:67`; `Sources/Engine/SQLiteMemory/SQLiteObservedInputRepository.swift:13,47,107,122,124`; `Tools/Engine/Scripts/verify-memory-schema.py:116,192` |
| `memory_agent_actions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:61,408,460,469,478,517,830,864,1131,1133,1139,1141,1150,1158,1166,1191,1233,1245,1596,1611,1631,1638,1654,1669,1677,1726,1922,1935,1947,1961,1973,2021,2081,2291,2301,2360,2370,2437,2440,2442,2459,2697,2747,2850,2868,3210,3596,3768,3775,3789,3829,3857,3866,3870,3898,3912,3926,4000`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:15,73,86,96,173,189,231,416`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:720`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:309,334,397`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:222,225,226,230`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:581,590,1514,1525,1568`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:466`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:77,143`; `Sources/Engine/SQLiteMemory/SQLiteTraceRepository.swift:68`; `Tools/Engine/Scripts/measure-reuse.py:116`; `Tools/Engine/Scripts/verify-memory-schema.py:160,174,180,384,387,388,389,394,395,397,399,403,407,408,409,410,411,412,413,414,415,416,418,419,424,425,426,427,432,433,439,441,449,453,464,476,484,547,725,728,790,794,843,1003,1716,1719,1809` |
| `memory_agent_action_effect_labels` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:429,459,1146`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:248,437`; `Tools/Engine/Scripts/verify-memory-schema.py:398,402,404,421,428,442` |
| `memory_agent_action_status` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:468,1154`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:271,513`; `Tools/Engine/Scripts/verify-memory-schema.py:450,451` |
| `memory_agent_action_listings` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:477,488,1162,1174,1184`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:279,523`; `Tools/Engine/Scripts/verify-memory-schema.py:454,455,465,473` |
| `memory_agent_action_applications` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:487,510,1170`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:285,537`; `Tools/Engine/Scripts/verify-memory-schema.py:456,457,458,459,466,467,468,469,470` |
| `memory_agent_action_windows` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:503,1180`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:298,529`; `Tools/Engine/Scripts/verify-memory-schema.py:460,461,462,472` |
| `memory_agent_action_observations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:516,1187`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:320,562`; `Tools/Engine/Scripts/verify-memory-schema.py:477,479,480` |
| `memory_event_observations` | `Sources/Engine/Memory/Observation/ObservationKind.swift:8`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:57,527,538,579,667,1006,1345,1350,1360,1365,1375,1389,1402,1718`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:310`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:919,939`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:259`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:414`; `Sources/Engine/SQLiteMemory/SQLiteCaptureRepository.swift:13`; `Sources/Engine/SQLiteMemory/SQLiteObservationRows.swift:200,217,322,542,566,588`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:533`; `Tools/Engine/Scripts/verify-memory-schema.py:81,118,543,552,554,556,564,565,566,580,581,582,655,656,657,698,699,880` |
| `memory_event_scenes` | `Sources/Engine/Memory/Observation/SceneStructureMatcher.swift:39`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:585,1007,1078,1084,1342,1357,1379,1394,1406`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:350`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:626`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:171,503`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:14,245,275`; `Tools/Engine/Scripts/verify-memory-schema.py:120,193,195,340,341,570,571,572,573,575,576,577,579` |
| `memory_verifications` | `Sources/Engine/Memory/Calls/OperationFact.swift:88`; `Sources/Engine/Memory/Tasks/TaskResultCheck.swift:13`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:600,905,1248,1254,1263,1266,1274,1464,1606,1676,1985`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:67`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:280,305`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:505,561`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:300,682,688,1253,1541`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:478`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:100`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:12,34,55,136,139`; `Tools/Engine/Scripts/verify-memory-schema.py:508,511,517,875,885,890,894,1725` |
| `memory_action_correlations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:613,1282,1294`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:67`; `Sources/Engine/SQLiteMemory/SQLiteObservedInputRepository.swift:14,67,83,172,175`; `Tools/Engine/Scripts/verify-memory-schema.py:519,521,523,524` |
| `brain_applications` | `Sources/Engine/Memory/Brain/BrainApplication.swift:14,278`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:54,629,867,1015,1016,1017,1417,1429,1434,1443`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:950`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:19,186,246,281,370,407,480`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:71`; `Tools/Engine/Scripts/verify-memory-schema.py:652,670,689,690,705,706,709` |
| `brain_evidence` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:628,674,998,999,1000,1001,1002,1003,1026,1090,1097`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:27,243,343,349`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:14,131,363,368,396,399`; `Tools/Engine/Scripts/verify-memory-schema.py:128,197,198,199,250,285,287,309,321,342,348,350,1850` |
| `memory_task_occurrences` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:699,710,720,893,918,1461,1531,1534`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:67`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:423`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:13,120,159,442,453`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:67,92,166,175,178`; `Tools/Engine/Scripts/verify-memory-schema.py:130,534,738,772` |
| `memory_task_events` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:709,1027,1594,2444,3459,3694,3974,3975`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:68`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:101,102,118,127`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:279,304`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:268`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:306,580,1253,1276,1514,1570`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:466`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:208`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:67,210,217,222,227`; `Tools/Engine/Scripts/verify-memory-schema.py:131,541,741,993,1005,1721,1723` |
| `memory_task_labels` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:718,1021`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:68`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:67,244,256,260,270,277`; `Tools/Engine/Scripts/verify-memory-schema.py:132,537` |
| `memory_routes` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:728,732,742,757,762,917,939,2123,2126,2130,3241,3254`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:68`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:419`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:345,346,840,1021,1171,1215,1322,1624,1654`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:135`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:13,72,97,192,356,365,398`; `Tools/Engine/Scripts/verify-memory-schema.py:100,527,536,1032,1059,1065,1207,1274,1312,1419` |
| `memory_route_parameters` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:740,797,862,875,876,886,887,962,2188,2202,2225,2242,3752,3822`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:14,177,201,340,344`; `Tools/Engine/Scripts/verify-memory-schema.py:103,228,1034,1112,1640` |
| `memory_route_steps` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:755,793,794,815,816,885,894,926,943,1197,1205,1211,1217,1223,1305,1313,2169,2254,2506,2538,3989`; `Sources/Engine/SQLiteMemory/SQLiteExperienceRepository.swift:33`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:980,1172`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:14,179,211,371,378,385`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:59`; `Tools/Engine/Scripts/verify-memory-schema.py:101,185,495,502,503,525,526,528,529,1033,1086` |
| `memory_step_checks` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:773,1214,1216,1220,1222`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:14,180,230,423,429`; `Tools/Engine/Scripts/verify-memory-schema.py:139,213,311,494` |
| `memory_step_operations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:802,817,829,861,863,1008,1009,1202,1204,1208,1210,1230,1242,1321,1329,2224,3821,3991`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:14,182,183,271,461,466,469,472,480,487`; `Tools/Engine/Scripts/verify-memory-schema.py:105,202,214,492,493,496,498,531,532,1036` |
| `memory_operation_arguments` | `Sources/Engine/Memory/Calls/AgentCallArguments.swift:12`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:56,406,827,1010,1011,1014,1226,1238,1420,1439,1446,1452,2208,2560,2565,3983`; `Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:15,188,586`; `Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:187,247,383,561`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:221`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:684,696`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:15,314,560,566`; `Tools/Engine/Scripts/verify-memory-schema.py:88,141,164,203,204,205,206,207,208,209,499,500,501,638,692,693,694,695,696,697,702,710,716` |
| `memory_route_call_bindings` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:871`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:15,257,403,405,590`; `Tools/Engine/Scripts/verify-memory-schema.py:187,211,212` |
| `memory_step_occurrences` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:603,891,907,933,1022,2080,2246,2251`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:68`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:424`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:657,664`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:12,31,46,75,161,166,172,176`; `Sources/Engine/SQLiteMemory/SQLiteTaskRepository.swift:47`; `Tools/Engine/Scripts/verify-memory-schema.py:134,506,535,980,988,1006,1813` |
| `memory_step_events` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:906,1028,1250,1259,1269,1277,2448`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1032,1156,1272,1361,1536`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:170,181,200`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:12,204,213,218,224`; `Tools/Engine/Scripts/verify-memory-schema.py:136,509,510,512,514,515,540,982,990,1007,1815` |
| `memory_route_evidence` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:916`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:13,128,234`; `Tools/Engine/Scripts/verify-memory-schema.py:538` |
| `memory_step_evidence` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:925`; `Sources/Engine/SQLiteMemory/SQLiteStepOccurrenceRepository.swift:13,132,236`; `Tools/Engine/Scripts/verify-memory-schema.py:137,201,539` |
| `memory_experiences` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:936,960,980`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:68`; `Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:422`; `Sources/Engine/SQLiteMemory/SQLiteExperienceRepository.swift:12,40,94,102,140,179`; `Tools/Engine/Scripts/verify-memory-schema.py:222` |
| `memory_experience_bindings` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:947`; `Sources/Engine/SQLiteMemory/SQLiteExperienceRepository.swift:12,61,144,149`; `Tools/Engine/Scripts/verify-memory-schema.py:224,230,235,236,237,238,239,240,241,242,243,244` |
| `memory_experience_uses` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:979`; `Sources/Engine/SQLiteMemory/SQLiteExperienceRepository.swift:15,82,196,203`; `Tools/Engine/Scripts/verify-memory-schema.py:542` |
| `memory_schema_migrations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1471`; `Sources/Engine/SQLiteMemory/SQLiteMemoryStore.swift:860,1017`; `Tools/Engine/Scripts/verify-memory-schema.py:964,965,1201,1290,1326,1563,1704` |
| `memory_tasks` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1484,1500,1535,1569,1823,1837,1839,1842,1851`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:69`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:309`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:11,78,124,226,241,248`; `Tools/Engine/Scripts/measure-reuse.py:110`; `Tools/Engine/Scripts/verify-memory-schema.py:729,768,769,770,781,784` |
| `memory_task_revisions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1499,1517,1528,1546,1562,1589,1601,1848,1856,1861,1864`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:288`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:283,316,324`; `Tools/Engine/Scripts/measure-reuse.py:114`; `Tools/Engine/Scripts/verify-memory-schema.py:731,748,750,752` |
| `memory_task_constraints` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1511,1867`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:294,327`; `Tools/Engine/Scripts/verify-memory-schema.py:732` |
| `memory_task_message_refs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1521,1872`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:302,331`; `Tools/Engine/Scripts/verify-memory-schema.py:733,753` |
| `memory_task_attempts` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1533,1537,1561,1600,1882,1887,1891,2073,2142,2233,3113,3528`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:134`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:279,289,290,304`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:257`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:13,423,441,452,464`; `Tools/Engine/Scripts/verify-memory-schema.py:739,773` |
| `memory_task_checkpoints` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1550,1590,1821,1895,1900,1903,1905,2074`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1173,1216`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:487,505,512,516`; `Tools/Engine/Scripts/measure-reuse.py:118`; `Tools/Engine/Scripts/verify-memory-schema.py:743,775,777,779,782` |
| `memory_task_values` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1567,1813,1815,1817,1819,1877`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:134`; `Sources/Engine/SQLiteMemory/SQLiteTaskContextRepository.swift:361,383,393,400`; `Tools/Engine/Scripts/verify-memory-schema.py:734,736,745,755,758,761,765` |
| `memory_task_call_revisions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1595,1824,1909`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:276,287`; `Tools/Engine/Scripts/measure-reuse.py:116`; `Tools/Engine/Scripts/verify-memory-schema.py:742` |
| `memory_call_effects` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1610,1914,1919`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:69`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:332,471,477`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:79`; `Tools/Engine/Scripts/verify-memory-schema.py:787,789,792,796,798,799` |
| `memory_call_routes` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1630,1927,1932`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:72`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:62`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:356,364,368`; `Tools/Engine/Scripts/verify-memory-schema.py:801,802,803,804,805,807,809` |
| `memory_call_adapter_dispatches` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1637,1939,1944`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:73`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:66`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:384,454,458`; `Tools/Engine/Scripts/verify-memory-schema.py:812,813,815,817,819,822` |
| `memory_call_rungs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1653,1953,1958`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:73`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:404,412,416`; `Tools/Engine/Scripts/verify-memory-schema.py:825,826,827,828,829,830,831,835,836,837,838,845,846,847,848` |
| `memory_call_route_advice` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1668,1965,1970`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:74`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:433,441,446`; `Tools/Engine/Scripts/verify-memory-schema.py:853,855,856,857,858,859,860,861,862,863,864,868,869,870,871,872` |
| `memory_operation_verifications` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1675,1697,1708,1825,1977,1982,2302,2362,2627,2695,2775,2866`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:393`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:158,514,561,576`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:578,675,1139,1306,1540`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:478`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:121`; `Tools/Engine/Scripts/verify-memory-schema.py:876,887,891,895,902,1726,1728` |
| `memory_operation_verification_limits` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1696,1988`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:58`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:526,579,584`; `Tools/Engine/Scripts/verify-memory-schema.py:878,897` |
| `memory_operation_verification_samples` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1707,1993`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:544,590,597`; `Tools/Engine/Scripts/verify-memory-schema.py:881,899` |
| `memory_call_recording_gaps` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1725,2008,2013,2018`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:648,658,663`; `Tools/Engine/Scripts/verify-memory-schema.py:926,927,928,930,932,934,936,937` |
| `memory_value_redactions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1737,1826,1998,2003`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:69`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:387`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:54`; `Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:615,624,711,717,727,743,751,755`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:603,614`; `Tools/Engine/Scripts/verify-memory-schema.py:904,906,908,910,912,914,916,917,918,920,922,924,1713` |
| `memory_archive_origins` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1768,1787,1804`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:35,89,93,100,247,256,348,364,480,995,1015,1036,1056,1094,1104`; `Tools/Engine/Scripts/verify-memory-schema.py:938,961,963` |
| `memory_origin_events` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1786,1829,2025`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:22,668,905,1015`; `Tools/Engine/Scripts/verify-memory-schema.py:940,941,943` |
| `memory_origin_brain_contributions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:1803,2030,2035`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:70,88,92,99,751,852`; `Sources/Engine/SQLiteMemory/SQLiteBrainRepository.swift:200`; `Tools/Engine/Scripts/verify-memory-schema.py:944,946,948,950,952,955,956,957,959` |
| `memory_procedure_candidates` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2060,2078,2100,2141,2398,2412,2417,2444`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:70`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:296,297`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:77,703,727,752,759,1582`; `Tools/Engine/Scripts/measure-reuse.py:125,126`; `Tools/Engine/Scripts/verify-memory-schema.py:983,1010,1012,1015,1816` |
| `memory_candidate_steps` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2077,2399,2422,2427,2434,2451,2454`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:714,736,746,991`; `Tools/Engine/Scripts/verify-memory-schema.py:985,991,994,996,998,1000,1008,1016,1818,1820,1822` |
| `memory_procedure_interpretations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2098,2113,2131,2462,2467,2472,2475,2502`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:298`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:778,785,795,940,950`; `Tools/Engine/Scripts/measure-reuse.py:124`; `Tools/Engine/Scripts/verify-memory-schema.py:1018,1020,1023,1026,1060,1066,1208,1275,1313,1421` |
| `memory_interpretation_findings` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2112,2479,2484`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:805,1080,1086`; `Tools/Engine/Scripts/verify-memory-schema.py:1027,1029` |
| `memory_procedure_versions` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2129,2136,2152,2397,2489,2494,2499,2804,2885,2887,2918,2934,2936,3050,3072,3150,3248,3256,3552`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:290`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:140,342,416,465,819,825,839,850,940,953,1169,1189,1214,1586,1624`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:135`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:418`; `Tools/Engine/Scripts/measure-reuse.py:123`; `Tools/Engine/Scripts/verify-memory-schema.py:1055,1057,1062,1068,1210,1277,1315,1423` |
| `memory_procedure_parts` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2150,2168,2187,2203,2273,2311,2395,2396,2509,2514,2521,2526,2534,3049,3153,3263,3271,3356,3422,3425,3742,3989`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:433,480,861,1059,1068,1195,1338,1649,1656,1668`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:209,387`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:283`; `Tools/Engine/Scripts/verify-memory-schema.py:1071,1073,1076,1078,1080,1083,1087,1089,1091,1092` |
| `memory_part_contract_items` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2175,2400,2541,3240`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:884,1097,1104`; `Tools/Engine/Scripts/verify-memory-schema.py:1094,1095,1096,1097,1099,1101,1103` |
| `memory_parameter_details` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2194,2546,2583,3239`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:872,920,928`; `Tools/Engine/Scripts/verify-memory-schema.py:1105,1113` |
| `memory_operation_argument_segments` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2210,2551,2557,2569,3985`; `Sources/Engine/SQLiteMemory/SQLiteRouteRepository.swift:286,502,516,527`; `Tools/Engine/Scripts/verify-memory-schema.py:1037,1039,1045,1048,1051` |
| `memory_parameter_bindings` | `Sources/Engine/Memory/Recall/RecallSource.swift:208`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2230,2574,2579,3238`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:900,960,971`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:256`; `Tools/Engine/Scripts/verify-memory-schema.py:1107,1109,1110,1114,1116` |
| `memory_procedure_step_occurrences` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2248,2586`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:910,979,1155,1365`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:169,180,199`; `Tools/Engine/Scripts/verify-memory-schema.py:1117,1118` |
| `memory_qualification_policies` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2263,2275,2649,2657,3276,3284`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:513,518,524,1119,1127,1652`; `Tools/Engine/Scripts/verify-memory-schema.py:1122,1143,1144,1145,1425,1427,1428` |
| `memory_part_qualifications` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2272,2294,2305,2401,2591,2596,2601,2604,2615,3260`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:434,435,1196,1197,1338,1428,1432,1463,1650,1651`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:145`; `Tools/Engine/Scripts/verify-memory-schema.py:1123,1128,1136,1140,1141,1409` |
| `memory_part_qualification_reasons` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2281,2607,2612`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1441,1471,1477`; `Tools/Engine/Scripts/verify-memory-schema.py:1125,1126,1132,1134` |
| `memory_part_qualification_evidence` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2297,2619,2624`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1198,1451,1483`; `Tools/Engine/Scripts/verify-memory-schema.py:1130,1138,1411` |
| `memory_part_states` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2310,2631,2636,2641,2644,2645,3268`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:484,496,1335,1336,1494,1497,1661`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:147`; `Tools/Engine/Scripts/verify-memory-schema.py:1146,1148,1150,1152,1413,1417` |
| `brain_relations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2327,2359,2402,2404,2665,2670,2675,2698,2771,2869`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:71`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:255,449,465,481,490,528`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1606`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:183,522`; `Tools/Engine/Scripts/verify-memory-schema.py:1155,1158,1160,1164,1168,1171,1174,1176,1178,1181,1183,1184` |
| `brain_relation_proofs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2358,2405,2682,2687,2692,2724`; `Tools/Engine/Scripts/verify-memory-schema.py:1185,1187,1189,1191,1193,1219` |
| `brain_relation_applications` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2369,2701,2706,2724`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:71`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:333`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1553`; `Tools/Engine/Scripts/verify-memory-schema.py:1194,1196,1198,1200,1218` |
| `brain_scene_shapes` | `Sources/Engine/Memory/Observation/SceneSkeleton.swift:153`; `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2384,2406,2711,2716`; `Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift:150`; `Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:129,132,331`; `Tools/Engine/Scripts/verify-memory-schema.py:973,974,977,978` |
| `brain_relation_evaluations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2746,2779,2816,2817,2818,2833,2838,2843,2846,2871`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:71`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:18,169,272,291,293,308,311,337,348,350,502,550,558,562`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1548,1600`; `Tools/Engine/Scripts/verify-memory-schema.py:1222,1224,1228,1231,1235,1237,1238,1239,1241,1243,1246,1248` |
| `brain_relation_evidence` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2770,2819,2853,2858,2863`; `Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:168,248,501,567`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:1599`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:182,522`; `Tools/Engine/Scripts/verify-memory-schema.py:1226,1251,1254,1257,1260,1263,1264` |
| `brain_anchor_label_keys` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2788,2820,2876`; `Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:575,577,597,627`; `Sources/Engine/SQLiteMemory/SQLiteMemoryStore.swift:852`; `Tools/Engine/Scripts/verify-memory-schema.py:1266,1268,1270,1271` |
| `memory_variant_prefixes` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2803,2882,2890,2895,2904`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:71`; `Tools/Engine/Scripts/verify-memory-schema.py:1215,1216,1279,1281,1283,1285,1286,1288,1289,1298` |
| `memory_variant_prefix_checks` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2905,2917,2931,2939,2944`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:72`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:243,1038,1041,1044`; `Tools/Engine/Scripts/verify-memory-schema.py:1297,1300,1303,1306,1308,1309,1310,1317,1319,1321,1323,1325` |
| `memory_recall_spaces` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2972,2999,3032,3296,3301,3343`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:50`; `Tools/Engine/Scripts/verify-memory-schema.py:1338,1341,1344,1347,1348` |
| `memory_recall_generations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:2996,3014,3015,3048,3101,3306,3312,3330,3354,3360,3365,3370,3519`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:74,78,92,96,99,103,113,123,215,367,406`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:24,31`; `Tools/Engine/Scripts/measure-reuse.py:130,142`; `Tools/Engine/Scripts/verify-memory-schema.py:1350,1352,1354,1357,1359,1361,1377,1386,1387,1389,1391,1393,1394,1395,1397,1398,1400,1405` |
| `memory_recall_documents` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3024,3033,3052,3335,3359`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:241,386`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:119`; `Tools/Engine/Scripts/verify-memory-schema.py:1364,1365,1373` |
| `memory_recall_vectors` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3031,3340,3346`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:242,266,354,389`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:46`; `Tools/Engine/Scripts/measure-reuse.py:141`; `Tools/Engine/Scripts/verify-memory-schema.py:1366,1368,1370,1372` |
| `memory_recall_entries` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3047,3059,3060,3351,3363,3368,3374`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:382`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:240,385,396,599`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:45,94,127,140`; `Tools/Engine/Scripts/measure-reuse.py:130`; `Tools/Engine/Scripts/verify-memory-schema.py:1375,1379,1382,1385,1401,1404` |
| `memory_recall_work` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3070,3082,3083,3250,3252,3253,3257,3262,3265,3270,3273,3279,3281,3287,3289,3379,3390`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:377`; `Sources/Engine/SQLiteMemory/SQLiteMemoryStore.swift:853`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:146,158,167,177,178,338,370,596,613`; `Tools/Engine/Scripts/verify-memory-schema.py:1334,1415,1416,1430,1434,1436,1438,1439,1440,1441,1442` |
| `memory_recall_queries` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3092,3120,3127,3399,3404,3459,3569,3654,3694`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:72`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:295`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:343,1318`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:77`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:568`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:325,437`; `Tools/Engine/Scripts/measure-reuse.py:122`; `Tools/Engine/Scripts/verify-memory-schema.py:1453,1481,1482` |
| `memory_recall_needs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3126,3157,3216,3232,3409,3414,3428,3431,3583,3602,3677`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:89`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:571`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:340,395`; `Tools/Engine/Scripts/verify-memory-schema.py:1456,1472,1483,1485,1487,1489,1528,1541,1543,1598,1643,1667,1676,1681,1689,1696,1701` |
| `memory_recall_selections` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3145,3188,3242,3419,3435,3440,3463,3603,3673,3675,3698,3732,3735,3742,3748,3752`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:344,1320`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:175`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:99`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:280,348,401,437`; `Tools/Engine/Scripts/verify-memory-schema.py:1457,1490,1493,1496,1499,1529,1560,1599,1601,1645,1669,1682,1690` |
| `memory_recall_requirements` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3170,3445,3450,3727`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:109`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:358,409,448`; `Tools/Engine/Scripts/verify-memory-schema.py:1459,1461,1500,1502,1504,1506,1508,1510,1512,1531,1533,1535,1537,1545,1547,1549,1551,1553,1555,1557,1647,1650,1652,1654,1657,1659` |
| `memory_recall_links` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3207,3455,3467,3472,3714`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:123`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:534`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:285`; `Tools/Engine/Scripts/verify-memory-schema.py:1463,1465,1513,1515,1517,1518,1635` |
| `memory_recall_reports` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3223,3477,3480,3484,3489`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:340`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:138`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:551,556`; `Tools/Engine/Scripts/verify-memory-schema.py:1466,1467,1520,1522,1524,1525` |
| `memory_recall_proposals` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3510,3533,3537,3570,3613,3618,3654`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:292,293`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:266`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:46,90`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:23`; `Tools/Engine/Scripts/measure-reuse.py:120`; `Tools/Engine/Scripts/verify-memory-schema.py:1576,1595` |
| `memory_recall_proposal_needs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3536,3557,3623,3628`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:60,104`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:33`; `Tools/Engine/Scripts/verify-memory-schema.py:1579,1663` |
| `memory_recall_proposal_sources` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3547,3633,3636,3640,3645`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:267`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:70,109,164`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:39`; `Tools/Engine/Scripts/verify-memory-schema.py:1580,1582,1585,1587,1589,1591,1596,1664,1665` |
| `memory_recall_choices` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3568,3577,3593,3650,3659,3664,3717`; `Sources/Engine/SQLiteMemory/SQLiteMemoryInspection.swift:293`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:269,1319`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:160,200`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:49,76`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:436`; `Tools/Engine/Scripts/verify-memory-schema.py:1603,1611,1614,1616,1637,1671,1677,1685,1692,1697,1702` |
| `memory_recall_choice_needs` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3576,3669,3680,3685`; `Sources/Engine/SQLiteMemory/SQLiteRecallChoices.swift:168,204`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:52`; `Tools/Engine/Scripts/verify-memory-schema.py:1604,1617,1619,1621,1623,1638,1672,1678,1686,1693,1698,1703` |
| `memory_recall_choice_links` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3592,3690,3703,3708`; `Sources/Engine/SQLiteMemory/SQLiteRecallInspectionRows.swift:127`; `Sources/Engine/SQLiteMemory/SQLiteRecallRepository.swift:522`; `Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift:287`; `Tools/Engine/Scripts/verify-memory-schema.py:1605,1607,1625,1627,1629,1631,1633,1639` |
| `memory_call_argument_fields` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3767,3887,3891,3895,3969`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:74`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:68,147`; `Sources/Engine/SQLiteMemory/SQLiteProcedureRepository.swift:579,1384`; `Tools/Engine/Scripts/verify-memory-schema.py:1746,1748,1750,1752,1754,1757,1759` |
| `memory_call_result_fields` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3788,3883,3901,3905,3909,3973`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:74`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:33,44,100,118,127`; `Tools/Engine/Scripts/verify-memory-schema.py:1732,1733,1735,1736,1738,1740,1742,1744,1745` |
| `memory_operation_argument_fields` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3803,3929,3933,3980`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:75`; `Tools/Engine/Scripts/verify-memory-schema.py:1763,1765,1767,1769,1772` |
| `memory_call_data_contexts` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3828,3915,3919,3923`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:75`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:195,219`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:80`; `Tools/Engine/Scripts/verify-memory-schema.py:1777,1779,1780,1782,1784,1786` |
| `memory_identity_salts` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3842,3937,3941`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:75`; `Sources/Engine/SQLiteMemory/SQLiteCallFieldRows.swift:233,234`; `Tools/Engine/Scripts/verify-memory-schema.py:1788,1789` |
| `memory_executors` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3849,3858,3945,3949`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:75`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:17`; `Tools/Engine/Scripts/verify-memory-schema.py:1792` |
| `memory_call_executors` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3856,3953,3957`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:76`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:20,29,81,145`; `Tools/Engine/Scripts/verify-memory-schema.py:1793,1794` |
| `memory_call_reconciliations` | `Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql:3865,3884,3961,3965,3994,3997`; `Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:76`; `Sources/Engine/SQLiteMemory/SQLiteReconciliationRows.swift:42,46,58,147`; `Tools/Engine/Scripts/verify-memory-schema.py:1795,1797,1799,1801,1803,1805,1807,1808` |


## Frozen tables

Every listed table accepts conversion rows after tables and rejects INSERT after triggers. History also rejects UPDATE and DELETE; controlled content replacement is described separately.

| Table | Reason and evidence |
| --- | --- |
| `brain_anchors` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_anchor_aliases` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_anchor_states` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_groups` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_group_members` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_transitions` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_transition_menu_items` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_anchor_label_keys` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_applications` | Explicit R-G-09 projection freeze; source writers are inventoried above. |
| `brain_relation_applications` | No normal, import, initialization, rare or future writer: SQLiteBrainRelationRepository:333 and SQLiteProcedureRepository:1553 read historic rows; SQLiteArchiveTransfer:71 is an exclusion list. Current relation writes use evaluations/evidence; BR5 revives proofs instead. |
| `memory_variant_prefixes` | No normal, import, initialization, rare or future writer: SQLiteArchiveTransfer:71 is an exclusion list. SQLiteProcedureRepository:1038 writes memory_variant_prefix_checks instead. |

## Mutable tables

The test reads this exact allowlist. All other tables reject UPDATE and DELETE. `*` means every column of rebuildable derived data; `none` permits no UPDATE.
An UPDATE naming an unlisted column is refused even if it assigns the same value. Deleted derived rows are not deleted facts.

| Table | Columns allowed in UPDATE | DELETE | Writer / transition |
| --- | --- | --- | --- |
| `brain_apps` | ingest_epoch, last_epoch_advance_ms | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `brain_app_window_epochs` | epoch | yes | Normal source writes in the reference inventory; identity columns remain protected. |
| `brain_scenes` | last_seen_ms, observation_count | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `brain_scene_elements` | anchor_id | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `brain_menu_commands` | top_level_title, accessibility_identifier, has_submenu, last_observed_enabled, mark_char, cmd_char, last_seen_ms | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_events` | capture_status | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_agent_actions` | execution_status, started_at_ms, completed_at_ms, duration_ms, result_kind, result_message, observed_effect_kind, observed_effect_text, observed_state_before, observed_state_after, observed_effect_label, observed_effect_value, attempted_count, verified_count, gesture, effect, effect_reason, recovery, recovery_reason, outcome_origin, learnable | no | Existing lifecycle/result columns retain inventoried updates. ES1 transition: gesture, effect, effect_reason, recovery, recovery_reason, outcome_origin and learnable are set once, never rewritten. A NULL column may be filled; any UPDATE naming it after its OLD value is non-NULL fails, including no-op and clearing writes. No source writer updates these seven columns today. Identity remains protected. |
| `memory_verifications` | step_occurrence_id | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_task_occurrences` | ended_at_ms, status | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_routes` | status, last_used_ms, demoted_at_ms, demotion_cause | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_operation_arguments` | text_value | no | SQLiteOperationFactRepository.withdraw:696 updates text_value only on call/event rows (OLD.event_id IS NOT NULL). Procedure-version literals and projection application inputs cannot be rewritten, including no-op updates. |
| `memory_step_occurrences` | task_occurrence_id, step_id, ended_at_ms, status, assigned_by | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_tasks` | status, closed_at_ms, current_revision | no | TU13/EC5: open ↔ postponed, then terminal; current_revision never decreases. Terminal rows cannot move. |
| `memory_task_attempts` | takeover | no | EE4/PP1: none → person_episode; repeating the same takeover value is allowed. |
| `memory_archive_origins` | status, updated_at_ms, source_schema_version, high_local_order, events_added, events_duplicate, events_renamed, applications_added, applications_duplicate, brains_imported, detail | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_qualification_policies` | status, changed_at_ms, reason | no | SQLiteProcedureRepository:518,1127 updates status/reason/time. Retained policy-update trigger queues derived Recall work. |
| `memory_part_qualifications` | complete | no | ME7: only complete 0 → 1, once; all other fields and DELETE refused. |
| `brain_relations` | last_seen_ms | no | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_recall_generations` | * | yes | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_recall_documents` | * | yes | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_recall_vectors` | * | yes | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_recall_entries` | * | yes | Derived entry deletion remains allowed; retained deletion trigger increments the generation revision. |
| `memory_recall_work` | * | yes | Normal source writes in the reference inventory; identity columns remain protected. |
| `memory_phase_families` | * | yes | Rebuildable derived rows (R-G-18). |
| `memory_phase_family_attempts` | * | yes | Rebuildable derived rows (R-G-18). |
| `memory_recall_texts` | * | yes | Rebuildable derived rows (R-G-18). |
| `memory_recall_text_pieces` | * | yes | Rebuildable derived rows (R-G-18). |
| `memory_recall_calibration` | used | no | ME3/ME6: used NULL → 0/1, once; adapted parts also count as used. |
| `memory_part_reuse` | * | yes | Rebuildable derived rows (R-G-18). |
| `memory_consolidation_queue` | none | yes | SK4: dequeue by DELETE; never UPDATE; unknown jobs remain queued. |
| `memory_consolidation_cursors` | last_seq, algorithm_version, generation, backfill_after_fact_id, backfill_until_fact_id, queue_from_seq, continuation | no | Rebuildable derived rows (R-G-18). |
## Declared exceptions

BR3 may replace instance-bearing method content only in one store.write transaction: temporarily drop the exact affected BEFORE UPDATE triggers, scrub method text, recompute its canonical digest, set replaced_by_id for a collision to the older equivalent row, then recreate the identical trigger SQL before commit. References to both rows remain intact. No row is deleted. Partial UNIQUE indexes apply only to live content rows in memory_elements, memory_element_sets, brain_element_keys, brain_scene_elements and brain_anchor_label_keys (R-G-13, R-X-13).

VK4 forgets episode values through the same controlled transaction pattern, dropping and recreating only the BEFORE UPDATE triggers of memory_task_values and memory_parameter_bindings. The only value-bearing columns in those tables are text_value and value_digest: set both NULL and content = withheld. source_ref remains an event/output reference, never a value. The ordinary DDL stays immutable; no broad exception is installed.

## Closed codes

| Field | Approved values |
| --- | --- |
| recorded_by | braus, person, import |
| reason_code | qualified, requalified, policy_quarantined, superseded, judged_wrong, retired_by_person, retired_by_curation, forgotten_by_person, merged_same_screen, split_distinct_surfaces, imported, migrated |
| part state | usable, to_reevaluate, retired |
| task status | open, completed, failed, abandoned, postponed |
| todo status | pending, in_progress, done, abandoned |
| todo change | drafted, revised, row_started, row_finished, stopped, postponed, resumed |
| gesture | sent, not_sent, uncertain |
| effect | confirmed, absent, unknown |
| effect_reason | still_changing, not_watched, not_classified, not_readable, not_applicable; present iff effect is unknown |
| recovery | continue, observe, do_not_repeat, change_target, ask_person, retry, postpone |
| recovery_reason | not_found, ambiguous, unreachable, disabled, destructive, not_permitted; present iff recovery is change_target |
| capability origin | core, adapter, registered; origin_name absent iff core |
| capability channel | seat, native, web, adapter, connector, command, braus |
| effect_class | read, write, irreversible |

R-G-32 applies identically to memory_part_states, memory_part_judgments and brain_scene_merges. recorded_by = import requires origin_id; local rows have no origin_id.
R-A-50: at most 10 todo rows and 160 characters per expectation are TU6 code limits; title length 1–120 is also a DDL CHECK. R-A-51: no second todo level; recorded gestures are associated by memory_call_steps. R-I-37 uses memory_task_end_checks and terminal task status before continuation in a new task; the row-limit refusal text is a TU6 code responsibility.
R-E-06 is superseded by R-E-40: the five outcome columns on memory_agent_actions carry the current contract.

Other closed domains, including all 18 verification limits, settle detail codes, arrival conditions, sensitivity and link derivations, appear in the Required columns contract and their DDL CHECKs. job_kind is deliberately open with a lowercase/underscore format limit of 40 characters.

## Digest canonical forms

Digest16.of(_:) uses the first 16 bytes of SHA-256 over canonical UTF-8 text. DB2 creates Digest16 and SkeletonDigest. A 64-character SHA-256 of the same canonical text converts by decoding its first 32 hex characters; otherwise recompute. Every content digest uses BLOB with a length = 16 CHECK, never a parameterized SQL type.

| Column | Canonical input |
| --- | --- |
| brain_scenes.skeleton_digest | SceneSkeleton.canonical; SkeletonDigest(skeleton).bytes = Digest16.of(skeleton.canonical) |
| brain_element_keys.digest | key_text, the admitted DurableKey method text |
| memory_elements.digest | Concatenate role, kind, admitted label, label_origin, container_path, state, in that order: each nullable field is -: for NULL or N: followed by its exact UTF-8 bytes, where N is the decimal byte count. DB2, BR2 and BR3 share this encoding |
| memory_element_sets.digest | Distinct member element digest bytes, each lowercase hexadecimal, sorted lexicographically and joined with LF (no trailing LF); empty set is empty text. members stores sorted local element IDs as unsigned varints, independently of the digest order |
| memory_step_signatures.signature_digest | ProcedureMethod.signature exact canonical method form, not a scene-local or durable element key |
| memory_phase_families.method_digest | ProcedureMethod exactForm of method_text |
| memory_phase_families.masked_digest | ProcedureMethod maskedForm of method_text |
| memory_recall_texts.digest | The exact stored text column (UTF-8). Equal text in different roles shares one text_id; piece_kind lives on the association. A whole document uses its format’s deterministic text; absent pieces have no row |
| memory_task_values.value_digest, memory_parameter_bindings.value_digest, memory_operation_argument_links.value_digest | Exact resolved input/argument text at recording (ME1 §3.4), before withholding; the same UTF-8 text has the same digest in all three tables. NULL where the plan allows an absent value |
| memory_procedure_candidates.structure_digest | Candidate policy version, then LF + CanonicalText.field(event_uuid) for each ordered step, plus U+001F + step_kind for the mixed policy, as ProcedureCandidate.digest builds it. Recompute SHA-256 truncation instead of copying the old FNV digest |
| memory_procedure_interpretations.payload_digest | ProcedureInterpretation.canonical reconstructed from stored parts, parameters and uses, with destination candidate identity rendered consistently as decimal and global route references from route_uuid. Recompute rather than copy its old FNV digest |
| memory_recall_spaces.weights_digest, tokenizer_digest | Existing full 64-character SHA-256 strings of model and tokenizer bytes; immutable complete-space metadata, not Digest16 content keys |

## Trigger destinies

Exactly one row per source trigger. retained preserves its name, rewritten on integer identities and narrowed only by the explicit mutability contract. code means DB2 SchemaCoherence owns the former validation; R-X-13 supplies independent history guards where the new schema requires them.

| Source trigger | Destiny | Owner / reason |
| --- | --- | --- |
| `brain_scenes_kind_immutable` | retained | history (R-X-13) |
| `brain_scene_elements_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_scene_elements_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_scene_roles_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_scene_roles_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_scene_labels_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_scene_labels_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_scenes_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_scenes_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_evidence_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_evidence_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_transitions_to_not_app_scope_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_transitions_to_not_app_scope_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_events_identity_immutable` | retained | history (R-X-13) |
| `memory_agent_actions_app_from_event_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_actions_identity_immutable` | retained | history (R-X-13) |
| `memory_agent_action_effect_labels_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_action_status_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_action_listings_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_action_applications_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_action_windows_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_agent_action_observations_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_route_steps_identity_immutable` | retained | history (R-X-13) |
| `memory_step_operations_app_from_step_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_operations_app_from_step_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_checks_app_from_step_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_checks_app_from_step_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_arguments_app_from_owner_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_arguments_app_from_owner_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_events_verification_role_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_events_verification_role_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_verifications_matches_membership_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_verifications_matches_membership_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_action_correlations_roles_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_action_correlations_roles_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_route_steps_no_recursive_calls` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_step_operations_no_parent_cycle` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_scenes_require_capture_insert` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_scenes_require_capture_update` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_observations_capture_identity_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_observations_capture_status_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_event_observations_capture_delete_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_applications_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_applications_immutable` | retained | history (R-X-13) |
| `brain_applications_kept` | retained | history (R-X-13) |
| `memory_operation_arguments_application_sealed` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_arguments_application_immutable` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_arguments_application_kept` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_tasks_identity_immutable` | retained | history (R-X-13) |
| `memory_tasks_forward_only` | retained | task progression (R-A-42); contextual stored-revision check moves to DB2 |
| `memory_tasks_kept` | retained | history (R-X-13) |
| `memory_task_revisions_immutable` | retained | history (R-X-13) |
| `memory_task_revisions_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_task_constraints_immutable` | retained | history (R-X-13) |
| `memory_task_message_refs_immutable` | retained | history (R-X-13) |
| `memory_task_values_immutable` | retained | history (R-X-13) |
| `memory_task_attempts_immutable` | retained | history (R-X-13) |
| `memory_task_attempts_resume_same_task` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_task_checkpoints_immutable` | retained | history (R-X-13) |
| `memory_task_checkpoints_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_task_call_revisions_immutable` | retained | history (R-X-13) |
| `memory_call_effects_immutable` | retained | history (R-X-13) |
| `memory_call_effects_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_routes_immutable` | retained | history (R-X-13) |
| `memory_call_routes_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_adapter_dispatches_immutable` | retained | history (R-X-13) |
| `memory_call_adapter_dispatches_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_rungs_immutable` | retained | history (R-X-13) |
| `memory_call_rungs_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_route_advice_immutable` | retained | history (R-X-13) |
| `memory_call_route_advice_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_verifications_immutable` | retained | history (R-X-13) |
| `memory_operation_verifications_call_scope` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_verification_limits_immutable` | retained | history (R-X-13) |
| `memory_operation_verification_samples_immutable` | retained | history (R-X-13) |
| `memory_value_redactions_immutable` | retained | history (R-X-13) |
| `memory_value_redactions_kept` | retained | history (R-X-13) |
| `memory_call_recording_gaps_immutable` | retained | history (R-X-13) |
| `memory_call_recording_gaps_kept` | retained | history (R-X-13) |
| `memory_call_recording_gaps_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_origin_events_immutable` | retained | history (R-X-13) |
| `memory_origin_brain_contributions_immutable` | retained | history (R-X-13) |
| `memory_origin_brain_contributions_kept` | retained | history (R-X-13) |
| `memory_procedure_candidates_immutable` | retained | history (R-X-13) |
| `memory_procedure_candidates_kept` | retained | history (R-X-13) |
| `memory_candidate_steps_immutable` | retained | history (R-X-13) |
| `memory_candidate_steps_kept` | retained | history (R-X-13) |
| `memory_candidate_steps_operation` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_procedure_interpretations_immutable` | retained | history (R-X-13) |
| `memory_procedure_interpretations_kept` | retained | history (R-X-13) |
| `memory_procedure_interpretations_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_interpretation_findings_immutable` | retained | history (R-X-13) |
| `memory_interpretation_findings_kept` | retained | history (R-X-13) |
| `memory_procedure_versions_immutable` | retained | history (R-X-13) |
| `memory_procedure_versions_kept` | retained | history (R-X-13) |
| `memory_procedure_versions_insert_guard` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_procedure_parts_immutable` | retained | history (R-X-13) |
| `memory_procedure_parts_kept` | retained | history (R-X-13) |
| `memory_procedure_parts_containment` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_procedure_parts_step_position` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_part_contract_items_immutable` | retained | history (R-X-13) |
| `memory_parameter_details_immutable` | retained | history (R-X-13) |
| `memory_operation_argument_segments_immutable` | retained | history (R-X-13) |
| `memory_operation_argument_segments_alone` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_arguments_not_templated` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_parameter_bindings_immutable` | retained | history (R-X-13) |
| `memory_parameter_bindings_secret` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_procedure_step_occurrences_immutable` | retained | history (R-X-13) |
| `memory_part_qualifications_immutable` | retained | history (R-X-13) |
| `memory_part_qualifications_kept` | retained | history (R-X-13) |
| `memory_part_qualifications_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_part_qualification_reasons_immutable` | retained | history (R-X-13) |
| `memory_part_qualification_reasons_refused_only` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_part_qualification_evidence_immutable` | retained | history (R-X-13) |
| `memory_part_qualification_evidence_own_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_part_states_immutable` | retained | history (R-X-13) |
| `memory_part_states_kept` | retained | history (R-X-13) |
| `memory_part_states_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_qualification_policies_forward` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_qualification_policies_kept` | retained | history (R-X-13) |
| `brain_relations_identity_immutable` | retained | history (R-X-13) |
| `brain_relations_kept` | retained | history (R-X-13) |
| `brain_relations_not_app_scope` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_relation_proofs_immutable` | retained | history (R-X-13) |
| `brain_relation_proofs_kept` | retained | history (R-X-13) |
| `brain_relation_proofs_own_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_relation_applications_immutable` | retained | history (R-X-13) |
| `brain_relation_applications_kept` | retained | history (R-X-13) |
| `brain_scene_shapes_immutable` | retained | history (R-X-13) |
| `brain_scene_shapes_not_app_scope` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_relation_evaluations_immutable` | retained | history (R-X-13) |
| `brain_relation_evaluations_kept` | retained | history (R-X-13) |
| `brain_relation_evaluations_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_relation_evidence_immutable` | retained | history (R-X-13) |
| `brain_relation_evidence_kept` | retained | history (R-X-13) |
| `brain_relation_evidence_own_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `brain_anchor_label_keys_own_app` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_variant_prefixes_of_variants` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_variant_prefixes_immutable` | retained | history (R-X-13) |
| `memory_variant_prefixes_kept` | retained | history (R-X-13) |
| `memory_variant_prefix_checks_of_variants` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_variant_prefix_checks_immutable` | retained | history (R-X-13) |
| `memory_variant_prefix_checks_kept` | retained | history (R-X-13) |
| `memory_recall_work_on_version` | retained | derived Recall data |
| `memory_recall_work_on_qualification` | retained | derived Recall data |
| `memory_recall_work_on_state` | retained | derived Recall data |
| `memory_recall_work_on_policy_insert` | retained | derived Recall data |
| `memory_recall_work_on_policy_update` | retained | derived Recall data |
| `memory_recall_spaces_immutable` | retained | history (R-X-13) |
| `memory_recall_spaces_kept` | retained | history (R-X-13) |
| `memory_recall_generations_born_building` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_generations_transitions` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_generations_kept` | code | DB2 derived-index lifecycle check; the explicit rebuildable Mutable tables exception supersedes the old unconditional guard. Keep a named coverage case; do not reintroduce a fact-history block on derived rebuilds. |
| `memory_recall_documents_immutable` | code | DB2 derived-index lifecycle check; the explicit rebuildable Mutable tables exception supersedes the old unconditional guard. Keep a named coverage case; do not reintroduce a fact-history block on derived rebuilds. |
| `memory_recall_vectors_shape` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_vectors_immutable` | code | DB2 derived-index lifecycle check; the explicit rebuildable Mutable tables exception supersedes the old unconditional guard. Keep a named coverage case; do not reintroduce a fact-history block on derived rebuilds. |
| `memory_recall_entries_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_entries_counted` | retained | derived Recall data |
| `memory_recall_entries_removed` | retained | derived Recall data |
| `memory_recall_entries_immutable` | code | DB2 derived-index lifecycle check; the explicit rebuildable Mutable tables exception supersedes the old unconditional guard. Keep a named coverage case; do not reintroduce a fact-history block on derived rebuilds. |
| `memory_recall_work_progress` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_work_kept` | code | DB2 derived-index lifecycle check; the explicit rebuildable Mutable tables exception supersedes the old unconditional guard. Keep a named coverage case; do not reintroduce a fact-history block on derived rebuilds. |
| `memory_recall_queries_immutable` | retained | history (R-X-13) |
| `memory_recall_queries_kept` | retained | history (R-X-13) |
| `memory_recall_needs_immutable` | retained | history (R-X-13) |
| `memory_recall_needs_kept` | retained | history (R-X-13) |
| `memory_recall_selections_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_selections_immutable` | retained | history (R-X-13) |
| `memory_recall_selections_kept` | retained | history (R-X-13) |
| `memory_recall_requirements_immutable` | retained | history (R-X-13) |
| `memory_recall_requirements_kept` | retained | history (R-X-13) |
| `memory_recall_links_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_links_immutable` | retained | history (R-X-13) |
| `memory_recall_links_kept` | retained | history (R-X-13) |
| `memory_recall_reports_in_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_reports_immutable` | retained | history (R-X-13) |
| `memory_recall_reports_kept` | retained | history (R-X-13) |
| `memory_recall_proposals_immutable` | retained | history (R-X-13) |
| `memory_recall_proposals_kept` | retained | history (R-X-13) |
| `memory_recall_proposal_needs_immutable` | retained | history (R-X-13) |
| `memory_recall_proposal_needs_kept` | retained | history (R-X-13) |
| `memory_recall_proposal_sources_named` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_proposal_sources_immutable` | retained | history (R-X-13) |
| `memory_recall_proposal_sources_kept` | retained | history (R-X-13) |
| `memory_recall_choices_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_choices_immutable` | retained | history (R-X-13) |
| `memory_recall_choices_kept` | retained | history (R-X-13) |
| `memory_recall_choice_needs_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_choice_needs_immutable` | retained | history (R-X-13) |
| `memory_recall_choice_needs_kept` | retained | history (R-X-13) |
| `memory_recall_choice_links_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_choice_links_immutable` | retained | history (R-X-13) |
| `memory_recall_choice_links_kept` | retained | history (R-X-13) |
| `memory_recall_links_not_of_choices` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_recall_requirements_valid` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_argument_fields_immutable` | retained | history (R-X-13) |
| `memory_call_argument_fields_kept` | retained | history (R-X-13) |
| `memory_call_argument_fields_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_result_fields_immutable` | retained | history (R-X-13) |
| `memory_call_result_fields_kept` | retained | history (R-X-13) |
| `memory_call_result_fields_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_data_contexts_immutable` | retained | history (R-X-13) |
| `memory_call_data_contexts_kept` | retained | history (R-X-13) |
| `memory_call_data_contexts_concluded_call` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_argument_fields_immutable` | retained | history (R-X-13) |
| `memory_operation_argument_fields_kept` | retained | history (R-X-13) |
| `memory_identity_salts_immutable` | retained | history (R-X-13) |
| `memory_identity_salts_kept` | retained | history (R-X-13) |
| `memory_executors_immutable` | retained | history (R-X-13) |
| `memory_executors_kept` | retained | history (R-X-13) |
| `memory_call_executors_immutable` | retained | history (R-X-13) |
| `memory_call_executors_kept` | retained | history (R-X-13) |
| `memory_call_reconciliations_immutable` | retained | history (R-X-13) |
| `memory_call_reconciliations_kept` | retained | history (R-X-13) |
| `memory_call_argument_fields_reference` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_operation_argument_fields_one_form` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |
| `memory_call_reconciliations_order` | code | SchemaCoherence (DB2), one pure function and coverage case named for this trigger |

## New triggers

New guards close every unlisted history column and every fact DELETE, freeze all eleven historical destinations, and enforce set-once outcome fields and one-way publication/use/takeover. The test exercises each history and freeze policy on an existing row.

| Trigger | Purpose |
| --- | --- |
| `brain_apps_history_immutable` | history / declared transition |
| `brain_apps_history_kept` | history / declared transition |
| `brain_app_window_epochs_history_immutable` | history / declared transition |
| `brain_app_contexts_history_immutable` | history / declared transition |
| `brain_app_contexts_history_kept` | history / declared transition |
| `brain_scenes_history_kept` | history / declared transition |
| `brain_scene_roles_history_immutable` | history / declared transition |
| `brain_scene_roles_history_kept` | history / declared transition |
| `brain_scene_labels_history_immutable` | history / declared transition |
| `brain_scene_labels_history_kept` | history / declared transition |
| `brain_anchors_history_immutable` | history / declared transition |
| `brain_anchors_history_kept` | history / declared transition |
| `brain_anchors_frozen` | freeze |
| `brain_anchor_aliases_history_immutable` | history / declared transition |
| `brain_anchor_aliases_history_kept` | history / declared transition |
| `brain_anchor_aliases_frozen` | freeze |
| `brain_anchor_states_history_immutable` | history / declared transition |
| `brain_anchor_states_history_kept` | history / declared transition |
| `brain_anchor_states_frozen` | freeze |
| `brain_scene_elements_history_immutable` | history / declared transition |
| `brain_scene_elements_history_kept` | history / declared transition |
| `brain_groups_history_immutable` | history / declared transition |
| `brain_groups_history_kept` | history / declared transition |
| `brain_groups_frozen` | freeze |
| `brain_group_members_history_immutable` | history / declared transition |
| `brain_group_members_history_kept` | history / declared transition |
| `brain_group_members_frozen` | freeze |
| `brain_menu_commands_history_immutable` | history / declared transition |
| `brain_menu_commands_history_kept` | history / declared transition |
| `brain_menu_path_segments_history_immutable` | history / declared transition |
| `brain_menu_path_segments_history_kept` | history / declared transition |
| `brain_transitions_history_immutable` | history / declared transition |
| `brain_transitions_history_kept` | history / declared transition |
| `brain_transitions_frozen` | freeze |
| `brain_transition_menu_items_history_immutable` | history / declared transition |
| `brain_transition_menu_items_history_kept` | history / declared transition |
| `brain_transition_menu_items_frozen` | freeze |
| `memory_events_history_kept` | history / declared transition |
| `memory_input_events_history_immutable` | history / declared transition |
| `memory_input_events_history_kept` | history / declared transition |
| `memory_agent_actions_history_kept` | history / declared transition |
| `memory_agent_actions_gesture_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_effect_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_effect_reason_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_recovery_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_recovery_reason_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_outcome_origin_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_actions_learnable_once` | ES1 outcome field: set once, never rewritten |
| `memory_agent_action_effect_labels_history_immutable` | history / declared transition |
| `memory_agent_action_effect_labels_history_kept` | history / declared transition |
| `memory_agent_action_status_history_immutable` | history / declared transition |
| `memory_agent_action_status_history_kept` | history / declared transition |
| `memory_agent_action_listings_history_immutable` | history / declared transition |
| `memory_agent_action_listings_history_kept` | history / declared transition |
| `memory_agent_action_applications_history_immutable` | history / declared transition |
| `memory_agent_action_applications_history_kept` | history / declared transition |
| `memory_agent_action_windows_history_immutable` | history / declared transition |
| `memory_agent_action_windows_history_kept` | history / declared transition |
| `memory_agent_action_observations_history_immutable` | history / declared transition |
| `memory_agent_action_observations_history_kept` | history / declared transition |
| `memory_event_observations_history_immutable` | history / declared transition |
| `memory_event_observations_history_kept` | history / declared transition |
| `memory_event_scenes_history_immutable` | history / declared transition |
| `memory_event_scenes_history_kept` | history / declared transition |
| `memory_verifications_history_immutable` | history / declared transition |
| `memory_verifications_history_kept` | history / declared transition |
| `memory_action_correlations_history_immutable` | history / declared transition |
| `memory_action_correlations_history_kept` | history / declared transition |
| `brain_applications_frozen` | freeze |
| `brain_evidence_history_immutable` | history / declared transition |
| `brain_evidence_history_kept` | history / declared transition |
| `memory_task_occurrences_history_immutable` | history / declared transition |
| `memory_task_occurrences_history_kept` | history / declared transition |
| `memory_task_events_history_immutable` | history / declared transition |
| `memory_task_events_history_kept` | history / declared transition |
| `memory_task_labels_history_immutable` | history / declared transition |
| `memory_task_labels_history_kept` | history / declared transition |
| `memory_routes_history_immutable` | history / declared transition |
| `memory_routes_history_kept` | history / declared transition |
| `memory_route_parameters_history_immutable` | history / declared transition |
| `memory_route_parameters_history_kept` | history / declared transition |
| `memory_route_steps_history_kept` | history / declared transition |
| `memory_step_checks_history_immutable` | history / declared transition |
| `memory_step_checks_history_kept` | history / declared transition |
| `memory_step_operations_history_immutable` | history / declared transition |
| `memory_step_operations_history_kept` | history / declared transition |
| `memory_operation_arguments_history_immutable` | history / declared transition |
| `memory_operation_arguments_history_kept` | history / declared transition |
| `memory_route_call_bindings_history_immutable` | history / declared transition |
| `memory_route_call_bindings_history_kept` | history / declared transition |
| `memory_step_occurrences_history_immutable` | history / declared transition |
| `memory_step_occurrences_history_kept` | history / declared transition |
| `memory_step_events_history_immutable` | history / declared transition |
| `memory_step_events_history_kept` | history / declared transition |
| `memory_route_evidence_history_immutable` | history / declared transition |
| `memory_route_evidence_history_kept` | history / declared transition |
| `memory_step_evidence_history_immutable` | history / declared transition |
| `memory_step_evidence_history_kept` | history / declared transition |
| `memory_experiences_history_immutable` | history / declared transition |
| `memory_experiences_history_kept` | history / declared transition |
| `memory_experience_bindings_history_immutable` | history / declared transition |
| `memory_experience_bindings_history_kept` | history / declared transition |
| `memory_experience_uses_history_immutable` | history / declared transition |
| `memory_experience_uses_history_kept` | history / declared transition |
| `memory_schema_migrations_history_immutable` | history / declared transition |
| `memory_schema_migrations_history_kept` | history / declared transition |
| `memory_task_revisions_history_kept` | history / declared transition |
| `memory_task_constraints_history_kept` | history / declared transition |
| `memory_task_message_refs_history_kept` | history / declared transition |
| `memory_task_attempts_history_kept` | history / declared transition |
| `memory_task_checkpoints_history_kept` | history / declared transition |
| `memory_task_values_history_kept` | history / declared transition |
| `memory_task_call_revisions_history_kept` | history / declared transition |
| `memory_call_effects_history_kept` | history / declared transition |
| `memory_call_routes_history_kept` | history / declared transition |
| `memory_call_adapter_dispatches_history_kept` | history / declared transition |
| `memory_call_rungs_history_kept` | history / declared transition |
| `memory_call_route_advice_history_kept` | history / declared transition |
| `memory_operation_verifications_history_kept` | history / declared transition |
| `memory_operation_verification_limits_history_kept` | history / declared transition |
| `memory_operation_verification_samples_history_kept` | history / declared transition |
| `memory_archive_origins_history_immutable` | history / declared transition |
| `memory_archive_origins_history_kept` | history / declared transition |
| `memory_origin_events_history_kept` | history / declared transition |
| `memory_part_contract_items_history_kept` | history / declared transition |
| `memory_parameter_details_history_kept` | history / declared transition |
| `memory_operation_argument_segments_history_kept` | history / declared transition |
| `memory_parameter_bindings_history_kept` | history / declared transition |
| `memory_procedure_step_occurrences_history_kept` | history / declared transition |
| `memory_qualification_policies_history_immutable` | history / declared transition |
| `memory_part_qualification_reasons_history_kept` | history / declared transition |
| `memory_part_qualification_evidence_history_kept` | history / declared transition |
| `brain_relation_applications_frozen` | freeze |
| `brain_scene_shapes_history_kept` | history / declared transition |
| `brain_anchor_label_keys_history_immutable` | history / declared transition |
| `brain_anchor_label_keys_history_kept` | history / declared transition |
| `brain_anchor_label_keys_frozen` | freeze |
| `memory_variant_prefixes_frozen` | freeze |
| `memory_todo_revisions_history_immutable` | history / declared transition |
| `memory_todo_revisions_history_kept` | history / declared transition |
| `memory_todo_items_history_immutable` | history / declared transition |
| `memory_todo_items_history_kept` | history / declared transition |
| `memory_todo_item_states_history_immutable` | history / declared transition |
| `memory_todo_item_states_history_kept` | history / declared transition |
| `memory_todo_item_expectations_history_immutable` | history / declared transition |
| `memory_todo_item_expectations_history_kept` | history / declared transition |
| `memory_call_steps_history_immutable` | history / declared transition |
| `memory_call_steps_history_kept` | history / declared transition |
| `memory_task_end_checks_history_immutable` | history / declared transition |
| `memory_task_end_checks_history_kept` | history / declared transition |
| `memory_gesture_evidence_history_immutable` | history / declared transition |
| `memory_gesture_evidence_history_kept` | history / declared transition |
| `memory_gesture_changes_history_immutable` | history / declared transition |
| `memory_gesture_changes_history_kept` | history / declared transition |
| `memory_batch_stops_history_immutable` | history / declared transition |
| `memory_batch_stops_history_kept` | history / declared transition |
| `memory_operation_argument_links_history_immutable` | history / declared transition |
| `memory_operation_argument_links_history_kept` | history / declared transition |
| `memory_step_signatures_history_immutable` | history / declared transition |
| `memory_step_signatures_history_kept` | history / declared transition |
| `memory_step_signature_members_history_immutable` | history / declared transition |
| `memory_step_signature_members_history_kept` | history / declared transition |
| `memory_recall_calibration_history_immutable` | history / declared transition |
| `memory_recall_calibration_history_kept` | history / declared transition |
| `memory_part_misses_history_immutable` | history / declared transition |
| `memory_part_misses_history_kept` | history / declared transition |
| `memory_attempt_reused_parts_history_immutable` | history / declared transition |
| `memory_attempt_reused_parts_history_kept` | history / declared transition |
| `memory_elements_history_immutable` | history / declared transition |
| `memory_elements_history_kept` | history / declared transition |
| `memory_element_sets_history_immutable` | history / declared transition |
| `memory_element_sets_history_kept` | history / declared transition |
| `brain_element_keys_history_immutable` | history / declared transition |
| `brain_element_keys_history_kept` | history / declared transition |
| `brain_screen_kinds_history_immutable` | history / declared transition |
| `brain_screen_kinds_history_kept` | history / declared transition |
| `brain_scene_kind_members_history_immutable` | history / declared transition |
| `brain_scene_kind_members_history_kept` | history / declared transition |
| `brain_scene_merges_history_immutable` | history / declared transition |
| `brain_scene_merges_history_kept` | history / declared transition |
| `memory_consolidation_queue_history_immutable` | history / declared transition |
| `memory_consolidation_cursors_history_immutable` | history / declared transition |
| `memory_consolidation_cursors_history_kept` | history / declared transition |
| `memory_part_judgments_history_immutable` | history / declared transition |
| `memory_part_judgments_history_kept` | history / declared transition |
| `memory_forget_tombstones_history_immutable` | history / declared transition |
| `memory_forget_tombstones_history_kept` | history / declared transition |
| `memory_part_origins_history_immutable` | history / declared transition |
| `memory_part_origins_history_kept` | history / declared transition |
| `memory_procedure_provenance_history_immutable` | history / declared transition |
| `memory_procedure_provenance_history_kept` | history / declared transition |
| `memory_procedure_exit_points_history_immutable` | history / declared transition |
| `memory_procedure_exit_points_history_kept` | history / declared transition |
| `memory_person_segments_history_immutable` | history / declared transition |
| `memory_person_segments_history_kept` | history / declared transition |
| `memory_segment_checks_history_immutable` | history / declared transition |
| `memory_segment_checks_history_kept` | history / declared transition |
| `memory_person_commands_history_immutable` | history / declared transition |
| `memory_person_commands_history_kept` | history / declared transition |
| `memory_call_capabilities_history_immutable` | history / declared transition |
| `memory_call_capabilities_history_kept` | history / declared transition |
| `memory_step_capabilities_history_immutable` | history / declared transition |
| `memory_step_capabilities_history_kept` | history / declared transition |
| `memory_part_qualifications_publish_once` | history / declared transition |
| `memory_recall_calibration_used_once` | history / declared transition |
| `memory_task_attempts_takeover_forward` | history / declared transition |
| `memory_operation_arguments_non_event_immutable` | Restrict text_value updates to event-owned arguments |

| `memory_brain_command_inputs_history_immutable` | Refuse every command-input UPDATE, including no-op updates |
| `memory_brain_command_inputs_history_no_delete` | Preserve durable command inputs independently of queue cleanup |
| `memory_brain_command_detections_history_immutable` | Refuse every command-input UPDATE, including no-op updates |
| `memory_brain_command_detections_history_no_delete` | Preserve durable command inputs independently of queue cleanup |

## Required columns

The resource tests read every (table, column) pair below and require the complete table set. This is the destination shape, including preserved columns.

| Table | Column |
| --- | --- |
| `brain_apps` | `app_id` |
| `brain_apps` | `bundle_id` |
| `brain_apps` | `ingest_epoch` |
| `brain_apps` | `last_epoch_advance_ms` |
| `brain_app_window_epochs` | `app_id` |
| `brain_app_window_epochs` | `window_family` |
| `brain_app_window_epochs` | `epoch` |
| `brain_app_contexts` | `context_id` |
| `brain_app_contexts` | `app_id` |
| `brain_app_contexts` | `app_version` |
| `brain_app_contexts` | `app_locale` |
| `brain_scenes` | `scene_id` |
| `brain_scenes` | `scene_uuid` |
| `brain_scenes` | `app_id` |
| `brain_scenes` | `window_title_pattern` |
| `brain_scenes` | `title_bucket` |
| `brain_scenes` | `scene_kind` |
| `brain_scenes` | `structural_key` |
| `brain_scenes` | `first_seen_ms` |
| `brain_scenes` | `last_seen_ms` |
| `brain_scenes` | `observation_count` |
| `brain_scenes` | `set_id` |
| `brain_scenes` | `skeleton_digest` |
| `brain_scene_roles` | `scene_id` |
| `brain_scene_roles` | `role` |
| `brain_scene_roles` | `count_bucket` |
| `brain_scene_labels` | `scene_id` |
| `brain_scene_labels` | `label_token` |
| `brain_anchors` | `anchor_id` |
| `brain_anchors` | `app_id` |
| `brain_anchors` | `insertion_order` |
| `brain_anchors` | `kind` |
| `brain_anchors` | `label` |
| `brain_anchors` | `label_source` |
| `brain_anchors` | `anchor_scope` |
| `brain_anchors` | `typical_x` |
| `brain_anchors` | `typical_y` |
| `brain_anchors` | `typical_width` |
| `brain_anchors` | `typical_height` |
| `brain_anchors` | `window_family` |
| `brain_anchors` | `first_seen_ms` |
| `brain_anchors` | `last_seen_ms` |
| `brain_anchors` | `seen_count` |
| `brain_anchors` | `last_seen_epoch` |
| `brain_anchors` | `current_group_id` |
| `brain_anchors` | `retired_at_ms` |
| `brain_anchors` | `retired_epoch` |
| `brain_anchors` | `retirement_cause` |
| `brain_anchor_aliases` | `anchor_id` |
| `brain_anchor_aliases` | `alias` |
| `brain_anchor_aliases` | `position` |
| `brain_anchor_states` | `anchor_id` |
| `brain_anchor_states` | `state` |
| `brain_anchor_states` | `seen_count` |
| `brain_scene_elements` | `scene_element_id` |
| `brain_scene_elements` | `app_id` |
| `brain_scene_elements` | `scene_id` |
| `brain_scene_elements` | `element_key` |
| `brain_scene_elements` | `element_scope` |
| `brain_scene_elements` | `parent_element_id` |
| `brain_scene_elements` | `edge_hash` |
| `brain_scene_elements` | `cursor_affordance` |
| `brain_scene_elements` | `anchor_id` |
| `brain_scene_elements` | `label` |
| `brain_scene_elements` | `label_origin` |
| `brain_scene_elements` | `role` |
| `brain_scene_elements` | `kind` |
| `brain_scene_elements` | `source` |
| `brain_scene_elements` | `bounds_x` |
| `brain_scene_elements` | `bounds_y` |
| `brain_scene_elements` | `bounds_width` |
| `brain_scene_elements` | `bounds_height` |
| `brain_scene_elements` | `first_seen_ms` |
| `brain_scene_elements` | `last_seen_ms` |
| `brain_scene_elements` | `observation_count` |
| `brain_scene_elements` | `replaced_by_id` |
| `brain_groups` | `group_id` |
| `brain_groups` | `app_id` |
| `brain_groups` | `insertion_order` |
| `brain_groups` | `axis` |
| `brain_groups` | `shared_kind` |
| `brain_groups` | `cell_width` |
| `brain_groups` | `cell_height` |
| `brain_groups` | `name` |
| `brain_groups` | `last_seen_ms` |
| `brain_groups` | `seen_count` |
| `brain_groups` | `last_seen_epoch` |
| `brain_groups` | `retired_at_ms` |
| `brain_groups` | `retired_epoch` |
| `brain_groups` | `retirement_cause` |
| `brain_group_members` | `app_id` |
| `brain_group_members` | `group_id` |
| `brain_group_members` | `anchor_id` |
| `brain_group_members` | `position` |
| `brain_menu_commands` | `menu_command_id` |
| `brain_menu_commands` | `app_id` |
| `brain_menu_commands` | `path_key` |
| `brain_menu_commands` | `top_level_title` |
| `brain_menu_commands` | `accessibility_identifier` |
| `brain_menu_commands` | `has_submenu` |
| `brain_menu_commands` | `last_observed_enabled` |
| `brain_menu_commands` | `mark_char` |
| `brain_menu_commands` | `cmd_char` |
| `brain_menu_commands` | `first_seen_ms` |
| `brain_menu_commands` | `last_seen_ms` |
| `brain_menu_path_segments` | `menu_command_id` |
| `brain_menu_path_segments` | `position` |
| `brain_menu_path_segments` | `title` |
| `brain_transitions` | `transition_id` |
| `brain_transitions` | `app_id` |
| `brain_transitions` | `insertion_order` |
| `brain_transitions` | `from_scene_id` |
| `brain_transitions` | `anchor_id` |
| `brain_transitions` | `scene_element_id` |
| `brain_transitions` | `menu_command_id` |
| `brain_transitions` | `trigger_kind` |
| `brain_transitions` | `to_scene_id` |
| `brain_transitions` | `effect_kind` |
| `brain_transitions` | `effect_text` |
| `brain_transitions` | `required_target_state` |
| `brain_transitions` | `resulting_target_state` |
| `brain_transitions` | `effect_label` |
| `brain_transitions` | `effect_value` |
| `brain_transitions` | `last_observed_epoch` |
| `brain_transitions` | `status` |
| `brain_transitions` | `first_seen_ms` |
| `brain_transitions` | `last_seen_ms` |
| `brain_transitions` | `evidence_count` |
| `brain_transitions` | `retired_at_ms` |
| `brain_transitions` | `retired_epoch` |
| `brain_transitions` | `retirement_cause` |
| `brain_transition_menu_items` | `transition_id` |
| `brain_transition_menu_items` | `position` |
| `brain_transition_menu_items` | `title` |
| `memory_events` | `event_id` |
| `memory_events` | `event_uuid` |
| `memory_events` | `source` |
| `memory_events` | `source_stream_id` |
| `memory_events` | `source_key` |
| `memory_events` | `trace_id` |
| `memory_events` | `session_id` |
| `memory_events` | `parent_event_id` |
| `memory_events` | `parent_position` |
| `memory_events` | `event_kind` |
| `memory_events` | `app_id` |
| `memory_events` | `context_id` |
| `memory_events` | `occurred_at_ms` |
| `memory_events` | `monotonic_ns` |
| `memory_events` | `capture_status` |
| `memory_events` | `origin_event_id` |
| `memory_input_events` | `event_id` |
| `memory_input_events` | `event_kind` |
| `memory_input_events` | `input_kind` |
| `memory_input_events` | `sequence_number` |
| `memory_input_events` | `target_pid` |
| `memory_input_events` | `source_pid` |
| `memory_input_events` | `window_number` |
| `memory_input_events` | `window_title` |
| `memory_input_events` | `window_x` |
| `memory_input_events` | `window_y` |
| `memory_input_events` | `window_width` |
| `memory_input_events` | `window_height` |
| `memory_input_events` | `point_x` |
| `memory_input_events` | `point_y` |
| `memory_input_events` | `delta_x` |
| `memory_input_events` | `delta_y` |
| `memory_input_events` | `started_at_ns` |
| `memory_input_events` | `ended_at_ns` |
| `memory_input_events` | `preceding_revision` |
| `memory_input_events` | `revision` |
| `memory_input_events` | `gap_first_sequence` |
| `memory_input_events` | `gap_last_sequence` |
| `memory_input_events` | `lost_critical` |
| `memory_input_events` | `lost_coalescible` |
| `memory_input_events` | `before_status` |
| `memory_input_events` | `after_status` |
| `memory_input_events` | `difference_status` |
| `memory_agent_actions` | `event_id` |
| `memory_agent_actions` | `event_kind` |
| `memory_agent_actions` | `app_id` |
| `memory_agent_actions` | `tool_kind` |
| `memory_agent_actions` | `contract_version` |
| `memory_agent_actions` | `execution_status` |
| `memory_agent_actions` | `started_at_ms` |
| `memory_agent_actions` | `completed_at_ms` |
| `memory_agent_actions` | `duration_ms` |
| `memory_agent_actions` | `result_kind` |
| `memory_agent_actions` | `result_message` |
| `memory_agent_actions` | `observed_effect_kind` |
| `memory_agent_actions` | `observed_effect_text` |
| `memory_agent_actions` | `observed_state_before` |
| `memory_agent_actions` | `observed_state_after` |
| `memory_agent_actions` | `observed_effect_label` |
| `memory_agent_actions` | `observed_effect_value` |
| `memory_agent_actions` | `requested_count` |
| `memory_agent_actions` | `attempted_count` |
| `memory_agent_actions` | `verified_count` |
| `memory_agent_actions` | `gesture` |
| `memory_agent_actions` | `effect` |
| `memory_agent_actions` | `effect_reason` |
| `memory_agent_actions` | `recovery` |
| `memory_agent_actions` | `recovery_reason` |
| `memory_agent_actions` | `outcome_origin` |
| `memory_agent_actions` | `learnable` |
| `memory_agent_action_effect_labels` | `event_id` |
| `memory_agent_action_effect_labels` | `position` |
| `memory_agent_action_effect_labels` | `label` |
| `memory_agent_action_status` | `event_id` |
| `memory_agent_action_status` | `session_id` |
| `memory_agent_action_status` | `screen_recording` |
| `memory_agent_action_status` | `accessibility` |
| `memory_agent_action_status` | `post_event` |
| `memory_agent_action_listings` | `event_id` |
| `memory_agent_action_listings` | `listing_kind` |
| `memory_agent_action_listings` | `hidden_count` |
| `memory_agent_action_applications` | `listing_application_id` |
| `memory_agent_action_applications` | `event_id` |
| `memory_agent_action_applications` | `position` |
| `memory_agent_action_applications` | `name` |
| `memory_agent_action_applications` | `bundle_id` |
| `memory_agent_action_applications` | `pid` |
| `memory_agent_action_applications` | `app_version` |
| `memory_agent_action_applications` | `is_running` |
| `memory_agent_action_applications` | `location` |
| `memory_agent_action_applications` | `is_default_browser` |
| `memory_agent_action_windows` | `event_id` |
| `memory_agent_action_windows` | `application_position` |
| `memory_agent_action_windows` | `position` |
| `memory_agent_action_windows` | `window_number` |
| `memory_agent_action_windows` | `title` |
| `memory_agent_action_windows` | `listing_application_id` |
| `memory_agent_action_observations` | `event_id` |
| `memory_agent_action_observations` | `session_id` |
| `memory_agent_action_observations` | `session_revision` |
| `memory_agent_action_observations` | `observed_at_ms` |
| `memory_agent_action_observations` | `sample_event_id` |
| `memory_agent_action_observations` | `sample_phase` |
| `memory_agent_action_observations` | `sample_ordinal` |
| `memory_agent_action_observations` | `sample_observation_id` |
| `memory_agent_action_observations` | `sample_kind` |
| `memory_event_observations` | `observation_id` |
| `memory_event_observations` | `event_id` |
| `memory_event_observations` | `phase` |
| `memory_event_observations` | `sample_ordinal` |
| `memory_event_observations` | `observation_kind` |
| `memory_event_observations` | `observation_contract_version` |
| `memory_event_observations` | `field_name` |
| `memory_event_observations` | `text_value` |
| `memory_event_observations` | `integer_value` |
| `memory_event_observations` | `real_value` |
| `memory_event_observations` | `boolean_value` |
| `memory_event_observations` | `observation_group` |
| `memory_event_observations` | `parent_observation_id` |
| `memory_event_observations` | `window_title` |
| `memory_event_observations` | `session_revision` |
| `memory_event_observations` | `surface_kind` |
| `memory_event_observations` | `status` |
| `memory_event_observations` | `candidate_rank` |
| `memory_event_observations` | `label` |
| `memory_event_observations` | `label_origin` |
| `memory_event_observations` | `container_path` |
| `memory_event_observations` | `role` |
| `memory_event_observations` | `element_kind` |
| `memory_event_observations` | `old_state` |
| `memory_event_observations` | `new_state` |
| `memory_event_observations` | `bounds_x` |
| `memory_event_observations` | `bounds_y` |
| `memory_event_observations` | `bounds_width` |
| `memory_event_observations` | `bounds_height` |
| `memory_event_observations` | `scene_age_ms` |
| `memory_event_observations` | `name_resolution` |
| `memory_event_observations` | `label_source` |
| `memory_event_observations` | `set_id` |
| `memory_event_observations` | `window_number` |
| `memory_event_observations` | `window_subrole` |
| `memory_event_observations` | `reject_reason` |
| `memory_event_scenes` | `event_id` |
| `memory_event_scenes` | `app_id` |
| `memory_event_scenes` | `phase` |
| `memory_event_scenes` | `sample_ordinal` |
| `memory_event_scenes` | `scene_id` |
| `memory_event_scenes` | `match_status` |
| `memory_event_scenes` | `matched_by` |
| `memory_event_scenes` | `matcher_version` |
| `memory_event_scenes` | `confidence` |
| `memory_verifications` | `event_id` |
| `memory_verifications` | `event_kind` |
| `memory_verifications` | `step_occurrence_id` |
| `memory_verifications` | `scope` |
| `memory_verifications` | `method` |
| `memory_verifications` | `verdict` |
| `memory_verifications` | `expected_text` |
| `memory_verifications` | `observed_text` |
| `memory_action_correlations` | `watcher_event_id` |
| `memory_action_correlations` | `agent_event_id` |
| `memory_action_correlations` | `basis_kind` |
| `memory_action_correlations` | `time_offset_ms` |
| `memory_action_correlations` | `explanation` |
| `brain_applications` | `application_id` |
| `brain_applications` | `app_id` |
| `brain_applications` | `event_id` |
| `brain_applications` | `operation` |
| `brain_applications` | `phase` |
| `brain_applications` | `sample_ordinal` |
| `brain_applications` | `sample_observation_id` |
| `brain_applications` | `sample_kind` |
| `brain_applications` | `contract_version` |
| `brain_applications` | `algorithm_version` |
| `brain_applications` | `requested_at_ms` |
| `brain_applications` | `effective_at_ms` |
| `brain_applications` | `outcome` |
| `brain_applications` | `created_count` |
| `brain_applications` | `updated_count` |
| `brain_applications` | `skipped_ambiguous_count` |
| `brain_applications` | `anchor_id` |
| `brain_applications` | `transition_id` |
| `brain_applications` | `evidence_count` |
| `brain_evidence` | `evidence_id` |
| `brain_evidence` | `app_id` |
| `brain_evidence` | `event_id` |
| `brain_evidence` | `relation` |
| `brain_evidence` | `assessed_by` |
| `brain_evidence` | `assessment_version` |
| `brain_evidence` | `assessed_at_ms` |
| `brain_evidence` | `scene_id` |
| `brain_evidence` | `anchor_id` |
| `brain_evidence` | `scene_element_id` |
| `brain_evidence` | `group_id` |
| `brain_evidence` | `menu_command_id` |
| `brain_evidence` | `transition_id` |
| `memory_task_occurrences` | `task_occurrence_id` |
| `memory_task_occurrences` | `task_occurrence_uuid` |
| `memory_task_occurrences` | `trace_id` |
| `memory_task_occurrences` | `started_at_ms` |
| `memory_task_occurrences` | `ended_at_ms` |
| `memory_task_occurrences` | `status` |
| `memory_task_events` | `task_occurrence_id` |
| `memory_task_events` | `event_id` |
| `memory_task_events` | `position` |
| `memory_task_events` | `role` |
| `memory_task_labels` | `label_id` |
| `memory_task_labels` | `task_occurrence_id` |
| `memory_task_labels` | `label` |
| `memory_task_labels` | `assigned_by` |
| `memory_task_labels` | `confidence` |
| `memory_task_labels` | `status` |
| `memory_task_labels` | `assigned_at_ms` |
| `memory_routes` | `route_id` |
| `memory_routes` | `route_uuid` |
| `memory_routes` | `name` |
| `memory_routes` | `status` |
| `memory_routes` | `supersedes_route_id` |
| `memory_routes` | `created_at_ms` |
| `memory_routes` | `last_used_ms` |
| `memory_routes` | `demoted_at_ms` |
| `memory_routes` | `demotion_cause` |
| `memory_route_parameters` | `parameter_id` |
| `memory_route_parameters` | `route_id` |
| `memory_route_parameters` | `name` |
| `memory_route_parameters` | `direction` |
| `memory_route_parameters` | `value_type` |
| `memory_route_parameters` | `is_required` |
| `memory_route_steps` | `step_id` |
| `memory_route_steps` | `route_id` |
| `memory_route_steps` | `position` |
| `memory_route_steps` | `step_kind` |
| `memory_route_steps` | `goal_text` |
| `memory_route_steps` | `app_id` |
| `memory_route_steps` | `called_route_id` |
| `memory_route_steps` | `actor` |
| `memory_route_steps` | `segment_id` |
| `memory_route_steps` | `person_evidence` |
| `memory_step_checks` | `check_id` |
| `memory_step_checks` | `route_id` |
| `memory_step_checks` | `step_id` |
| `memory_step_checks` | `app_id` |
| `memory_step_checks` | `position` |
| `memory_step_checks` | `check_kind` |
| `memory_step_checks` | `expected_scene_id` |
| `memory_step_checks` | `expected_anchor_id` |
| `memory_step_checks` | `expected_state` |
| `memory_step_checks` | `expected_text` |
| `memory_step_checks` | `expected_integer` |
| `memory_step_checks` | `expected_real` |
| `memory_step_checks` | `expected_bool` |
| `memory_step_checks` | `expected_parameter_id` |
| `memory_step_checks` | `comparison` |
| `memory_step_operations` | `operation_id` |
| `memory_step_operations` | `route_id` |
| `memory_step_operations` | `step_id` |
| `memory_step_operations` | `parent_operation_id` |
| `memory_step_operations` | `position` |
| `memory_step_operations` | `tool_kind` |
| `memory_step_operations` | `contract_version` |
| `memory_step_operations` | `app_id` |
| `memory_operation_arguments` | `argument_id` |
| `memory_operation_arguments` | `operation_id` |
| `memory_operation_arguments` | `event_id` |
| `memory_operation_arguments` | `brain_application_id` |
| `memory_operation_arguments` | `route_id` |
| `memory_operation_arguments` | `app_id` |
| `memory_operation_arguments` | `argument_name` |
| `memory_operation_arguments` | `position` |
| `memory_operation_arguments` | `value_kind` |
| `memory_operation_arguments` | `text_value` |
| `memory_operation_arguments` | `integer_value` |
| `memory_operation_arguments` | `real_value` |
| `memory_operation_arguments` | `boolean_value` |
| `memory_operation_arguments` | `parameter_id` |
| `memory_operation_arguments` | `anchor_id` |
| `memory_operation_arguments` | `menu_command_id` |
| `memory_route_call_bindings` | `step_id` |
| `memory_route_call_bindings` | `route_id` |
| `memory_route_call_bindings` | `called_route_id` |
| `memory_route_call_bindings` | `called_parameter_id` |
| `memory_route_call_bindings` | `source_parameter_id` |
| `memory_route_call_bindings` | `literal_text` |
| `memory_route_call_bindings` | `literal_integer` |
| `memory_route_call_bindings` | `literal_real` |
| `memory_route_call_bindings` | `literal_bool` |
| `memory_step_occurrences` | `step_occurrence_id` |
| `memory_step_occurrences` | `task_occurrence_id` |
| `memory_step_occurrences` | `step_id` |
| `memory_step_occurrences` | `started_at_ms` |
| `memory_step_occurrences` | `ended_at_ms` |
| `memory_step_occurrences` | `status` |
| `memory_step_occurrences` | `assigned_by` |
| `memory_step_events` | `step_occurrence_id` |
| `memory_step_events` | `event_id` |
| `memory_step_events` | `position` |
| `memory_step_events` | `attempt_number` |
| `memory_step_events` | `role` |
| `memory_route_evidence` | `route_id` |
| `memory_route_evidence` | `task_occurrence_id` |
| `memory_route_evidence` | `relation` |
| `memory_route_evidence` | `assessed_by` |
| `memory_route_evidence` | `assessed_at_ms` |
| `memory_step_evidence` | `step_id` |
| `memory_step_evidence` | `step_occurrence_id` |
| `memory_step_evidence` | `relation` |
| `memory_step_evidence` | `assessed_by` |
| `memory_step_evidence` | `assessed_at_ms` |
| `memory_experiences` | `experience_id` |
| `memory_experiences` | `phrase` |
| `memory_experiences` | `route_id` |
| `memory_experiences` | `step_id` |
| `memory_experiences` | `created_at_ms` |
| `memory_experience_bindings` | `experience_id` |
| `memory_experience_bindings` | `route_id` |
| `memory_experience_bindings` | `parameter_id` |
| `memory_experience_bindings` | `value_type` |
| `memory_experience_bindings` | `binding_kind` |
| `memory_experience_bindings` | `binding_contract_version` |
| `memory_experience_bindings` | `slot_name` |
| `memory_experience_bindings` | `literal_text` |
| `memory_experience_bindings` | `literal_integer` |
| `memory_experience_bindings` | `literal_real` |
| `memory_experience_bindings` | `literal_boolean` |
| `memory_experience_uses` | `experience_id` |
| `memory_experience_uses` | `event_id` |
| `memory_experience_uses` | `verdict` |
| `memory_schema_migrations` | `to_version` |
| `memory_schema_migrations` | `from_version` |
| `memory_schema_migrations` | `migrated_at_ms` |
| `memory_schema_migrations` | `copy_name` |
| `memory_tasks` | `task_id` |
| `memory_tasks` | `task_uuid` |
| `memory_tasks` | `contract_version` |
| `memory_tasks` | `source` |
| `memory_tasks` | `source_stream_id` |
| `memory_tasks` | `trace_id` |
| `memory_tasks` | `opened_at_ms` |
| `memory_tasks` | `status` |
| `memory_tasks` | `closed_at_ms` |
| `memory_tasks` | `current_revision` |
| `memory_task_revisions` | `task_revision_id` |
| `memory_task_revisions` | `task_id` |
| `memory_task_revisions` | `revision` |
| `memory_task_revisions` | `recorded_at_ms` |
| `memory_task_revisions` | `change_kind` |
| `memory_task_revisions` | `reason` |
| `memory_task_revisions` | `goal` |
| `memory_task_revisions` | `requested_result` |
| `memory_task_constraints` | `task_id` |
| `memory_task_constraints` | `revision` |
| `memory_task_constraints` | `position` |
| `memory_task_constraints` | `constraint_text` |
| `memory_task_constraints` | `task_revision_id` |
| `memory_task_message_refs` | `task_id` |
| `memory_task_message_refs` | `revision` |
| `memory_task_message_refs` | `position` |
| `memory_task_message_refs` | `message_ref` |
| `memory_task_message_refs` | `task_revision_id` |
| `memory_task_attempts` | `task_occurrence_id` |
| `memory_task_attempts` | `task_id` |
| `memory_task_attempts` | `ordinal` |
| `memory_task_attempts` | `resumes_task_occurrence_id` |
| `memory_task_attempts` | `source` |
| `memory_task_attempts` | `source_stream_id` |
| `memory_task_attempts` | `opened_at_ms` |
| `memory_task_attempts` | `opened_at_revision` |
| `memory_task_attempts` | `task_revision_id` |
| `memory_task_attempts` | `takeover` |
| `memory_task_checkpoints` | `checkpoint_id` |
| `memory_task_checkpoints` | `task_occurrence_id` |
| `memory_task_checkpoints` | `sequence` |
| `memory_task_checkpoints` | `checkpoint_kind` |
| `memory_task_checkpoints` | `task_id` |
| `memory_task_checkpoints` | `revision` |
| `memory_task_checkpoints` | `recorded_at_ms` |
| `memory_task_checkpoints` | `declared_status` |
| `memory_task_checkpoints` | `note` |
| `memory_task_checkpoints` | `task_revision_id` |
| `memory_task_values` | `value_id` |
| `memory_task_values` | `task_id` |
| `memory_task_values` | `revision` |
| `memory_task_values` | `task_occurrence_id` |
| `memory_task_values` | `checkpoint_sequence` |
| `memory_task_values` | `position` |
| `memory_task_values` | `name` |
| `memory_task_values` | `role` |
| `memory_task_values` | `value_kind` |
| `memory_task_values` | `content` |
| `memory_task_values` | `text_value` |
| `memory_task_values` | `sensitivity` |
| `memory_task_values` | `source` |
| `memory_task_values` | `source_ref` |
| `memory_task_values` | `source_version` |
| `memory_task_values` | `task_revision_id` |
| `memory_task_values` | `checkpoint_id` |
| `memory_task_values` | `value_digest` |
| `memory_task_call_revisions` | `event_id` |
| `memory_task_call_revisions` | `task_occurrence_id` |
| `memory_task_call_revisions` | `task_id` |
| `memory_task_call_revisions` | `revision` |
| `memory_task_call_revisions` | `task_revision_id` |
| `memory_call_effects` | `event_id` |
| `memory_call_effects` | `performed` |
| `memory_call_effects` | `substitute` |
| `memory_call_effects` | `not_sent_reason` |
| `memory_call_effects` | `target_element_id` |
| `memory_call_effects` | `target_role` |
| `memory_call_effects` | `target_label` |
| `memory_call_effects` | `target_section` |
| `memory_call_effects` | `checked` |
| `memory_call_routes` | `event_id` |
| `memory_call_routes` | `route` |
| `memory_call_routes` | `handoff_reason` |
| `memory_call_adapter_dispatches` | `event_id` |
| `memory_call_adapter_dispatches` | `adapter` |
| `memory_call_adapter_dispatches` | `verb` |
| `memory_call_rungs` | `event_id` |
| `memory_call_rungs` | `rung` |
| `memory_call_rungs` | `how` |
| `memory_call_rungs` | `skipped` |
| `memory_call_route_advice` | `event_id` |
| `memory_call_route_advice` | `decision` |
| `memory_call_route_advice` | `route` |
| `memory_call_route_advice` | `message` |
| `memory_operation_verifications` | `event_id` |
| `memory_operation_verifications` | `call_event_id` |
| `memory_operation_verifications` | `contract_version` |
| `memory_operation_verifications` | `condition_kind` |
| `memory_operation_verifications` | `method_version` |
| `memory_operation_verifications` | `performed` |
| `memory_operation_verifications` | `substitute` |
| `memory_operation_verifications` | `target_element_id` |
| `memory_operation_verifications` | `target_role` |
| `memory_operation_verifications` | `target_label` |
| `memory_operation_verifications` | `target_section` |
| `memory_operation_verification_limits` | `event_id` |
| `memory_operation_verification_limits` | `position` |
| `memory_operation_verification_limits` | `limit_kind` |
| `memory_operation_verification_samples` | `event_id` |
| `memory_operation_verification_samples` | `position` |
| `memory_operation_verification_samples` | `sample_observation_id` |
| `memory_operation_verification_samples` | `sample_event_id` |
| `memory_operation_verification_samples` | `sample_phase` |
| `memory_operation_verification_samples` | `sample_ordinal` |
| `memory_operation_verification_samples` | `sample_kind` |
| `memory_call_recording_gaps` | `event_id` |
| `memory_call_recording_gaps` | `part` |
| `memory_call_recording_gaps` | `reason` |
| `memory_call_recording_gaps` | `detail` |
| `memory_value_redactions` | `redaction_id` |
| `memory_value_redactions` | `event_id` |
| `memory_value_redactions` | `location_kind` |
| `memory_value_redactions` | `argument_name` |
| `memory_value_redactions` | `argument_position` |
| `memory_value_redactions` | `condition_kind` |
| `memory_value_redactions` | `sample_phase` |
| `memory_value_redactions` | `sample_ordinal` |
| `memory_value_redactions` | `element_position` |
| `memory_value_redactions` | `reason` |
| `memory_value_redactions` | `set_id` |
| `memory_value_redactions` | `set_position` |
| `memory_archive_origins` | `origin_id` |
| `memory_archive_origins` | `origin_uuid` |
| `memory_archive_origins` | `origin_kind` |
| `memory_archive_origins` | `location` |
| `memory_archive_origins` | `status` |
| `memory_archive_origins` | `first_seen_at_ms` |
| `memory_archive_origins` | `updated_at_ms` |
| `memory_archive_origins` | `source_schema_version` |
| `memory_archive_origins` | `high_local_order` |
| `memory_archive_origins` | `events_added` |
| `memory_archive_origins` | `events_duplicate` |
| `memory_archive_origins` | `events_renamed` |
| `memory_archive_origins` | `applications_added` |
| `memory_archive_origins` | `applications_duplicate` |
| `memory_archive_origins` | `brains_imported` |
| `memory_archive_origins` | `detail` |
| `memory_origin_events` | `origin_id` |
| `memory_origin_events` | `source_event_id` |
| `memory_origin_events` | `event_id` |
| `memory_origin_events` | `disposition` |
| `memory_origin_brain_contributions` | `origin_id` |
| `memory_origin_brain_contributions` | `bundle_id` |
| `memory_origin_brain_contributions` | `element_kind` |
| `memory_origin_brain_contributions` | `element_key` |
| `memory_origin_brain_contributions` | `disposition` |
| `memory_origin_brain_contributions` | `withheld` |
| `memory_procedure_candidates` | `candidate_id` |
| `memory_procedure_candidates` | `task_id` |
| `memory_procedure_candidates` | `task_occurrence_id` |
| `memory_procedure_candidates` | `policy_version` |
| `memory_procedure_candidates` | `structure_digest` |
| `memory_procedure_candidates` | `checkpoint_sequence` |
| `memory_procedure_candidates` | `built_at_ms` |
| `memory_procedure_candidates` | `step_count` |
| `memory_procedure_candidates` | `block_count` |
| `memory_procedure_candidates` | `checkpoint_id` |
| `memory_candidate_steps` | `candidate_id` |
| `memory_candidate_steps` | `position` |
| `memory_candidate_steps` | `step_occurrence_id` |
| `memory_candidate_steps` | `call_event_id` |
| `memory_candidate_steps` | `block_index` |
| `memory_candidate_steps` | `app_id` |
| `memory_candidate_steps` | `step_kind` |
| `memory_candidate_steps` | `actor` |
| `memory_candidate_steps` | `segment_id` |
| `memory_candidate_steps` | `person_evidence` |
| `memory_procedure_interpretations` | `interpretation_id` |
| `memory_procedure_interpretations` | `candidate_id` |
| `memory_procedure_interpretations` | `revision` |
| `memory_procedure_interpretations` | `contract_version` |
| `memory_procedure_interpretations` | `payload_digest` |
| `memory_procedure_interpretations` | `source` |
| `memory_procedure_interpretations` | `source_stream_id` |
| `memory_procedure_interpretations` | `task_revision` |
| `memory_procedure_interpretations` | `attempt_state` |
| `memory_procedure_interpretations` | `recorded_at_ms` |
| `memory_interpretation_findings` | `interpretation_id` |
| `memory_interpretation_findings` | `position` |
| `memory_interpretation_findings` | `finding` |
| `memory_interpretation_findings` | `step_position` |
| `memory_interpretation_findings` | `argument_name` |
| `memory_interpretation_findings` | `argument_position` |
| `memory_procedure_versions` | `route_id` |
| `memory_procedure_versions` | `interpretation_id` |
| `memory_procedure_versions` | `candidate_id` |
| `memory_procedure_versions` | `task_id` |
| `memory_procedure_versions` | `task_occurrence_id` |
| `memory_procedure_versions` | `contract_version` |
| `memory_procedure_versions` | `variant_of_route_id` |
| `memory_procedure_versions` | `divergence_position` |
| `memory_procedure_versions` | `built_at_ms` |
| `memory_procedure_parts` | `part_id` |
| `memory_procedure_parts` | `part_uuid` |
| `memory_procedure_parts` | `route_id` |
| `memory_procedure_parts` | `part_kind` |
| `memory_procedure_parts` | `parent_part_id` |
| `memory_procedure_parts` | `first_position` |
| `memory_procedure_parts` | `last_position` |
| `memory_procedure_parts` | `step_id` |
| `memory_procedure_parts` | `app_id` |
| `memory_procedure_parts` | `label` |
| `memory_procedure_parts` | `declared_outcome` |
| `memory_part_contract_items` | `part_id` |
| `memory_part_contract_items` | `position` |
| `memory_part_contract_items` | `route_id` |
| `memory_part_contract_items` | `item_kind` |
| `memory_part_contract_items` | `parameter_id` |
| `memory_part_contract_items` | `app_id` |
| `memory_part_contract_items` | `scene_id` |
| `memory_parameter_details` | `parameter_id` |
| `memory_parameter_details` | `route_id` |
| `memory_parameter_details` | `role` |
| `memory_parameter_details` | `value_kind` |
| `memory_parameter_details` | `unit` |
| `memory_parameter_details` | `sensitivity` |
| `memory_parameter_details` | `produced_by_part_id` |
| `memory_operation_argument_segments` | `route_id` |
| `memory_operation_argument_segments` | `operation_id` |
| `memory_operation_argument_segments` | `argument_name` |
| `memory_operation_argument_segments` | `argument_position` |
| `memory_operation_argument_segments` | `argument_index` |
| `memory_operation_argument_segments` | `segment_position` |
| `memory_operation_argument_segments` | `segment_kind` |
| `memory_operation_argument_segments` | `literal_text` |
| `memory_operation_argument_segments` | `parameter_id` |
| `memory_parameter_bindings` | `parameter_id` |
| `memory_parameter_bindings` | `route_id` |
| `memory_parameter_bindings` | `task_occurrence_id` |
| `memory_parameter_bindings` | `content` |
| `memory_parameter_bindings` | `text_value` |
| `memory_parameter_bindings` | `source` |
| `memory_parameter_bindings` | `source_ref` |
| `memory_parameter_bindings` | `source_version` |
| `memory_parameter_bindings` | `value_digest` |
| `memory_procedure_step_occurrences` | `route_id` |
| `memory_procedure_step_occurrences` | `step_id` |
| `memory_procedure_step_occurrences` | `step_occurrence_id` |
| `memory_qualification_policies` | `policy_id` |
| `memory_qualification_policies` | `policy_version` |
| `memory_qualification_policies` | `status` |
| `memory_qualification_policies` | `changed_at_ms` |
| `memory_qualification_policies` | `reason` |
| `memory_part_qualifications` | `qualification_id` |
| `memory_part_qualifications` | `part_id` |
| `memory_part_qualifications` | `sequence` |
| `memory_part_qualifications` | `policy_id` |
| `memory_part_qualifications` | `verdict` |
| `memory_part_qualifications` | `evaluated_at_ms` |
| `memory_part_qualifications` | `complete` |
| `memory_part_qualification_reasons` | `part_id` |
| `memory_part_qualification_reasons` | `sequence` |
| `memory_part_qualification_reasons` | `position` |
| `memory_part_qualification_reasons` | `reason` |
| `memory_part_qualification_reasons` | `step_position` |
| `memory_part_qualification_reasons` | `call_event_id` |
| `memory_part_qualification_reasons` | `qualification_id` |
| `memory_part_qualification_evidence` | `part_id` |
| `memory_part_qualification_evidence` | `sequence` |
| `memory_part_qualification_evidence` | `step_position` |
| `memory_part_qualification_evidence` | `call_event_id` |
| `memory_part_qualification_evidence` | `verification_event_id` |
| `memory_part_qualification_evidence` | `origin` |
| `memory_part_qualification_evidence` | `qualification_id` |
| `memory_part_states` | `part_id` |
| `memory_part_states` | `sequence` |
| `memory_part_states` | `state` |
| `memory_part_states` | `reason_code` |
| `memory_part_states` | `recorded_at_ms` |
| `memory_part_states` | `recorded_by` |
| `memory_part_states` | `origin_id` |
| `brain_relations` | `relation_id` |
| `brain_relations` | `relation_uuid` |
| `brain_relations` | `app_id` |
| `brain_relations` | `context_id` |
| `brain_relations` | `from_scene_id` |
| `brain_relations` | `scene_element_id` |
| `brain_relations` | `verb` |
| `brain_relations` | `arguments_key` |
| `brain_relations` | `to_scene_id` |
| `brain_relations` | `outcome` |
| `brain_relations` | `effect_kind` |
| `brain_relations` | `first_seen_ms` |
| `brain_relations` | `last_seen_ms` |
| `brain_relations` | `kind_id` |
| `brain_relations` | `element_key_id` |
| `brain_relation_proofs` | `relation_id` |
| `brain_relation_proofs` | `call_event_id` |
| `brain_relation_proofs` | `relation` |
| `brain_relation_proofs` | `verification_event_id` |
| `brain_relation_proofs` | `policy_version` |
| `brain_relation_proofs` | `assessed_at_ms` |
| `brain_relation_proofs` | `to_scene_id` |
| `brain_relation_applications` | `call_event_id` |
| `brain_relation_applications` | `app_id` |
| `brain_relation_applications` | `policy_version` |
| `brain_relation_applications` | `outcome` |
| `brain_relation_applications` | `reason` |
| `brain_relation_applications` | `applied_at_ms` |
| `brain_scene_shapes` | `scene_id` |
| `brain_scene_shapes` | `app_id` |
| `brain_scene_shapes` | `role_key` |
| `brain_relation_evaluations` | `evaluation_id` |
| `brain_relation_evaluations` | `call_event_id` |
| `brain_relation_evaluations` | `sequence` |
| `brain_relation_evaluations` | `app_id` |
| `brain_relation_evaluations` | `policy_version` |
| `brain_relation_evaluations` | `cause` |
| `brain_relation_evaluations` | `outcome` |
| `brain_relation_evaluations` | `reason` |
| `brain_relation_evaluations` | `recoverable` |
| `brain_relation_evaluations` | `group_key` |
| `brain_relation_evaluations` | `expected_effect_kind` |
| `brain_relation_evaluations` | `evaluated_at_ms` |
| `brain_relation_evidence` | `relation_id` |
| `brain_relation_evidence` | `call_event_id` |
| `brain_relation_evidence` | `sequence` |
| `brain_relation_evidence` | `relation` |
| `brain_relation_evidence` | `verification_event_id` |
| `brain_relation_evidence` | `policy_version` |
| `brain_relation_evidence` | `assessed_at_ms` |
| `brain_relation_evidence` | `evaluation_id` |
| `brain_anchor_label_keys` | `label_key_id` |
| `brain_anchor_label_keys` | `anchor_id` |
| `brain_anchor_label_keys` | `app_id` |
| `brain_anchor_label_keys` | `label_key` |
| `brain_anchor_label_keys` | `replaced_by_id` |
| `memory_variant_prefixes` | `route_id` |
| `memory_variant_prefixes` | `status` |
| `memory_variant_prefixes` | `compared_steps` |
| `memory_variant_prefixes` | `reason` |
| `memory_variant_prefixes` | `checked_at_ms` |
| `memory_variant_prefix_checks` | `route_id` |
| `memory_variant_prefix_checks` | `status` |
| `memory_variant_prefix_checks` | `compared_steps` |
| `memory_variant_prefix_checks` | `reason` |
| `memory_variant_prefix_checks` | `checked_at_ms` |
| `memory_recall_spaces` | `space_int_id` |
| `memory_recall_spaces` | `space_id` |
| `memory_recall_spaces` | `model_id` |
| `memory_recall_spaces` | `model_revision` |
| `memory_recall_spaces` | `weights_digest` |
| `memory_recall_spaces` | `tokenizer_digest` |
| `memory_recall_spaces` | `dimensions` |
| `memory_recall_spaces` | `pooling` |
| `memory_recall_spaces` | `normalization` |
| `memory_recall_spaces` | `precision` |
| `memory_recall_spaces` | `query_prefix` |
| `memory_recall_spaces` | `document_prefix` |
| `memory_recall_spaces` | `maximum_tokens` |
| `memory_recall_spaces` | `recorded_at_ms` |
| `memory_recall_generations` | `generation_id` |
| `memory_recall_generations` | `document_format` |
| `memory_recall_generations` | `space_int_id` |
| `memory_recall_generations` | `status` |
| `memory_recall_generations` | `cursor_route_id` |
| `memory_recall_generations` | `enumerated` |
| `memory_recall_generations` | `revision` |
| `memory_recall_generations` | `started_at_ms` |
| `memory_recall_generations` | `ready_at_ms` |
| `memory_recall_generations` | `ended_at_ms` |
| `memory_recall_generations` | `reason` |
| `memory_recall_documents` | `document_id` |
| `memory_recall_documents` | `text_id` |
| `memory_recall_documents` | `document_format` |
| `memory_recall_documents` | `recorded_at_ms` |
| `memory_recall_vectors` | `text_id` |
| `memory_recall_vectors` | `space_int_id` |
| `memory_recall_vectors` | `token_count` |
| `memory_recall_vectors` | `truncated` |
| `memory_recall_vectors` | `vector` |
| `memory_recall_entries` | `generation_id` |
| `memory_recall_entries` | `part_id` |
| `memory_recall_entries` | `route_id` |
| `memory_recall_entries` | `part_kind` |
| `memory_recall_entries` | `document_id` |
| `memory_recall_entries` | `qualification_sequence` |
| `memory_recall_entries` | `state_sequence` |
| `memory_recall_entries` | `entered_at_ms` |
| `memory_recall_work` | `work_id` |
| `memory_recall_work` | `route_id` |
| `memory_recall_work` | `reason` |
| `memory_recall_work` | `enqueued_at_ms` |
| `memory_recall_work` | `done_at_ms` |
| `memory_recall_work` | `attempts` |
| `memory_recall_work` | `last_error` |
| `memory_recall_queries` | `query_id` |
| `memory_recall_queries` | `task_id` |
| `memory_recall_queries` | `task_occurrence_id` |
| `memory_recall_queries` | `task_revision` |
| `memory_recall_queries` | `source` |
| `memory_recall_queries` | `source_stream_id` |
| `memory_recall_queries` | `reason` |
| `memory_recall_queries` | `remaining_work` |
| `memory_recall_queries` | `generation_id` |
| `memory_recall_queries` | `channel` |
| `memory_recall_queries` | `search_status` |
| `memory_recall_queries` | `search_note` |
| `memory_recall_queries` | `candidate_limit` |
| `memory_recall_queries` | `candidates_considered` |
| `memory_recall_queries` | `coverage` |
| `memory_recall_queries` | `delivery` |
| `memory_recall_queries` | `delivery_bytes` |
| `memory_recall_queries` | `selector_version` |
| `memory_recall_queries` | `recorded_at_ms` |
| `memory_recall_queries` | `duration_us` |
| `memory_recall_needs` | `need_id` |
| `memory_recall_needs` | `query_id` |
| `memory_recall_needs` | `position` |
| `memory_recall_needs` | `text` |
| `memory_recall_needs` | `bundle_id` |
| `memory_recall_needs` | `coverage` |
| `memory_recall_needs` | `reason` |
| `memory_recall_selections` | `selection_id` |
| `memory_recall_selections` | `query_id` |
| `memory_recall_selections` | `need_position` |
| `memory_recall_selections` | `position` |
| `memory_recall_selections` | `role` |
| `memory_recall_selections` | `route_id` |
| `memory_recall_selections` | `first_position` |
| `memory_recall_selections` | `last_position` |
| `memory_recall_selections` | `whole_part_id` |
| `memory_recall_selections` | `relevance` |
| `memory_recall_selections` | `preparations` |
| `memory_recall_selections` | `need_id` |
| `memory_recall_requirements` | `query_id` |
| `memory_recall_requirements` | `need_position` |
| `memory_recall_requirements` | `selection_position` |
| `memory_recall_requirements` | `position` |
| `memory_recall_requirements` | `kind` |
| `memory_recall_requirements` | `step_position` |
| `memory_recall_requirements` | `parameter_id` |
| `memory_recall_requirements` | `scene_id` |
| `memory_recall_requirements` | `bundle_id` |
| `memory_recall_requirements` | `task_value_name` |
| `memory_recall_requirements` | `binding_match` |
| `memory_recall_requirements` | `constraint_position` |
| `memory_recall_requirements` | `selection_id` |
| `memory_recall_links` | `query_id` |
| `memory_recall_links` | `need_position` |
| `memory_recall_links` | `call_event_id` |
| `memory_recall_links` | `step_position` |
| `memory_recall_links` | `confirmed` |
| `memory_recall_links` | `undetermined` |
| `memory_recall_links` | `linked_at_ms` |
| `memory_recall_links` | `need_id` |
| `memory_recall_reports` | `query_id` |
| `memory_recall_reports` | `need_position` |
| `memory_recall_reports` | `sequence` |
| `memory_recall_reports` | `declared` |
| `memory_recall_reports` | `cause` |
| `memory_recall_reports` | `note` |
| `memory_recall_reports` | `recorded_at_ms` |
| `memory_recall_reports` | `need_id` |
| `memory_recall_proposals` | `proposal_id` |
| `memory_recall_proposals` | `task_id` |
| `memory_recall_proposals` | `task_occurrence_id` |
| `memory_recall_proposals` | `task_revision` |
| `memory_recall_proposals` | `source` |
| `memory_recall_proposals` | `source_stream_id` |
| `memory_recall_proposals` | `reason` |
| `memory_recall_proposals` | `remaining_work` |
| `memory_recall_proposals` | `generation_id` |
| `memory_recall_proposals` | `channel` |
| `memory_recall_proposals` | `search_status` |
| `memory_recall_proposals` | `search_note` |
| `memory_recall_proposals` | `candidates_considered` |
| `memory_recall_proposals` | `proposal_bytes` |
| `memory_recall_proposals` | `format_version` |
| `memory_recall_proposals` | `recorded_at_ms` |
| `memory_recall_proposals` | `duration_us` |
| `memory_recall_proposal_needs` | `proposal_need_id` |
| `memory_recall_proposal_needs` | `proposal_id` |
| `memory_recall_proposal_needs` | `position` |
| `memory_recall_proposal_needs` | `text` |
| `memory_recall_proposal_needs` | `bundle_id` |
| `memory_recall_proposal_sources` | `proposal_id` |
| `memory_recall_proposal_sources` | `need_position` |
| `memory_recall_proposal_sources` | `position` |
| `memory_recall_proposal_sources` | `source_key` |
| `memory_recall_proposal_sources` | `route_id` |
| `memory_recall_proposal_sources` | `relevance` |
| `memory_recall_proposal_sources` | `suggested_first` |
| `memory_recall_proposal_sources` | `suggested_last` |
| `memory_recall_proposal_sources` | `proposal_need_id` |
| `memory_recall_choices` | `query_id` |
| `memory_recall_choices` | `proposal_id` |
| `memory_recall_choices` | `recorded_at_ms` |
| `memory_recall_choice_needs` | `query_id` |
| `memory_recall_choice_needs` | `need_position` |
| `memory_recall_choice_needs` | `declared` |
| `memory_recall_choice_needs` | `uncovered` |
| `memory_recall_choice_needs` | `settled_by` |
| `memory_recall_choice_needs` | `need_id` |
| `memory_recall_choice_links` | `query_id` |
| `memory_recall_choice_links` | `need_position` |
| `memory_recall_choice_links` | `selection_position` |
| `memory_recall_choice_links` | `call_event_id` |
| `memory_recall_choice_links` | `step_position` |
| `memory_recall_choice_links` | `confirmed` |
| `memory_recall_choice_links` | `undetermined` |
| `memory_recall_choice_links` | `linked_at_ms` |
| `memory_recall_choice_links` | `need_id` |
| `memory_recall_choice_links` | `selection_id` |
| `memory_call_argument_fields` | `event_id` |
| `memory_call_argument_fields` | `field_path` |
| `memory_call_argument_fields` | `value_kind` |
| `memory_call_argument_fields` | `field_kind` |
| `memory_call_argument_fields` | `text_value` |
| `memory_call_argument_fields` | `withheld_reason` |
| `memory_call_argument_fields` | `source_event_id` |
| `memory_call_argument_fields` | `source_path` |
| `memory_call_result_fields` | `event_id` |
| `memory_call_result_fields` | `field_path` |
| `memory_call_result_fields` | `value_kind` |
| `memory_call_result_fields` | `text_value` |
| `memory_call_result_fields` | `withheld_reason` |
| `memory_operation_argument_fields` | `route_id` |
| `memory_operation_argument_fields` | `operation_id` |
| `memory_operation_argument_fields` | `argument_name` |
| `memory_operation_argument_fields` | `argument_position` |
| `memory_operation_argument_fields` | `field_path` |
| `memory_operation_argument_fields` | `field_kind` |
| `memory_operation_argument_fields` | `value_kind` |
| `memory_operation_argument_fields` | `text_value` |
| `memory_operation_argument_fields` | `parameter_id` |
| `memory_operation_argument_fields` | `source_step_position` |
| `memory_operation_argument_fields` | `source_path` |
| `memory_call_data_contexts` | `event_id` |
| `memory_call_data_contexts` | `service` |
| `memory_call_data_contexts` | `route` |
| `memory_call_data_contexts` | `profile_ref` |
| `memory_call_data_contexts` | `account_ref` |
| `memory_call_data_contexts` | `account_source` |
| `memory_call_data_contexts` | `resource_kind` |
| `memory_call_data_contexts` | `resource_ref` |
| `memory_identity_salts` | `salt_id` |
| `memory_identity_salts` | `salt` |
| `memory_executors` | `executor_id` |
| `memory_executors` | `source` |
| `memory_executors` | `process_id` |
| `memory_executors` | `started_at_ms` |
| `memory_call_executors` | `event_id` |
| `memory_call_executors` | `executor_id` |
| `memory_call_reconciliations` | `event_id` |
| `memory_call_reconciliations` | `sequence` |
| `memory_call_reconciliations` | `kind` |
| `memory_call_reconciliations` | `finding` |
| `memory_call_reconciliations` | `evidence_event_id` |
| `memory_call_reconciliations` | `declared_by` |
| `memory_call_reconciliations` | `recorded_at_ms` |
| `memory_call_reconciliations` | `detail` |
| `memory_todo_revisions` | `todo_revision_id` |
| `memory_todo_revisions` | `task_id` |
| `memory_todo_revisions` | `revision` |
| `memory_todo_revisions` | `task_revision_id` |
| `memory_todo_revisions` | `reason_kind` |
| `memory_todo_revisions` | `reason_text` |
| `memory_todo_revisions` | `recorded_at_ms` |
| `memory_todo_items` | `item_id` |
| `memory_todo_items` | `item_uuid` |
| `memory_todo_items` | `task_id` |
| `memory_todo_items` | `first_revision` |
| `memory_todo_items` | `row_key` |
| `memory_todo_items` | `origin` |
| `memory_todo_item_states` | `item_id` |
| `memory_todo_item_states` | `todo_revision_id` |
| `memory_todo_item_states` | `position` |
| `memory_todo_item_states` | `title` |
| `memory_todo_item_states` | `app_name` |
| `memory_todo_item_states` | `linked_part_id` |
| `memory_todo_item_states` | `status` |
| `memory_todo_item_states` | `closed_by` |
| `memory_todo_item_states` | `check_verdict` |
| `memory_todo_item_states` | `expectation_revision_id` |
| `memory_todo_item_expectations` | `item_id` |
| `memory_todo_item_expectations` | `todo_revision_id` |
| `memory_todo_item_expectations` | `predicate_position` |
| `memory_todo_item_expectations` | `kind` |
| `memory_todo_item_expectations` | `operand` |
| `memory_todo_item_expectations` | `parameter_name` |
| `memory_todo_item_expectations` | `second_parameter_name` |
| `memory_todo_item_expectations` | `app_id` |
| `memory_todo_item_expectations` | `subject_key` |
| `memory_todo_item_expectations` | `expected_state` |
| `memory_todo_item_expectations` | `presence` |
| `memory_call_steps` | `event_id` |
| `memory_call_steps` | `item_id` |
| `memory_task_end_checks` | `task_occurrence_id` |
| `memory_task_end_checks` | `verdict` |
| `memory_task_end_checks` | `scope` |
| `memory_task_end_checks` | `goal_match` |
| `memory_gesture_evidence` | `event_id` |
| `memory_gesture_evidence` | `comparable` |
| `memory_gesture_evidence` | `looked_again` |
| `memory_gesture_evidence` | `settle_kind` |
| `memory_gesture_evidence` | `settle_ending` |
| `memory_gesture_evidence` | `settle_detail` |
| `memory_gesture_evidence` | `settle_waited_ms` |
| `memory_gesture_evidence` | `settle_cap_ms` |
| `memory_gesture_evidence` | `settle_channels` |
| `memory_gesture_evidence` | `settle_surfaces` |
| `memory_gesture_evidence` | `readback` |
| `memory_gesture_evidence` | `verdict_change_position` |
| `memory_gesture_evidence` | `verdict_differs_from_learning` |
| `memory_gesture_changes` | `event_id` |
| `memory_gesture_changes` | `position` |
| `memory_gesture_changes` | `kind` |
| `memory_gesture_changes` | `subject_key` |
| `memory_gesture_changes` | `scope` |
| `memory_gesture_changes` | `stability` |
| `memory_gesture_changes` | `family` |
| `memory_batch_stops` | `event_id` |
| `memory_batch_stops` | `stopped_at_position` |
| `memory_batch_stops` | `reason` |
| `memory_operation_argument_links` | `event_id` |
| `memory_operation_argument_links` | `argument_name` |
| `memory_operation_argument_links` | `position` |
| `memory_operation_argument_links` | `link_kind` |
| `memory_operation_argument_links` | `parameter_name` |
| `memory_operation_argument_links` | `template` |
| `memory_operation_argument_links` | `derivation` |
| `memory_operation_argument_links` | `field_role` |
| `memory_operation_argument_links` | `value_digest` |
| `memory_step_signatures` | `signature_id` |
| `memory_step_signatures` | `app_id` |
| `memory_step_signatures` | `signature_digest` |
| `memory_step_signatures` | `verb` |
| `memory_step_signatures` | `element_key_id` |
| `memory_step_signatures` | `arguments_shape` |
| `memory_step_signature_members` | `signature_id` |
| `memory_step_signature_members` | `step_id` |
| `memory_phase_families` | `family_id` |
| `memory_phase_families` | `app_id` |
| `memory_phase_families` | `kind` |
| `memory_phase_families` | `method_text` |
| `memory_phase_families` | `method_digest` |
| `memory_phase_families` | `masked_digest` |
| `memory_phase_families` | `has_parameter` |
| `memory_phase_families` | `length` |
| `memory_phase_families` | `label` |
| `memory_phase_families` | `labels` |
| `memory_phase_families` | `members` |
| `memory_phase_families` | `procedures` |
| `memory_phase_families` | `first_member_seq` |
| `memory_phase_families` | `first_attempt_id` |
| `memory_phase_families` | `latest_route_id` |
| `memory_phase_families` | `recorded_at_ms` |
| `memory_phase_family_attempts` | `family_id` |
| `memory_phase_family_attempts` | `task_occurrence_id` |
| `memory_phase_family_attempts` | `members` |
| `memory_phase_family_attempts` | `routes` |
| `memory_phase_family_attempts` | `labels` |
| `memory_recall_texts` | `text_id` |
| `memory_recall_texts` | `digest` |
| `memory_recall_texts` | `format` |
| `memory_recall_texts` | `text` |
| `memory_recall_text_pieces` | `text_id` |
| `memory_recall_text_pieces` | `position` |
| `memory_recall_text_pieces` | `piece_kind` |
| `memory_recall_text_pieces` | `piece_text_id` |
| `memory_recall_calibration` | `query_id` |
| `memory_recall_calibration` | `need_position` |
| `memory_recall_calibration` | `part_id` |
| `memory_recall_calibration` | `rank` |
| `memory_recall_calibration` | `cosine` |
| `memory_recall_calibration` | `lexical` |
| `memory_recall_calibration` | `score` |
| `memory_recall_calibration` | `threshold` |
| `memory_recall_calibration` | `delivered` |
| `memory_recall_calibration` | `used` |
| `memory_part_misses` | `miss_id` |
| `memory_part_misses` | `item_id` |
| `memory_part_misses` | `query_id` |
| `memory_part_misses` | `part_id` |
| `memory_part_misses` | `similarity` |
| `memory_part_misses` | `recorded_at_ms` |
| `memory_part_reuse` | `part_id` |
| `memory_part_reuse` | `offered` |
| `memory_part_reuse` | `used` |
| `memory_part_reuse` | `succeeded` |
| `memory_part_reuse` | `updated_at_ms` |
| `memory_attempt_reused_parts` | `reuse_id` |
| `memory_attempt_reused_parts` | `task_occurrence_id` |
| `memory_attempt_reused_parts` | `part_id` |
| `memory_attempt_reused_parts` | `item_id` |
| `memory_attempt_reused_parts` | `recorded_at_ms` |
| `memory_elements` | `element_id` |
| `memory_elements` | `digest` |
| `memory_elements` | `role` |
| `memory_elements` | `kind` |
| `memory_elements` | `label` |
| `memory_elements` | `label_origin` |
| `memory_elements` | `container_path` |
| `memory_elements` | `state` |
| `memory_elements` | `replaced_by_id` |
| `memory_element_sets` | `set_id` |
| `memory_element_sets` | `digest` |
| `memory_element_sets` | `members` |
| `memory_element_sets` | `replaced_by_id` |
| `brain_element_keys` | `element_key_id` |
| `brain_element_keys` | `app_id` |
| `brain_element_keys` | `key_text` |
| `brain_element_keys` | `digest` |
| `brain_element_keys` | `first_seen_ms` |
| `brain_element_keys` | `replaced_by_id` |
| `brain_screen_kinds` | `kind_id` |
| `brain_screen_kinds` | `kind_uuid` |
| `brain_screen_kinds` | `app_id` |
| `brain_screen_kinds` | `method_name` |
| `brain_scene_kind_members` | `membership_id` |
| `brain_scene_kind_members` | `scene_id` |
| `brain_scene_kind_members` | `kind_id` |
| `brain_scene_kind_members` | `since_ms` |
| `brain_scene_kind_members` | `merge_id` |
| `brain_scene_merges` | `merge_id` |
| `brain_scene_merges` | `app_id` |
| `brain_scene_merges` | `subject` |
| `brain_scene_merges` | `from_scene_id` |
| `brain_scene_merges` | `into_scene_id` |
| `brain_scene_merges` | `from_kind_id` |
| `brain_scene_merges` | `into_kind_id` |
| `brain_scene_merges` | `action` |
| `brain_scene_merges` | `recorded_by` |
| `brain_scene_merges` | `reason_code` |
| `brain_scene_merges` | `origin_id` |
| `brain_scene_merges` | `recorded_at_ms` |
| `memory_consolidation_queue` | `seq` |
| `memory_consolidation_queue` | `job_kind` |
| `memory_consolidation_queue` | `ref_id` |
| `memory_consolidation_queue` | `enqueued_at_ms` |
| `memory_consolidation_cursors` | `job_kind` |
| `memory_consolidation_cursors` | `last_seq` |
| `memory_consolidation_cursors` | `algorithm_version` |
| `memory_consolidation_cursors` | `generation` |
| `memory_consolidation_cursors` | `backfill_after_fact_id` |
| `memory_consolidation_cursors` | `backfill_until_fact_id` |
| `memory_consolidation_cursors` | `queue_from_seq` |
| `memory_consolidation_cursors` | `continuation` |
| `memory_part_judgments` | `judgment_id` |
| `memory_part_judgments` | `part_id` |
| `memory_part_judgments` | `family_root_route_id` |
| `memory_part_judgments` | `judgment` |
| `memory_part_judgments` | `recorded_by` |
| `memory_part_judgments` | `reason_code` |
| `memory_part_judgments` | `origin_id` |
| `memory_part_judgments` | `recorded_at_ms` |
| `memory_forget_tombstones` | `tombstone_id` |
| `memory_forget_tombstones` | `tombstone_uuid` |
| `memory_forget_tombstones` | `bundle_id` |
| `memory_forget_tombstones` | `key_kind` |
| `memory_forget_tombstones` | `method_key` |
| `memory_forget_tombstones` | `verb` |
| `memory_forget_tombstones` | `recorded_at_ms` |
| `memory_forget_tombstones` | `reason_code` |
| `memory_part_origins` | `part_id` |
| `memory_part_origins` | `origin_id` |
| `memory_part_origins` | `source_part_uuid` |
| `memory_part_origins` | `recorded_at_ms` |
| `memory_procedure_provenance` | `route_id` |
| `memory_procedure_provenance` | `third_party_content` |
| `memory_procedure_provenance` | `exit_point` |
| `memory_procedure_provenance` | `person_episode` |
| `memory_procedure_provenance` | `learned_via` |
| `memory_procedure_provenance` | `client_ref` |
| `memory_procedure_provenance` | `confirmed` |
| `memory_procedure_provenance` | `confirmed_by_attempt` |
| `memory_procedure_exit_points` | `route_id` |
| `memory_procedure_exit_points` | `step_position` |
| `memory_procedure_exit_points` | `exit_point` |
| `memory_person_segments` | `segment_id` |
| `memory_person_segments` | `task_occurrence_id` |
| `memory_person_segments` | `before_event_id` |
| `memory_person_segments` | `after_event_id` |
| `memory_person_segments` | `started_at_ms` |
| `memory_person_segments` | `ended_at_ms` |
| `memory_person_segments` | `reason` |
| `memory_person_segments` | `person_only_kind` |
| `memory_person_segments` | `coverage` |
| `memory_segment_checks` | `segment_id` |
| `memory_segment_checks` | `position` |
| `memory_segment_checks` | `kind` |
| `memory_segment_checks` | `app_id` |
| `memory_segment_checks` | `window_number` |
| `memory_segment_checks` | `subject_key` |
| `memory_segment_checks` | `operand` |
| `memory_segment_checks` | `parameter_name` |
| `memory_segment_checks` | `expected_state` |
| `memory_segment_checks` | `coverage` |
| `memory_person_commands` | `command_id` |
| `memory_person_commands` | `segment_id` |
| `memory_person_commands` | `position` |
| `memory_person_commands` | `kind` |
| `memory_person_commands` | `element_key_id` |
| `memory_person_commands` | `menu_path` |
| `memory_person_commands` | `key_code` |
| `memory_person_commands` | `modifiers` |
| `memory_person_commands` | `effect_kind` |
| `memory_person_commands` | `coverage` |
| `memory_person_commands` | `cause` |
| `memory_person_commands` | `scene_before_id` |
| `memory_person_commands` | `scene_after_id` |
| `memory_person_commands` | `arrival_kind` |
| `memory_person_commands` | `arrival_state` |
| `memory_person_commands` | `arrival_parameter` |
| `memory_call_capabilities` | `event_id` |
| `memory_call_capabilities` | `capability_id` |
| `memory_call_capabilities` | `effect_class` |
| `memory_call_capabilities` | `channel` |
| `memory_call_capabilities` | `origin` |
| `memory_call_capabilities` | `origin_name` |
| `memory_step_capabilities` | `step_id` |
| `memory_step_capabilities` | `position` |
| `memory_step_capabilities` | `capability_id` |

| `memory_brain_command_inputs` | `command_input_id` |
| `memory_brain_command_inputs` | `event_id` |
| `memory_brain_command_inputs` | `sample_observation_id` |
| `memory_brain_command_inputs` | `operation` |
| `memory_brain_command_inputs` | `requested_at_ms` |
| `memory_brain_command_inputs` | `contract_version` |
| `memory_brain_command_inputs` | `detection_count` |
| `memory_brain_command_inputs` | `window` |
| `memory_brain_command_inputs` | `capture_completeness` |
| `memory_brain_command_inputs` | `capture_surface` |
| `memory_brain_command_inputs` | `representation` |
| `memory_brain_command_inputs` | `spatial_coverage` |
| `memory_brain_command_inputs` | `verb` |
| `memory_brain_command_inputs` | `effect_event_id` |
| `memory_brain_command_detections` | `command_input_id` |
| `memory_brain_command_detections` | `position` |
| `memory_brain_command_detections` | `kind` |
| `memory_brain_command_detections` | `label` |
| `memory_brain_command_detections` | `x` |
| `memory_brain_command_detections` | `y` |
| `memory_brain_command_detections` | `width` |
| `memory_brain_command_detections` | `height` |
| `memory_brain_command_detections` | `state` |

## Durable Brain command inputs

SK4's dry-run closure §3 names BrainApplicationCommand.observe(detections:window:bundleID:sample:requestedAt:coverage:) and record(verb:target:effect:), defined in Sources/Engine/Memory/Brain/BrainApplication.swift:89,201,217 at the audited revision. SK3 defines queue sequencing, not another command payload. The queue remains (seq, job_kind, ref_id, enqueued_at_ms); its timestamp is not the Brain request timestamp.

The two new STRICT child tables keep the normalized input independently of queue cleanup. memory_brain_command_inputs has an integer command_input_id PK, simple event/sample/effect FKs, requested_at_ms INTEGER, contract_version INTEGER, detection_count INTEGER and typed TEXT columns for operation, window, capture_completeness, capture_surface, representation, spatial_coverage and verb. Partial UNIQUE indexes allow one observe input per sample and one record input per event. Event UUID and bundle ID come from the immutable event/application identity; phase and ordinal come from the referenced capture.

memory_brain_command_detections has PK (command_input_id, position), kind TEXT, label TEXT, x/y/width/height REAL and nullable state TEXT. Observe stores every BrainDetection in command order, including pixel-only and unlabeled detections; record stores its exact resolved target at position zero. No role is required, so CaptureElement's role filter cannot discard these inputs. label TEXT NOT NULL is exactly the same minimized text that schema 19 already stores as detection_label/target_label in memory_operation_arguments. SK4 writes it only after ValueMinimization, including the existing confidential-surface rules; unlabeled detections retain the same empty detection_label. This does not introduce a different label-retention policy. There is no element value or free-form instance-value column. Both tables refuse every UPDATE and DELETE. The nullable state preserves absence separately from the unknown state code; empty label remains distinct from absent text.

For record, CHECK (effect_event_id IS NULL OR effect_event_id = event_id) enforces same-event ownership. effect_event_id is NULL for no effect, otherwise it identifies the same call's saved typed effect in memory_agent_actions and ordered items in memory_agent_action_effect_labels. Existing observed_effect_kind/text, observed_state_before/after, observed_effect_label/value and item labels supply every effect field without a second value-text column. These episode facts keep their existing minimization rules. Coverage preserves version 1 absence, version 2 legacy_window, and version 3 visible/whole_surface explicitly.

SK4 must adapt the producer to seal these normalized inputs in the same essential transaction as the sample or call end and queue entry. In particular, it must copy CallRecorder's original requestedAt and resolved target before RAM is lost; a later queued job cannot recover them. DB2 owns repository adaptation and conversion. Context checks (sample kind/event/app agreement, effect payload agreement, contiguous positions and count, one record target) belong to SchemaCoherence and SK4's typed reader, not new cross-table validation triggers. SK4 retains the saved verification/redaction eligibility filters named in its plan.

Conversion from 19, 20 and 21 creates no speculative command-input rows. Historical added fields are NULL through a LEFT JOIN, even where an already concluded Brain application's arguments happen to survive. Existing application arguments remain available for their own replay; they are not represented as previously captured source inputs. Absence is a declared historical durability gap, never a zero rectangle or a guessed timestamp.

brainCommandFieldsHaveTypedStorage enumerates the actual BrainApplicationContract argument specs for observe/record and all supported versions, checks every name's physical column, SQLite type and nullability against cardinality, and checks command identity, request time, queue references and STRICT storage. brainCommandInputsRoundTrip proves exact command equality for ordered pixel/control detections and a resolved target with independent geometry/state, request times, coverage and saved state-flip, valueChanged and ordered-list effects; it also checks historical NULL absence, every-column immutability and DELETE refusal. The tests first failed against the missing tables (69 issues), then passed. They prove the DDL storage contract; SK4's future producer/reconstruction integration and full replay corpus remain SK4 work.

Cardinality one requires a non-NULL value for the operation/version that admits the argument. Required detection/target fields and the common detection_count have physical NOT NULL columns. The shared header's verb is required by a CHECK only for record; coverage fields are required by CHECKs only for observe versions 2/3. They stay NULL where the contract does not admit them. The test checks both pragma_table_info.notnull and NULL-insert rejection under each applicable contract, avoiding a requirement to store invented coverage or a verb in unrelated rows. Optional fields preserve NULL; required list-item fields are NOT NULL within each row, while an absent list has no rows.

brainCommandEffectBelongsToItsEvent first demonstrated that a valid effect from another existing event was accepted, then passed after the ownership CHECK. Value-change text and ordered items are tested in separate round trips: TransitionEffectRecord forbids items on valueChanged, so that combination is explicitly rejected rather than added to the contract.

## Space per action

Desk estimates only, not measured behavior. The source figures are 30.5 MB / 1,020 actions; decimal KB are used consistently below. No source archive was opened, copied or converted. Rounded source shares include indexes. All three options preserve every command field, including exact resolved target bounds/state; option (c) shares observe detections with the sample instead of storing a second copy.

| Source family | Source share | Current KB/action | (a) Drop other sample evidence | (b) Keep with duplicate observe rows | (c) Keep and derive observe inputs | Assumption |
| --- | --- | --- | --- | --- | --- | --- |
| Observations, before new command inputs | 37.9% | 11.33 | 1.80 | 11.33 | 11.33 | Keep scenarios credit no unmeasured saving on the source observation family |
| Durable command inputs, new | — | — | 2.00 | 2.00 | 0.50 | (a)/(b): complete separate command storage; (c): headers and independent resolved record targets only |
| Extra complete-sample facts for (c) | — | — | 0.00 | 0.00 | 0.50 | Pixel-only detections, exact order and unlabeled flags missing from schema 19 samples |
| Operation arguments | 12.3% | 3.68 | 1.10 | 1.10 | 1.10 | Integer owner identities, no contextual parent UNIQUE indexes |
| Redactions | 7.1% | 2.12 | 0.55 | 0.55 | 0.55 | Integer owner/set identities and shared structural content |
| Brain arguments | 6.7% | 2.00 | 0.50 | 0.50 | 0.50 | Existing application inputs remain separate from the proposed source inputs |
| Brain evidence | 3.8% | 1.14 | 0.35 | 0.35 | 0.35 | Simple integer references and removed contextual parent indexes |
| Other rows and indexes | 32.2% | 9.63 | 3.50 | 3.50 | 3.50 | Integer identities, shared Recall text; allowance for new facts and lookup indexes |
| Observations including new inputs/facts | — | — | 3.80 | 13.33 | 12.33 | Subtotal only; do not add again |
| Total | 100% | 29.90 | 9.80 | 19.33 | 18.33 | Owner alternatives; none selected |

The 2.00 KB/action command-input allocation for (a)/(b) is a planning proxy from 30.5 MB × 6.7% / 1,020, rounded; it is not a measurement or an upper bound. It includes command headers, all ordered observe detections, resolved record targets and indexes. It is additional to the existing application-argument budget because durable source inputs and concluded application arguments are distinct rows. In (b), role-bearing observe detections occur twice: once in sample elements and once in command detections; the two copies are charged separately.

For (c), the explicit comparison scenario splits that 2.00 allocation into 0.50 for headers/resolved record targets and 1.50 for separate observe detections. It removes the 1.50 observe copy, but adds 0.50 for sample facts currently missing: pixel-only detections, exact full-scene order and unlabeled flags. Thus (c) uses 11.33 + 0.50 + 0.50 = 12.33 observations KB/action and 12.33 + 6.00 = 18.33 total. These 0.50/1.50/0.50 allocations are declared sensitivity assumptions, not source measurements or an observed ratio. The source documents contain no counts, label-length distribution or reuse ratio that could determine the split. A zero-cost extension of the old structural sample would be incorrect.

Let S be retained sample KB/action, C be complete separate command-input KB/action, H be command-header/resolved-target KB/action, and P be the extra sample facts needed for exact observe reconstruction. The formulas are (a) observations = 1.80 + C; (b) observations = S + C; (c) observations = S + H + P. Add the unchanged 6.00 KB/action allocation for other families to obtain each total. The table uses S = 11.33, C = 2.00, H = 0.50 and P = 0.50. Option (c) saves C − H − P = 1.00 only in that scenario; it saves space versus (b) only if H + P < C. If H + P = 2.00, its budget is the same 13.33 observations / 19.33 total as (b). No measured saving is claimed.

At 1,020 actions the source plan's 3.45 MiB contextual-parent index saving is about 3.55 KB/action. It is context for component assumptions, not another deduction. The former 7.80 KB/action total omitted durable command inputs and is superseded. DB2 must measure a converted baseline. The 10 KB/action gate leaves 0.20 headroom in (a); (b) and the stated (c) scenario exceed it by 9.33 and 8.33 respectively and require reopening the form before approval. No evidence-retention decision or performance result follows from these allocations.

## Open questions

1. COERENZA still calls the state codes and todo limits provisional and proposes 20 rows. DB1 records R-G-32 and R-A-50 as approved and specifies 10 rows. DB1 is authoritative here; TU6 must use 10, title 120 and expectation 160.
2. Owner-visible label note: memory_brain_command_detections.label is exactly the same minimized text that schema 19 already stores as detection_label/target_label in memory_operation_arguments. SK4 writes it only after ValueMinimization, including confidential-surface handling. The owner must be able to see that (a)/(b) retain a second copy of this existing minimized text; no different text-admission policy is introduced. The DDL field-capacity gate now passes: brainCommandFieldsHaveTypedStorage checks every observe/record command argument name, type and required/optional nullability against BrainApplicationContract; brainCommandInputsRoundTrip checks exact representative commands, including pixel-only detections, resolved target kind/bounds/state and the original Brain request timestamp. Both tests were red before the child tables existed, then green. See Durable Brain command inputs for the complete contract, SK4/DB2 writer duties and historical NULL rule. This closes the missing-storage question; SK4's production integration/full corpus and Tommaso's DDL approval are still pending.
3. Owner approval required: memory_phase_families.labels and memory_phase_family_attempts.labels contain sorted JSON, which conflicts with the general “no JSON column” rule. Accept the encoding as an explicit exception for rebuildable derived data, or require child tables before approval. The current representation is provisional; no choice is assumed.
4. Owner approval required: choose the extent of non-command sample evidence only after reviewing the following audited readers and all three budgets. All alternatives retain every command field and exact resolved target bounds/state; (c) derives observe detections from an extended sample. No alternative has been selected. The original 1.80 observations / 7.80 total omitted those durable inputs.

### Question 4: reader evidence at 0e594d72

This is a read-only audit of Sources/, Tools/ and BrausApp/ at 0e594d722e139a29e1801d0fc4b9afebab200d46. Direct SQL readers were followed through sample decoding, exact comparison, structural consumers, transfer and the related derived tables. Source locations below refer to that revision. A producer's RAM scene, screenshot frame or AppKit bounds is not a persisted sample reader.

| Reader at the audited revision | Evidence read and purpose | Execution / consequence |
| --- | --- | --- |
| Sources/Engine/SQLiteMemory/SQLiteObservationRows.swift:304,305,306,307,308,309,501,506,509,516 | Decodes new_state and all four bounds into CaptureElement; refuses missing/nonfinite bounds. old_state is read only to reject it at :349,:443,:480. | Live shared codec. Removing stored bounds without adapting the codec breaks every sample read, even structural-only consumers. There is no active old_state payload reader: before/after state is new_state on separate phase samples. |
| Sources/Engine/Memory/Observation/CaptureSample.swift:56,62,141,215 | CaptureElement equality/hash and CaptureSample equality/fingerprint include every bound and state; distinguish a repeated sample from a conflicting offer. | Live value semantics used by storage retries and transfer. Drop loses exact sample-instance comparison; a changed geometry/state can no longer be diagnosed from old facts. |
| Sources/Engine/SQLiteMemory/SQLiteCaptureRepository.swift:43,44,48,64; Sources/Engine/SQLiteMemory/SQLiteOperationFactRepository.swift:306,307,311 | Reads a stored sample to compare an offered retry, returns full samples and reports conflict digests. | Live repository paths. Both idempotency implementations require an explicit new representation if non-command evidence is dropped. |
| Sources/Integration/AutomationRuntime/MemoryService.swift:1245,1246; Sources/Engine/Memory/Storage/CaptureStoring.swift:29 | Exposes the typed stored-sample reader. | Live API; no application/tool call site to this sample API was found in the audited roots. Its historic complete payload would cease to be available under drop. |
| Sources/Engine/SQLiteMemory/SQLiteSceneRepository.swift:48,76,376; Sources/Engine/Memory/Observation/SceneSkeleton.swift:77,117 | Decodes stored samples for scene association and creates structural scene elements. The skeleton uses roles, paths, captions and collections, ignoring bounds/state. | Live derivation. Structural behavior needs no per-instance geometry/state after the shared codec is adapted; source decoder currently still requires it. |
| Sources/Engine/SQLiteMemory/SQLiteBrainRelationRepository.swift:361,401,427; Sources/Engine/Memory/Brain/BrainRelation.swift:361,368; Sources/Engine/Memory/Observation/SceneElementKey.swift:64,103,120 | Loads before samples for pending scene association and resolves targets by role/label/structural identity. Does not use bounds or control state to decide relations. | Live relation/recovery paths. Keep roles/labels/paths and their ambiguity; geometry/state removal alone does not remove a policy input, after codec adaptation. |
| Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:565,579,652,838,884; Sources/Engine/Memory/Privacy/ValueMinimization.swift:223,264 | Reads, minimizes and transfers complete samples; checks element counts on both sides. Minimization preserves geometry/state. | Explicit archive import/export path, not merely a diagnostic. Drop loses transferable per-element phase evidence; count checks alone cannot certify its preservation. |
| Sources/Engine/SQLiteMemory/SQLiteAgentCallRepository.swift:414,415,447,448; Sources/Engine/Memory/Calls/AgentCallResults.swift:129,141; Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:695 | Reads the separate observed_state_before/after pair from memory_agent_actions for a stateFlip, exact call comparison and transfer. | Live call facts and archive transfer. All three options retain this typed effect pair: deleting other sample states must not delete the action's effect evidence. |
| Sources/Engine/SQLiteMemory/SQLiteBrainApplicationRepository.swift:557,574,583; Sources/Engine/Memory/Brain/BrainApplication.swift:688,695,699,721; Sources/Engine/SQLiteMemory/SQLiteArchiveTransfer.swift:312,313 | Reads typed detection/target bounds/state and effect arguments from memory_operation_arguments under a concluded brain_applications row; reconstructs the exact command for retries and transfer/reapplication. | Live command history/replay, separate from sample rows. All three options preserve this existing history and every durable command field. It cannot prove an unrecorded historical source command existed. |
| Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:167,185; Sources/Engine/Memory/Storage/BrainStoring.swift:107 | Reads optional bounds from brain_scene_elements for graph inspection. No caller of elements(ofScene:) was found in Sources/, Tools/ or BrausApp/; normal scene insertion at SQLiteSceneRepository.swift:349 omits bounds. | Available inspection API, not a current live per-sample consumer. A scene-level rectangle does not replace an element's historical sample rectangle/state. |
| Sources/Engine/SQLiteMemory/SQLiteBrainRows.swift:126,144,253,254; Sources/Engine/SQLiteMemory/SQLiteBrainGraphRepository.swift:274,275 | Reads derived anchor typical bounds and transition required/resulting state; BrainMatcher.swift:60 and SiblingGroupDetector.swift:33 consume projection geometry. | Live derived Brain data, not raw per-sample evidence. All three options retain it; it cannot restore discarded individual captures. |
| Tools/Engine/memory-probe/Probe.swift:264,268,272; Tools/Engine/Scripts/verify-memory-schema.py:419 | Probe reads a concluded command's detection count; the schema verifier checks action before/after effect state. The verifier's observation and scene-element rows are synthetic fixtures, not archive evidence readers. | Diagnostics/checks only. No other Tools/ reader of stored per-sample bounds/state was found. Existing concluded command/effect stores stay in all three options. |
| BrausApp/ (no persisted sample geometry/state reader) | ConversationObservedScreen.swift:37,46 draws scene bounds from live conversation output; it does not read memory_event_observations. Other UI bounds/frames likewise do not come from the archive. | Live display, outside the persisted-evidence dependency. Dropping archive samples does not remove these live overlays. |

### Question 4: owner alternatives and consequences

(a) Drop non-command per-sample bounds/state. Keep memory_brain_command_inputs and memory_brain_command_detections, including every current observe detection and the resolved record target, plus the existing typed action effects and concluded Brain commands. Shared memory_elements/memory_element_sets keep structural content. Omit the remaining per-sample element instances carrying memory_event_observations.bounds_x/y/width/height and new_state (and any unused old_state); do not silently keep a geometry-free row that the old codec would reject. This loses before/menu/after geometry and per-element state except the exact target/command evidence retained separately, historic raw sample reconstruction, full transfer payloads and exact instance retry comparisons. Scene structure and relation policy do not read those discarded fields, and the live UI reads RAM scenes. Existing codecs, retries and transfer must be adapted explicitly by DB2/SK4. The revised allocation is observations including command inputs = 3.80 KB/action; total = 9.80 KB/action.

(b) Keep all per-sample bounds/state. Retain the element child rows in memory_event_observations, with parent_observation_id linking each capture, phase/sample_ordinal and observation_id preserving sample identity/order, bounds_x/y/width/height REAL and new_state TEXT for each phase. old_state TEXT remains historical/unused by the active codec; retain any source evidence rather than inventing a before value. set_id still refers to the shared content; shared content cannot stand in for per-instance bounds. Also keep both new command-input tables: this stores role-bearing observe detections twice, once as sample elements in memory_event_observations and again as command detections in memory_brain_command_detections, including the same minimized label, bounds and state. Pixel-only detections currently have only the command copy. The 2.00 additional command-input allocation explicitly pays for that duplication. A command target is not a substitute for every before/after element. Exact sample comparison, decoder behavior and archive evidence remain possible. Giving no unmeasured saving to the retained source observations, plus the same new command allocation, gives observations = 13.33 KB/action; total = 19.33 KB/action. This exceeds DB1's 10 KB/action approval gate and requires reopening the form; owner approval and a DB2 measurement are necessary before activation.

(c) Keep per-sample bounds/state and derive observe detections from the sample. Preserve the sample element rows and fields of (b), but extend the sample contract to carry every detection in the original full scene order, including roleless pixel detections. It must also preserve SceneElement.isUnlabeled, which BrainDetection uses to turn a label into empty text; CaptureElement does not currently persist it and drops roleless detections (CaptureSample.swift:75,153; BrainDetection.swift:27). An explicit element_position INTEGER and is_unlabeled INTEGER flag, nullable for historical rows, are examples of the extra typed sample fields needed. These are proposed requirements for this alternative, not columns added by this review.

SK4 would build observe command detections from the immutable sample's element_kind, the same ValueMinimization-admitted label (empty when is_unlabeled), bounds_x/y/width/height and new_state, ordered by element_position, and would omit observe rows from memory_brain_command_detections. Headers still store the original request timestamp, window family, count and coverage. Record still stores its exact resolved target in memory_brain_command_detections; it must not guess that target from a matching label in a sample. No new instance-value text is required. DB2/SK4 must adapt the sample codec, keep roleless/unlabeled facts distinct from structural elements, and prove command equivalence before omitting any observe copy. Historical missing detections/flags remain absent/NULL; old structural samples cannot be treated as complete command inputs.

The explicit (c) allocation is retained samples 11.33 + command headers/record targets 0.50 + extra complete-sample facts 0.50 = 12.33 observations KB/action; total = 18.33 KB/action. It saves 1.00 versus (b) under the declared split assumptions only. It remains above the approval gate. The DDL is not switched to this alternative; choosing it would require an owner-approved sample contract and renewed field/round-trip tests.

The numbers are the explicit sensitivity scenarios in Space per action, not measured savings. Measure S, C, H and P before making a size claim. No evidence-retention or storage-sharing choice is made here.

## Deviations from the plan

Seven derived-data triggers retained instead of the five named in the plan: the integrator explicitly instructed retaining memory_recall_work_on_policy_update and memory_recall_entries_removed as well, because they validate nothing and only maintain derived Recall data, just like the five named triggers. Both keep their original names and integer-key operations; policy status updates and Recall entry deletion remain permitted.

The integrator subsequently required two immutable typed command-input child tables to satisfy DB1's pre-approval SK4 field-equivalence gate. These extend the named table list without changing the queue shape; historical input fields remain NULL, and no instance-value text column is added. Their additional space is included in (a)/(b); alternative (c) separately prices shared observe storage and would require another approved DDL change.

## Verification

Tests were written first. Before either proposed resource or document existed, all 28 Schema22ResourceTests compiled and ran, failing with missing-file errors (28 issues).
This Mac requires TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault for Swift commands. The restricted environment additionally requires module caches inside .build and SwiftPM nested sandbox disabled; these do not alter the task filesystem restrictions.
Validation of this resource uses isolated in-memory databases. The empty-database and populated historical-section tests enable foreign keys and CHECKs; vocabulary and transition cases disable foreign keys to isolate the tested contract. Trigger fixtures seed one row with CHECKs disabled before installing the triggers, so a rejected mutation must report a trigger error (1811) rather than a missing parent or CHECK failure. Digest boundary cases use valid CHECK-conforming rows. These tests do not prove migration or live application behavior.

- `xcrun swift test --disable-sandbox --filter 'Schema22ResourceTests/brainCommand'`: the two new command-input tests first failed against the absent tables (69 issues); both then passed after the DDL addition.
- Command-input review tests were extended first: the effect-ownership regression failed because a different existing event's effect was accepted; cardinality/nullability and the added valueChanged/ordered-item round trips already passed. The ownership test passed after the same-event CHECK was added. Items on valueChanged are explicitly rejected by the existing typed effect contract.
- `xcrun swift test --disable-sandbox --filter Schema22ResourceTests`: 34 tests passed, including command field/type/cardinality checks, exact storage round trips for state/value/list effects, same-event effect ownership, set-once outcomes, event-only argument text updates, app classification independent of title_bucket, and every immutable column.
- `xcrun swift test --disable-sandbox --filter SQLiteMemoryTests`: 370 tests in 60 suites passed. The earlier three review regressions were also confirmed red before their DDL fixes.
- `swift build --disable-sandbox --product braus`: passed.
- `make test SWIFT=swift SHELL=/bin/bash`: blocked before test execution by SwiftPM nested sandbox (`sandbox_apply: Operation not permitted`); no TIER_RESULT was produced. A shell-level forwarding function was not propagated by make. This baseline remains unverified here.
- Cursor correction: an added type assertion first failed on TEXT; cursor_route_id now references the integer procedure-version key. Final whitespace checks (including each new file), allowed-file audit, source-decision coverage, object counts and simple primary-key FK audit passed. The populated historical section fixture has no foreign-key violations.

The production resource and version remain unchanged. No commit or push was made. Independent full-diff review and Tommaso’s DDL approval remain human handoff requirements.
