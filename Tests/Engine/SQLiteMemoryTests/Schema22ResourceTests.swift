import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing

@testable import SQLiteMemory

/// Schema22ResourceTests fixes the proposed resource contract without opening a persistent archive.
@Suite("Schema 22 resource")
struct Schema22ResourceTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func resource(_ name: String = "memory-schema-22.sql") throws -> String {
        try String(
            contentsOf: root.appendingPathComponent("Sources/Engine/SQLiteMemory/Resources/\(name)"), encoding: .utf8)
    }

    private func document() throws -> String {
        try String(contentsOf: root.appendingPathComponent("Documentation/Engine/Schema22.md"), encoding: .utf8)
    }

    private func section(_ name: String) throws -> String {
        let sections = try resource().components(separatedBy: "-- section: ")
        return try #require(sections.first { $0.hasPrefix(name + "\n") }).dropFirst(name.count + 1).description
    }

    private func rows(_ heading: String) throws -> [[String]] {
        let text = try #require(document().components(separatedBy: "## \(heading)\n").dropFirst().first)
            .components(separatedBy: "\n## ")[0]
        return text.split(separator: "\n").filter { $0.hasPrefix("| `") }.map { line in
            line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
            }
        }
    }

    private func database(foreignKeys: Bool = false) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("PRAGMA foreign_keys = \(foreignKeys ? "ON" : "OFF")")
        try db.execute(resource())
        return db
    }

    private func names(_ db: SQLiteConnection, type: String = "table") throws -> [String] {
        try db.query(
            "SELECT name FROM sqlite_schema WHERE type = ? AND name NOT LIKE 'sqlite_%' ORDER BY name", [.text(type)]
        ) {
            try $0.text(0) ?? ""
        }
    }

    private func columns(_ db: SQLiteConnection, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" }
    }

    private func scalar(_ db: SQLiteConnection, _ sql: String) throws -> Int64 {
        try #require(db.query(sql) { $0.integer(0) }.first ?? nil)
    }

    private func rejects(_ db: SQLiteConnection, _ sql: String, code: Int32? = nil) {
        do {
            try db.execute(sql)
            Issue.record("Accepted invalid statement: \(sql)")
        } catch let error as SQLiteConnection.Failure {
            #expect(error.primary == 19, "\(sql): \(error)")
            if let code { #expect(error.extended == code, "\(sql): \(error)") }
        } catch {
            Issue.record("Unexpected error for \(sql): \(error)")
        }
    }

    /// Seeds one row before triggers, with checks disabled, to isolate trigger behavior from other constraints.
    private func triggerFixture(_ table: String, installTriggers: Bool = true) throws -> (SQLiteConnection, [String]) {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute(section("tables"))
        try db.execute("PRAGMA ignore_check_constraints = ON")
        let fields = try db.query("PRAGMA table_info(\(table))") {
            (try $0.text(1) ?? "", try $0.text(2) ?? "", $0.integer(3), $0.integer(5))
        }
        let required = fields.filter { $0.2 != 0 || $0.3 != 0 }
        let values = required.map { field in
            switch field.1 {
            case "INTEGER", "REAL": "1"
            case "BLOB": "zeroblob(16)"
            default: "'synthetic'"
            }
        }
        try db.execute(
            "INSERT INTO \(table) (\(required.map(\.0).joined(separator: ","))) VALUES (\(values.joined(separator: ",")))"
        )
        if installTriggers { try db.execute(section("triggers")) }
        return (db, fields.map(\.0))
    }

    /// Builds valid historical rows with foreign keys and CHECKs enabled, before freeze triggers exist.
    private func historicalTables() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute(section("tables"))
        try db.execute(
            """
            INSERT INTO brain_apps (app_id,bundle_id) VALUES (1,'test.synthetic');
            INSERT INTO brain_scenes (scene_id,scene_uuid,app_id,first_seen_ms,last_seen_ms)
            VALUES (1,'scene',1,0,0);
            INSERT INTO memory_events (event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status,app_id)
            VALUES (1,'event','app','test','action',0,'complete',1);
            INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status,app_id)
            VALUES (1,'click','planned',1);
            INSERT INTO memory_tasks (task_id,task_uuid,contract_version,source,source_stream_id,
                opened_at_ms,status,current_revision)
            VALUES (1,'task',1,'app','test',0,'open',1);
            INSERT INTO memory_task_revisions (task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
            VALUES (1,1,1,0,'opened','Save');
            INSERT INTO memory_task_occurrences (task_occurrence_id,task_occurrence_uuid,started_at_ms,status)
            VALUES (1,'attempt',0,'in_progress');
            INSERT INTO memory_task_attempts (task_occurrence_id,task_id,ordinal,source,source_stream_id,
                opened_at_ms,opened_at_revision,task_revision_id)
            VALUES (1,1,1,'app','test',0,1,1);
            INSERT INTO memory_procedure_candidates (candidate_id,task_id,task_occurrence_id,policy_version,
                structure_digest,built_at_ms,step_count,block_count)
            VALUES (1,1,1,'test',zeroblob(16),0,1,1);
            INSERT INTO memory_procedure_interpretations (interpretation_id,candidate_id,revision,contract_version,
                payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
            VALUES (1,1,1,1,zeroblob(16),'app','test',1,'running',0);
            INSERT INTO memory_routes (route_id,route_uuid,name,status,created_at_ms)
            VALUES (1,'version','Save','draft',0);
            INSERT INTO memory_procedure_versions (route_id,interpretation_id,candidate_id,task_id,
                task_occurrence_id,contract_version,built_at_ms)
            VALUES (1,1,1,1,1,1,0);
            INSERT INTO brain_anchors (anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
            VALUES (1,1,0,'button','Save',0,0);
            INSERT INTO brain_anchor_aliases VALUES (1,'Save',0);
            INSERT INTO brain_anchor_states VALUES (1,'on',1);
            INSERT INTO brain_groups (group_id,app_id,insertion_order,axis,shared_kind,last_seen_ms)
            VALUES (1,1,0,'row','button',0);
            INSERT INTO brain_group_members VALUES (1,1,1,0);
            INSERT INTO brain_transitions (transition_id,app_id,insertion_order,from_scene_id,trigger_kind,
                to_scene_id,effect_kind,status,first_seen_ms,last_seen_ms)
            VALUES (1,1,0,1,'click',1,'navigation','candidate',0,0);
            INSERT INTO brain_transition_menu_items VALUES (1,0,'Save');
            INSERT INTO brain_anchor_label_keys (label_key_id,anchor_id,app_id,label_key)
            VALUES (1,1,1,'save');
            INSERT INTO brain_applications (application_id,app_id,event_id,operation,contract_version,
                algorithm_version,requested_at_ms,effective_at_ms,outcome,anchor_id)
            VALUES (1,1,1,'set_name',1,'test',0,0,'named',1);
            INSERT INTO brain_relation_applications (call_event_id,app_id,policy_version,outcome,reason,applied_at_ms)
            VALUES (1,1,'test','excluded','not_an_operation',0);
            INSERT INTO memory_variant_prefixes VALUES (1,'verified',0,NULL,0);
            """
        )
        return db
    }

    private func insert(_ db: SQLiteConnection, _ table: String, _ values: [String: String]) throws {
        let keys = values.keys.sorted()
        try db.execute(
            "INSERT INTO \(table) (\(keys.joined(separator: ","))) VALUES (\(keys.map { values[$0]! }.joined(separator: ",")))"
        )
    }

    private var task: [String: String] {
        [
            "task_id": "1", "task_uuid": "'task'", "contract_version": "1", "source": "'app'",
            "source_stream_id": "'test'", "opened_at_ms": "0", "status": "'open'", "current_revision": "1",
        ]
    }

    private var action: [String: String] {
        [
            "event_id": "1", "tool_kind": "'synthetic.capability'", "execution_status": "'completed'",
            "gesture": "'sent'", "effect": "'confirmed'", "recovery": "'continue'",
            "outcome_origin": "'recorded'", "learnable": "1",
        ]
    }

    private var personCommand: [String: String] {
        [
            "command_id": "1", "segment_id": "1", "position": "0", "kind": "'click'", "element_key_id": "1",
            "coverage": "'complete'", "cause": "'rule'", "arrival_kind": "'expanded'",
        ]
    }

    /// SK4 reads observe/record commands, including fields absent from structural CaptureElement rows.
    @Test
    func brainCommandFieldsHaveTypedStorage() throws {
        let db = try database()
        let input = "memory_brain_command_inputs"
        let detection = "memory_brain_command_detections"
        var fields: [String: (String, String)] = [
            "detection_count": (input, "detection_count"), "window": (input, "window"),
            "capture_completeness": (input, "capture_completeness"), "capture_surface": (input, "capture_surface"),
            "representation": (input, "representation"), "spatial_coverage": (input, "spatial_coverage"),
            "verb": (input, "verb"),
            "effect_kind": ("memory_agent_actions", "observed_effect_kind"),
            "effect_text": ("memory_agent_actions", "observed_effect_text"),
            "effect_required_state": ("memory_agent_actions", "observed_state_before"),
            "effect_resulting_state": ("memory_agent_actions", "observed_state_after"),
            "effect_label": ("memory_agent_actions", "observed_effect_label"),
            "effect_value": ("memory_agent_actions", "observed_effect_value"),
            "effect_item": ("memory_agent_action_effect_labels", "label"),
        ]
        for prefix in ["detection", "target"] {
            for suffix in ["kind", "label", "x", "y", "width", "height", "state"] {
                fields["\(prefix)_\(suffix)"] = (detection, suffix)
            }
        }
        func type(_ table: String, _ column: String) throws -> String? {
            try db.query("SELECT type FROM pragma_table_info(?) WHERE name = ?", [.text(table), .text(column)]) {
                try $0.text(0)
            }.first ?? nil
        }
        // Derive the complete field list from the actual command contract, rather than copying its list.
        for version in BrainApplicationContract.supportedVersions {
            for operation in [BrainOperation.observe, .record] {
                for field in BrainApplicationContract.arguments(of: operation, version: version) {
                    let location = try #require(fields[field.name], "Unaccounted command field: \(field.name)")
                    #expect(try type(location.0, location.1) == field.kind.rawValue.uppercased(), "\(field.name)")
                    let required = try scalar(
                        db, "SELECT \"notnull\" FROM pragma_table_info('\(location.0)') WHERE name = '\(location.1)'")
                    switch field.cardinality {
                    case .one where required == 0:
                        // Shared headers require these fields only for the operation/version that admits them.
                        #expect(
                            ["verb", "capture_completeness", "capture_surface", "representation", "spatial_coverage"]
                                .contains(location.1), "\(field.name) must be NOT NULL")
                        let fixture = try database()
                        var values: [String: String] = [
                            "command_input_id": "1", "event_id": "1", "operation": "'\(operation.rawValue)'",
                            "requested_at_ms": "17", "contract_version": "\(version)", "detection_count": "1",
                        ]
                        if operation == .observe {
                            values["sample_observation_id"] = "1"
                            if version > 1 {
                                values["capture_completeness"] = "'complete'"
                                values["capture_surface"] = "'window'"
                                values["representation"] = "'desktop'"
                                values["spatial_coverage"] = version == 2 ? "'legacy_window'" : "'visible'"
                            }
                        } else {
                            values["contract_version"] = "1"
                            values["verb"] = "'click'"
                        }
                        try insert(fixture, input, values)
                        values["command_input_id"] = "2"
                        values["event_id"] = "2"
                        if operation == .observe { values["sample_observation_id"] = "2" }
                        values[location.1] = "NULL"
                        rejects(fixture, statement(input, values), code: 275)
                    case .one, .perDetection, .list:
                        #expect(required == 1, "\(field.name) must be NOT NULL within each stored row")
                    case .optional, .optionalPerDetection:
                        #expect(required == 0, "\(field.name) must preserve absence")
                    }
                }
            }
        }
        for (table, column, expected) in [
            (input, "command_input_id", "INTEGER"), (input, "event_id", "INTEGER"),
            (input, "sample_observation_id", "INTEGER"), (input, "operation", "TEXT"),
            (input, "requested_at_ms", "INTEGER"), (input, "contract_version", "INTEGER"),
            (input, "effect_event_id", "INTEGER"), (detection, "command_input_id", "INTEGER"),
            (detection, "position", "INTEGER"), ("memory_events", "event_uuid", "TEXT"),
            ("memory_events", "app_id", "INTEGER"), ("brain_apps", "bundle_id", "TEXT"),
            ("memory_event_observations", "phase", "TEXT"), ("memory_event_observations", "sample_ordinal", "INTEGER"),
            ("memory_consolidation_queue", "seq", "INTEGER"), ("memory_consolidation_queue", "job_kind", "TEXT"),
            ("memory_consolidation_queue", "ref_id", "INTEGER"),
            ("memory_consolidation_queue", "enqueued_at_ms", "INTEGER"),
        ] {
            #expect(try type(table, column) == expected, "\(table).\(column)")
        }
        for table in [input, detection] {
            #expect(try scalar(db, "SELECT strict FROM pragma_table_list WHERE name = '\(table)'") == 1)
            #expect(try !columns(db, table).contains("value"))
            #expect(try !columns(db, table).contains("text_value"))
        }
    }

    @Test
    func brainCommandEffectBelongsToItsEvent() throws {
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        try db.execute(
            """
            INSERT INTO memory_events (event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status,app_id)
            VALUES (2,'other-event','app','test','action',0,'complete',1);
            INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status,app_id)
            VALUES (2,'click','completed',1);
            """
        )
        var values: [String: String] = [
            "command_input_id": "1", "event_id": "1", "operation": "'record'", "requested_at_ms": "19",
            "contract_version": "1", "detection_count": "1", "verb": "'click'", "effect_event_id": "2",
        ]
        // Both events and effects exist, so a mismatched owner must fail a CHECK, not a foreign key.
        rejects(db, statement("memory_brain_command_inputs", values), code: 275)
        values["effect_event_id"] = "1"
        try insert(db, "memory_brain_command_inputs", values)
        values["command_input_id"] = "2"
        values["event_id"] = "2"
        values["effect_event_id"] = "NULL"
        try insert(db, "memory_brain_command_inputs", values)
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    /// Exercises the proposed typed storage, not the future SK4 producer or its runtime reconstruction.
    @Test
    func brainCommandInputsRoundTrip() throws {
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        #expect(
            try scalar(
                db,
                "SELECT count(*) FROM memory_events e LEFT JOIN memory_brain_command_inputs i ON i.event_id = e.event_id WHERE i.requested_at_ms IS NULL"
            ) == 1)
        try db.execute(
            """
            UPDATE memory_agent_actions SET execution_status = 'completed', observed_effect_kind = 'stateFlip',
                observed_state_before = 'off', observed_state_after = 'on' WHERE event_id = 1;
            INSERT INTO memory_events (event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status,app_id)
            VALUES (2,'value-event','app','test','action',0,'complete',1),
                   (3,'items-event','app','test','action',0,'complete',1);
            INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status,app_id,
                observed_effect_kind,observed_effect_label,observed_effect_value)
            VALUES (2,'click','completed',1,'valueChanged','Color','Blue'),
                   (3,'click','completed',1,'elementsAppeared',NULL,NULL);
            INSERT INTO memory_agent_action_effect_labels (event_id,position,label)
            VALUES (3,0,'Zulu'),(3,1,'Alpha');
            INSERT INTO memory_event_observations (observation_id,event_id,phase,observation_kind,status)
            VALUES (1,1,'current','capture','complete');
            INSERT INTO memory_brain_command_inputs
                (command_input_id,event_id,sample_observation_id,operation,requested_at_ms,contract_version,
                 detection_count,window,capture_completeness,capture_surface,representation,spatial_coverage)
            VALUES (1,1,1,'observe',17,3,2,'Editor','complete','window','desktop','visible');
            INSERT INTO memory_brain_command_inputs
                (command_input_id,event_id,operation,requested_at_ms,contract_version,detection_count,verb,effect_event_id)
            VALUES (2,1,'record',19,1,1,'click',1),
                   (3,2,'record',23,1,1,'click',2),
                   (4,3,'record',29,1,1,'click',3);
            INSERT INTO memory_brain_command_detections (command_input_id,position,kind,label,x,y,width,height,state)
            VALUES (1,0,'icon','',0.125,0.25,0.5,0.75,NULL),
                   (1,1,'control','Save',0.25,0.5,0.125,0.25,'off'),
                   (2,0,'control','Save',0.375,0.5,0.25,0.125,'on'),
                   (3,0,'control','Save',0.375,0.5,0.25,0.125,'on'),
                   (4,0,'control','Save',0.375,0.5,0.25,0.125,'on');
            """
        )
        let pixel = BrainDetection(
            kind: .icon, label: "", bounds: NormalizedRect(x: 0.125, y: 0.25, width: 0.5, height: 0.75))
        let control = BrainDetection(
            kind: .control, label: "Save", bounds: NormalizedRect(x: 0.25, y: 0.5, width: 0.125, height: 0.25),
            state: .off)
        let target = BrainDetection(
            kind: .control, label: "Save", bounds: NormalizedRect(x: 0.375, y: 0.5, width: 0.25, height: 0.125),
            state: .on)
        let live = [
            try BrainApplicationCommand(
                key: .observe(CaptureSampleKey(eventID: "event", phase: .current)),
                bundleID: "test.synthetic", requestedAtMS: 17,
                input: .observe(window: "Editor", detections: [pixel, control]),
                coverage: BrainObservationCoverage(completeness: .complete, surface: .window, representation: .desktop)),
            try BrainApplicationCommand(
                key: .record(eventID: "event"), bundleID: "test.synthetic", requestedAtMS: 19,
                input: .record(
                    verb: .click, target: target,
                    effect: try TransitionEffectRecord(
                        kind: "stateFlip", text: nil, requiredState: "off", resultingState: "on", label: nil,
                        value: nil, items: []))),
            try BrainApplicationCommand(
                key: .record(eventID: "value-event"), bundleID: "test.synthetic", requestedAtMS: 23,
                input: .record(
                    verb: .click, target: target,
                    effect: try TransitionEffectRecord(
                        kind: "valueChanged", text: nil, requiredState: nil,
                        resultingState: nil, label: "Color", value: "Blue", items: []))),
            try BrainApplicationCommand(
                key: .record(eventID: "items-event"), bundleID: "test.synthetic", requestedAtMS: 29,
                input: .record(
                    verb: .click, target: target,
                    effect: try TransitionEffectRecord(
                        kind: "elementsAppeared", text: nil, requiredState: nil,
                        resultingState: nil, label: nil, value: nil, items: ["Zulu", "Alpha"]))),
        ]
        #expect(throws: BrainProjectionError.self) {
            try TransitionEffectRecord(
                kind: "valueChanged", text: nil, requiredState: nil,
                resultingState: nil, label: "Color", value: "Blue", items: ["Unexpected"])
        }
        for (index, offered) in live.enumerated() {
            let id = Int64(index + 1)
            let found = try db.query(
                "SELECT kind,label,x,y,width,height,state FROM memory_brain_command_detections WHERE command_input_id = ? ORDER BY position",
                [.integer(id)]
            ) { row in
                BrainDetection(
                    kind: try #require(ElementKind(rawValue: row.text(0) ?? "")), label: try row.text(1) ?? "",
                    bounds: NormalizedRect(
                        x: row.real(2) ?? 0, y: row.real(3) ?? 0, width: row.real(4) ?? 0, height: row.real(5) ?? 0),
                    state: try row.text(6).flatMap(ControlState.init(rawValue:)))
            }
            let rebuiltRows = try db.query(
                """
                SELECT e.event_uuid,a.bundle_id,i.operation,i.requested_at_ms,i.contract_version,i.window,
                       i.capture_completeness,i.capture_surface,i.representation,i.spatial_coverage,i.verb,
                       o.phase,o.sample_ordinal,i.detection_count,i.effect_event_id,
                       f.observed_effect_kind,f.observed_state_before,f.observed_state_after,
                       f.observed_effect_text,f.observed_effect_label,f.observed_effect_value
                FROM memory_brain_command_inputs i JOIN memory_events e ON e.event_id = i.event_id
                JOIN brain_apps a ON a.app_id = e.app_id
                LEFT JOIN memory_event_observations o ON o.observation_id = i.sample_observation_id
                LEFT JOIN memory_agent_actions f ON f.event_id = i.effect_event_id
                WHERE i.command_input_id = ?
                """, [.integer(id)]
            ) { row in
                let event = try row.text(0) ?? ""
                #expect(row.integer(13) == Int64(found.count))
                let key: BrainApplicationKey
                let argument: BrainApplicationCommand.Input
                var coverage: BrainObservationCoverage?
                if try row.text(2) == "observe" {
                    key = .observe(
                        CaptureSampleKey(
                            eventID: event, phase: try #require(CapturePhase(rawValue: row.text(11) ?? "")),
                            ordinal: Int(row.integer(12) ?? 0)))
                    argument = .observe(window: try row.text(5), detections: found)
                    coverage = BrainObservationCoverage(
                        completeness: try #require(CaptureQuality.Completeness(rawValue: row.text(6) ?? "")),
                        surface: try #require(CaptureSurface(rawValue: row.text(7) ?? "")),
                        representation: try #require(
                            BrainObservationCoverage.Representation(rawValue: row.text(8) ?? "")),
                        spatialScope: try #require(BrainObservationCoverage.SpatialScope(rawValue: row.text(9) ?? "")))
                } else {
                    key = .record(eventID: event)
                    let items = try db.query(
                        "SELECT label FROM memory_agent_action_effect_labels WHERE event_id = ? ORDER BY position",
                        [row.integer(14).map(SQLiteValue.integer) ?? .null]
                    ) { try $0.text(0) ?? "" }
                    let effect =
                        row.isNull(14)
                        ? nil
                        : try TransitionEffectRecord(
                            kind: row.text(15) ?? "", text: row.text(18),
                            requiredState: row.text(16), resultingState: row.text(17),
                            label: row.text(19), value: row.text(20), items: items
                        )
                    argument = .record(
                        verb: try #require(ActionVerb(rawValue: row.text(10) ?? "")), target: try #require(found.first),
                        effect: effect)
                }
                let command = try BrainApplicationCommand(
                    key: key, bundleID: row.text(1) ?? "", requestedAtMS: row.integer(3) ?? 0, input: argument,
                    coverage: coverage)
                #expect(row.integer(4) == Int64(command.contractVersion))
                return command
            }
            let rebuilt = try #require(rebuiltRows.first)
            #expect(rebuilt.hasSameInput(as: offered))
        }
        for table in ["memory_brain_command_inputs", "memory_brain_command_detections"] {
            for column in try columns(db, table) {
                rejects(db, "UPDATE \(table) SET \(column) = \(column)", code: 1811)
            }
            rejects(db, "DELETE FROM \(table)", code: 1811)
        }
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func ddlLoadsInEmptyDatabase() throws {
        let db = try database(foreignKeys: true)
        #expect(try scalar(db, "PRAGMA foreign_keys") == 1)
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func everyTableStrictNoJSON() throws {
        let db = try database()
        let tables = try names(db)
        #expect(tables.count >= 121)
        for table in tables {
            let strict = try db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)]) {
                $0.integer(0)
            }
            #expect(strict == [1], "\(table)")
            #expect(try columns(db, table).allSatisfy { !$0.lowercased().contains("json") })
        }
    }

    @Test
    func noEncodedListColumns() throws {
        let db = try database()
        for table in try names(db) {
            #expect(try !columns(db, table).contains("labels"), "\(table).labels")
        }
        for row in try rows("Table inventory") {
            let description = row.joined(separator: " ").lowercased()
            #expect(!description.contains("json"), "\(row[0]) documents encoded storage")
            #expect(!description.contains("encoded list"), "\(row[0]) documents encoded storage")
        }
    }

    private func insertPhaseFamily(_ db: SQLiteConnection) throws {
        try db.execute(
            """
            INSERT INTO memory_phase_families (family_id,app_id,kind,method_text,method_digest,
                masked_digest,has_parameter,length,label,members,procedures,first_member_seq,
                first_attempt_id,recorded_at_ms)
            VALUES (1,1,'step','click',zeroblob(16),zeroblob(16),0,1,'Save',4,2,0,1,0)
            """
        )
    }

    @Test
    func phaseFamilyLabelsAreRows() throws {
        let db = try historicalTables()
        try insertPhaseFamily(db)
        try db.execute(
            """
            INSERT INTO memory_phase_family_labels (family_id,position,label,count)
            VALUES (1,1,'Store',1),(1,0,'Save',3)
            """
        )
        let labels = try db.query(
            "SELECT label,count FROM memory_phase_family_labels WHERE family_id = 1 ORDER BY position"
        ) { (try $0.text(0), $0.integer(1)) }
        #expect(labels.map { $0.0 } == ["Save", "Store"])
        #expect(labels.map { $0.1 } == [3, 1])
        for values in ["(1,2,'Save',1)", "(1,0,'Other',1)", "(1,-1,'Other',1)", "(1,2,'Other',0)"] {
            rejects(db, "INSERT INTO memory_phase_family_labels VALUES \(values)")
        }
    }

    @Test
    func attemptLabelsFollowTheirAttempt() throws {
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        try insertPhaseFamily(db)
        try db.execute("INSERT INTO memory_phase_family_attempts VALUES (1,1,4,2)")
        try db.execute(
            """
            INSERT INTO memory_phase_family_labels VALUES (1,0,'Save',3);
            INSERT INTO memory_phase_family_attempt_labels VALUES (1,1,1,'Store',1),(1,1,0,'Save',3);
            """
        )
        let labels = try db.query(
            """
            SELECT label,count FROM memory_phase_family_attempt_labels
            WHERE family_id = 1 AND task_occurrence_id = 1 ORDER BY position
            """
        ) { (try $0.text(0), $0.integer(1)) }
        #expect(labels.map { $0.0 } == ["Save", "Store"])
        #expect(labels.map { $0.1 } == [3, 1])
        for values in [
            "(1,1,2,'Save',1)", "(1,1,0,'Other',1)", "(1,1,-1,'Other',1)",
            "(1,1,2,'Other',0)", "(1,2,0,'Other',1)",
        ] {
            rejects(db, "INSERT INTO memory_phase_family_attempt_labels VALUES \(values)")
        }
        try db.execute("DELETE FROM memory_phase_family_attempts WHERE family_id = 1 AND task_occurrence_id = 1")
        #expect(try scalar(db, "SELECT count(*) FROM memory_phase_family_attempt_labels") == 0)
        #expect(try scalar(db, "SELECT count(*) FROM memory_phase_family_labels") == 1)
        try db.execute(
            """
            INSERT INTO memory_phase_family_attempts VALUES (1,1,4,2);
            INSERT INTO memory_phase_family_attempt_labels VALUES (1,1,0,'Save',3),(1,1,1,'Store',1);
            DELETE FROM memory_phase_families WHERE family_id = 1;
            """
        )
        for table in ["memory_phase_family_labels", "memory_phase_family_attempts", "memory_phase_family_attempt_labels"] {
            #expect(try scalar(db, "SELECT count(*) FROM \(table)") == 0)
        }
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func requiredTablesAndColumns() throws {
        let db = try database()
        let required = try rows("Required columns")
        #expect(!required.isEmpty)
        #expect(Set(required.map { $0[0] }) == Set(try names(db)))
        for row in required {
            #expect(try columns(db, row[0]).contains(row[1]), "\(row[0]).\(row[1])")
        }
        #expect(
            try db.query(
                "SELECT type FROM pragma_table_info('memory_recall_generations') WHERE name = 'cursor_route_id'"
            ) { try $0.text(0) } == ["INTEGER"])
        for table in try names(db) {
            let foreignKeys = try db.query("PRAGMA foreign_key_list(\(table))") {
                [String($0.integer(1) ?? -1), try $0.text(2) ?? "", try $0.text(3) ?? "",
                 try $0.text(4) ?? "", try $0.text(6) ?? ""]
            }
            if table == "memory_phase_family_attempt_labels" {
                #expect(foreignKeys == [
                    ["0", "memory_phase_family_attempts", "family_id", "family_id", "CASCADE"],
                    ["1", "memory_phase_family_attempts", "task_occurrence_id", "task_occurrence_id", "CASCADE"],
                ])
            } else {
                #expect(foreignKeys.allSatisfy { $0[0] == "0" }, "Composite foreign key in \(table)")
            }
        }
    }

    @Test
    func partStatesHaveNoOff() throws {
        let db = try database()
        let values = [
            "part_id": "1", "sequence": "1", "state": "'usable'", "reason_code": "'qualified'",
            "recorded_by": "'braus'", "recorded_at_ms": "0",
        ]
        for (key, value) in [("state", "'off'"), ("reason_code", "'arbitrary'"), ("recorded_by", "'arbitrary'")] {
            var invalid = values
            invalid[key] = value
            rejects(db, statement("memory_part_states", invalid))
        }
        try insert(db, "memory_part_states", values)
    }

    private func statement(_ table: String, _ values: [String: String]) -> String {
        let keys = values.keys.sorted()
        return
            "INSERT INTO \(table) (\(keys.joined(separator: ","))) VALUES (\(keys.map { values[$0]! }.joined(separator: ",")))"
    }

    @Test
    func outcomeColumnsOnly() throws {
        let db = try database()
        for table in ["memory_agent_actions", "memory_call_effects"] {
            #expect(try !columns(db, table).contains("status"))
            let sql = try #require(
                db.query("SELECT sql FROM sqlite_schema WHERE name = ?", [.text(table)]) { try $0.text(0) }.first!)
            #expect(!sql.contains("found_acted"))
            #expect(!sql.contains("acted_unverified"))
        }
        for field in ["gesture", "effect", "effect_reason", "recovery", "recovery_reason"] {
            var values = action
            values[field] = "'invalid'"
            rejects(db, statement("memory_agent_actions", values))
        }
        var invalid = action
        invalid["effect_reason"] = "'not_readable'"
        rejects(db, statement("memory_agent_actions", invalid))
        invalid = action
        invalid["effect"] = "'unknown'"
        rejects(db, statement("memory_agent_actions", invalid))
        try insert(db, "memory_agent_actions", action)
    }

    @Test
    func outcomeColumnsSetOnce() throws {
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        try db.execute("UPDATE memory_agent_actions SET execution_status = 'started', started_at_ms = 1")
        try db.execute(
            """
            UPDATE memory_agent_actions
            SET execution_status = 'completed', completed_at_ms = 2, duration_ms = 1,
                gesture = 'sent', effect = 'unknown', effect_reason = 'not_readable',
                recovery = 'change_target', recovery_reason = 'not_found', outcome_origin = 'recorded', learnable = 0
            """
        )
        let fields = [
            "gesture", "effect", "effect_reason", "recovery", "recovery_reason", "outcome_origin", "learnable",
        ]
        let values = ["'uncertain'", "'absent'", "'not_watched'", "'postpone'", "'ambiguous'", "'converted'", "1"]
        for (field, value) in zip(fields, values) {
            rejects(db, "UPDATE memory_agent_actions SET \(field) = \(field)", code: 1811)
            rejects(db, "UPDATE memory_agent_actions SET \(field) = \(value)", code: 1811)
            rejects(db, "UPDATE memory_agent_actions SET \(field) = NULL", code: 1811)
        }
        try db.execute("UPDATE memory_agent_actions SET result_message = 'Finished'")
        #expect(
            try scalar(
                db,
                "SELECT gesture = 'sent' AND effect = 'unknown' AND effect_reason = 'not_readable' AND recovery = 'change_target' AND recovery_reason = 'not_found' AND outcome_origin = 'recorded' AND learnable = 0 FROM memory_agent_actions"
            ) == 1)

        let inserted = try database()
        var recorded = action
        recorded["effect"] = "'unknown'"
        recorded["effect_reason"] = "'not_readable'"
        recorded["recovery"] = "'change_target'"
        recorded["recovery_reason"] = "'not_found'"
        try insert(inserted, "memory_agent_actions", recorded)
        for field in fields {
            rejects(inserted, "UPDATE memory_agent_actions SET \(field) = \(field)", code: 1811)
        }
    }

    @Test
    func literalArgumentsBelongToTheirOwner() throws {
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        try db.execute(
            """
            INSERT INTO memory_route_steps (step_id,route_id,position,step_kind,goal_text,app_id)
            VALUES (1,1,0,'goal','Save',1);
            INSERT INTO memory_step_operations (operation_id,route_id,step_id,position,tool_kind,app_id)
            VALUES (1,1,1,0,'click',1);
            INSERT INTO memory_operation_arguments (argument_id,operation_id,route_id,app_id,argument_name,value_kind,text_value)
            VALUES (1,1,1,1,'label','text','Save');
            INSERT INTO memory_operation_arguments (argument_id,event_id,app_id,argument_name,value_kind,text_value)
            VALUES (2,1,1,'label','text','Save');
            INSERT INTO memory_operation_arguments (argument_id,brain_application_id,app_id,argument_name,value_kind,text_value)
            VALUES (3,1,1,'label','text','Save');
            """
        )
        rejects(db, "UPDATE memory_operation_arguments SET text_value = 'Changed' WHERE argument_id = 1", code: 1811)
        rejects(db, "UPDATE memory_operation_arguments SET text_value = 'Changed' WHERE argument_id = 3", code: 1811)
        try db.execute("UPDATE memory_operation_arguments SET text_value = 'withheld' WHERE argument_id = 2")
        #expect(
            try db.query("SELECT text_value FROM memory_operation_arguments ORDER BY argument_id") { try $0.text(0) }
                == ["Save", "withheld", "Save"])
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func appScenesNeedNoTitleBucket() throws {
        for bucket in ["NULL", "'#app'", "'Historical hint'"] {
            let db = try database(foreignKeys: true)
            try db.execute("INSERT INTO brain_apps (app_id,bundle_id) VALUES (1,'test.synthetic')")
            try db.execute(
                "INSERT INTO brain_scenes (scene_id,scene_uuid,app_id,title_bucket,scene_kind,first_seen_ms,last_seen_ms,observation_count) VALUES (1,'scope',1,\(bucket),'app',0,0,0)"
            )
            try db.execute(
                "INSERT INTO brain_scenes (scene_id,scene_uuid,app_id,title_bucket,scene_kind,first_seen_ms,last_seen_ms) VALUES (2,'window',1,'#app','window',0,0)"
            )
            #expect(try scalar(db, "SELECT count(*) FROM brain_scenes WHERE scene_kind = 'app'") == 1)
            #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
        }
        for extra in ["structural_key", "window_title_pattern", "observation_count"] {
            let db = try database(foreignKeys: true)
            try db.execute("INSERT INTO brain_apps (app_id,bundle_id) VALUES (1,'test.synthetic')")
            var row = [
                "scene_uuid": "'scope'", "app_id": "1", "scene_kind": "'app'", "first_seen_ms": "0",
                "last_seen_ms": "0", "observation_count": "0",
            ]
            row[extra] = extra == "observation_count" ? "1" : "'structure'"
            rejects(db, statement("brain_scenes", row), code: 275)
        }
    }

    @Test
    func noPersonFacts() throws {
        let db = try database()
        #expect(
            try names(db).allSatisfy {
                $0 != "memory_learned_facts" && !$0.hasPrefix("person_") && !$0.hasSuffix("_overrides")
            })
    }

    @Test
    func personStepNeedsSegment() throws {
        let db = try database()
        let base = [
            "candidate_id": "1", "position": "0", "block_index": "0", "actor": "'person'", "step_kind": "'person_only'",
        ]
        rejects(db, statement("memory_candidate_steps", base))
        var agent = base
        agent["actor"] = "'agent'"
        rejects(db, statement("memory_candidate_steps", agent))
    }

    @Test
    func frozenTablesRefuseInsert() throws {
        let frozen = try rows("Frozen tables")
        #expect(!frozen.isEmpty)
        let db = try historicalTables()
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        for row in frozen {
            #expect(try scalar(db, "SELECT count(*) FROM \(row[0])") == 1)
            rejects(db, "INSERT INTO \(row[0]) SELECT * FROM \(row[0])", code: 1811)
        }
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func historyImmutable() throws {
        let mutable = Dictionary(uniqueKeysWithValues: try rows("Mutable tables").map { ($0[0], $0) })
        for table in try names(database()) {
            let (db, fields) = try triggerFixture(table)
            if let rule = mutable[table] {
                let allowed = rule[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for field in fields where rule[1] != "*" && !allowed.contains(field) {
                    rejects(db, "UPDATE \(table) SET \(field) = \(field)", code: 1811)
                }
                if rule[1] == "*" {
                    try db.execute("UPDATE \(table) SET \(fields[0]) = \(fields[0])")
                } else if ![
                    "memory_part_qualifications", "memory_recall_calibration", "memory_tasks", "memory_task_attempts",
                    "memory_operation_arguments",
                ].contains(table) {
                    for field in allowed where field != "none" {
                        try db.execute("UPDATE \(table) SET \(field) = \(field)")
                    }
                }
                if rule[2] == "yes" {
                    try db.execute("DELETE FROM \(table)")
                } else {
                    rejects(db, "DELETE FROM \(table)", code: 1811)
                }
            } else {
                for field in fields {
                    rejects(db, "UPDATE \(table) SET \(field) = \(field)", code: 1811)
                }
                rejects(db, "DELETE FROM \(table)", code: 1811)
            }
        }
        let db = try database()
        try db.execute(
            "INSERT INTO memory_recall_calibration (query_id, need_position, part_id, rank, score, threshold, delivered) VALUES (1,0,1,0,0.8,0.5,1)"
        )
        try db.execute("UPDATE memory_recall_calibration SET used = 1")
        rejects(db, "UPDATE memory_recall_calibration SET used = 0", code: 1811)
    }

    @Test
    func triggerDestinies() throws {
        let old = try SQLiteConnection(path: ":memory:")
        try old.execute(resource("brain-living-memory-schema.sql"))
        let declared = Dictionary(uniqueKeysWithValues: try rows("Trigger destinies").map { ($0[0], $0) })
        #expect(declared.count == 217)
        let current = Set(try names(database(), type: "trigger"))
        for name in try names(old, type: "trigger") {
            let row = try #require(declared[name], "Missing destiny: \(name)")
            #expect(["retained", "code"].contains(row[1]))
            #expect(row[2] != "")
            if row[1] == "retained" {
                #expect(current.contains(name), "\(name)")
            } else {
                #expect(!current.contains(name), "\(name)")
            }
        }
    }

    @Test
    func postponedMovesBack() throws {
        let db = try database()
        try insert(db, "memory_tasks", task)
        try db.execute("UPDATE memory_tasks SET status = 'postponed'")
        rejects(db, "UPDATE memory_tasks SET closed_at_ms = 2")
        try db.execute("UPDATE memory_tasks SET status = 'open', current_revision = 2")
        try db.execute("UPDATE memory_tasks SET status = 'completed', closed_at_ms = 3")
        for status in ["open", "postponed", "failed", "abandoned"] {
            rejects(db, "UPDATE memory_tasks SET status = '\(status)'", code: 1811)
        }
        rejects(db, "UPDATE memory_tasks SET current_revision = 1", code: 1811)
    }

    @Test
    func elementKeysOnce() throws {
        let db = try database()
        try db.execute(
            "INSERT INTO brain_element_keys (element_key_id, app_id, key_text, digest, first_seen_ms) VALUES (1,1,'AXButton|Save',zeroblob(16),0)"
        )
        rejects(
            db,
            "INSERT INTO brain_element_keys (app_id,key_text,digest,first_seen_ms) VALUES (1,'AXButton|Save',zeroblob(16),0)"
        )
        try db.execute(
            "INSERT INTO brain_element_keys (element_key_id,app_id,key_text,digest,first_seen_ms,replaced_by_id) VALUES (2,1,'AXButton|Save',zeroblob(16),0,1)"
        )
        try insert(db, "memory_person_commands", personCommand)
        try db.execute(
            "INSERT INTO memory_step_signatures (app_id,signature_digest,verb,element_key_id,arguments_shape) VALUES (1,zeroblob(16),'click',1,'none')"
        )
        try db.execute(
            "INSERT INTO brain_relations (relation_id,relation_uuid,app_id,from_scene_id,to_scene_id,element_key_id,verb,arguments_key,outcome,first_seen_ms,last_seen_ms) VALUES (1,'relation',1,1,1,1,'click','','already_satisfied',0,0)"
        )
        for table in ["brain_relations", "memory_step_signatures", "memory_person_commands"] {
            #expect(try scalar(db, "SELECT element_key_id FROM \(table)") == 1)
        }
    }

    @Test
    func stepsByTable() throws {
        let db = try database()
        let route = [
            "step_id": "1", "route_id": "1", "position": "0", "step_kind": "'goal'", "goal_text": "'Save'",
            "actor": "'person'", "segment_id": "1",
        ]
        try insert(db, "memory_route_steps", route)
        var invalid = route
        invalid["step_id"] = "2"
        invalid["position"] = "1"
        invalid["segment_id"] = "NULL"
        rejects(db, statement("memory_route_steps", invalid))
        try db.execute(
            "INSERT INTO memory_candidate_steps (candidate_id,position,block_index,actor,segment_id,step_kind) VALUES (1,0,0,'person',1,'person_only')"
        )
    }

    @Test
    func objectCountsRecorded() throws {
        let db = try database()
        for type in ["table", "trigger", "index"] {
            let count = try names(db, type: type).count
            let label = type == "index" ? "indexes" : type + "s"
            #expect(try resource().contains("-- \(label): \(count)\n"))
        }
    }

    @Test
    func vocabulariesOfOtherPlans() throws {
        for (field, values) in [
            ("recovery", ["postpone"]), ("effect_reason", ["not_readable"]), ("recovery_reason", ["not_permitted"]),
        ] {
            let db = try database()
            var row = action
            if field == "effect_reason" { row["effect"] = "'unknown'" }
            if field == "recovery_reason" { row["recovery"] = "'change_target'" }
            row[field] = "'\(values[0])'"
            try insert(db, "memory_agent_actions", row)
        }
        let reasons = [
            "qualified", "requalified", "policy_quarantined", "superseded", "judged_wrong",
            "retired_by_person", "retired_by_curation", "forgotten_by_person", "merged_same_screen",
            "split_distinct_surfaces", "imported", "migrated",
        ]
        for table in ["memory_part_states", "memory_part_judgments", "brain_scene_merges"] {
            for (index, reason) in reasons.enumerated() {
                let isolated = try database()
                var row: [String: String]
                switch table {
                case "memory_part_states":
                    row = ["part_id": "1", "sequence": "1", "state": "'usable'", "recorded_at_ms": "0"]
                case "memory_part_judgments":
                    row = ["part_id": "1", "family_root_route_id": "1", "judgment": "'wrong'", "recorded_at_ms": "0"]
                default:
                    row = [
                        "app_id": "1", "subject": "'kind'", "from_kind_id": "1", "into_kind_id": "2",
                        "action": "'merge'", "recorded_at_ms": "0",
                    ]
                }
                let author = ["braus", "person", "import"][index % 3]
                row["recorded_by"] = "'\(author)'"
                row["reason_code"] = "'\(reason)'"
                row["origin_id"] = author == "import" ? "1" : "NULL"
                var invalid = row
                invalid["reason_code"] = "'invalid'"
                rejects(isolated, statement(table, invalid))
                invalid = row
                invalid["recorded_by"] = "'invalid'"
                rejects(isolated, statement(table, invalid))
                try insert(isolated, table, row)
            }
        }
        let db = try database()
        for (position, value) in ["instance_value", "outside_target_scope", "self_changing_seen", "partial_capture"]
            .enumerated()
        {
            try db.execute("INSERT INTO memory_operation_verification_limits VALUES (1,\(position),'\(value)')")
        }
        for (event, reason) in ["committing_not_last", "committing_after_unconfirmed"].enumerated() {
            try db.execute("INSERT INTO memory_batch_stops VALUES (\(event+1),0,'\(reason)')")
        }
        try db.execute(
            "INSERT INTO memory_call_capabilities VALUES (1,'synthetic.capability','irreversible','command','registered','synthetic')"
        )
        rejects(
            db,
            "INSERT INTO memory_call_capabilities VALUES (2,'synthetic.capability','read','command','private','synthetic')"
        )
        try db.execute(
            "INSERT INTO memory_recall_requirements (query_id,need_position,selection_position,position,kind,selection_id,task_value_name) VALUES (1,0,0,0,'task_value_not_taken',1,'file')"
        )
        for table in ["brain_scene_elements", "memory_event_observations"] {
            #expect(
                try #require(
                    db.query("SELECT sql FROM sqlite_schema WHERE name = ?", [.text(table)]) { try $0.text(0) }.first!
                ).contains("'caption'"))
        }
        try db.execute(
            "INSERT INTO memory_qualification_policies (policy_id,policy_version,status,changed_at_ms) VALUES (1,'test','active',0)"
        )
        try db.execute("UPDATE memory_qualification_policies SET status='quarantined',reason='test',changed_at_ms=1")
        #expect(try scalar(db, "SELECT count(*) FROM memory_recall_work WHERE reason='policy'") == 1)
        try db.execute(
            "INSERT INTO memory_recall_generations (generation_id,document_format,status,started_at_ms) VALUES (1,'test','building',0)"
        )
        try db.execute("INSERT INTO memory_recall_entries VALUES (1,1,1,'procedure',1,1,0,0)")
        #expect(try scalar(db, "SELECT revision FROM memory_recall_generations") == 1)
        try db.execute("DELETE FROM memory_recall_entries")
        #expect(try scalar(db, "SELECT revision FROM memory_recall_generations") == 2)
        try db.execute(
            "INSERT INTO brain_scene_elements (scene_element_id,app_id,scene_id,element_key,label_origin,first_seen_ms,last_seen_ms) VALUES (1,1,1,'Save','caption',0,0)"
        )
        try db.execute(
            "INSERT INTO memory_event_observations (observation_id,event_id,phase,observation_kind,status,label_origin) VALUES (1,1,'after','capture','complete','caption')"
        )
        var invalid = task
        invalid["status"] = "'deferred'"
        rejects(db, statement("memory_tasks", invalid))
    }

    @Test
    func newTablesOfTheReconciliation() throws {
        let db = try database()
        let link = [
            "event_id": "1", "argument_name": "'file'", "position": "0", "link_kind": "'derived'",
            "derivation": "'file_extension'", "value_digest": "zeroblob(16)",
        ]
        for (field, value) in [
            ("link_kind", "'invalid'"), ("derivation", "'invalid'"), ("value_digest", "zeroblob(15)"),
        ] {
            var invalid = link
            invalid[field] = value
            rejects(db, statement("memory_operation_argument_links", invalid))
        }
        try insert(db, "memory_operation_argument_links", link)
        var provide = link
        provide["position"] = "1"
        provide["link_kind"] = "'to_provide'"
        provide["derivation"] = "NULL"
        try insert(db, "memory_operation_argument_links", provide)
        let family =
            "INSERT INTO memory_phase_families (family_id,app_id,kind,method_text,method_digest,masked_digest,has_parameter,length,label,members,procedures,first_member_seq,first_attempt_id,recorded_at_ms) VALUES "
        try db.execute(family + "(1,1,'step','click',zeroblob(16),zeroblob(16),0,1,'Save',1,1,1,1,0)")
        rejects(db, family + "(2,1,'step','click',zeroblob(16),zeroblob(16),0,1,'Save',1,1,1,1,0)")
        try db.execute(family + "(2,1,'procedure','click',zeroblob(16),zeroblob(16),0,1,'Save',1,1,1,1,0)")
        try db.execute("INSERT INTO memory_phase_family_attempts VALUES (1,1,1,1)")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("DELETE FROM memory_phase_families WHERE family_id = 1")
        #expect(try scalar(db, "SELECT count(*) FROM memory_phase_family_attempts") == 0)
        try db.execute("PRAGMA foreign_keys = OFF")
        try db.execute(
            "INSERT INTO memory_attempt_reused_parts (task_occurrence_id,part_id,item_id,recorded_at_ms) VALUES (1,1,NULL,0)"
        )
        rejects(
            db,
            "INSERT INTO memory_attempt_reused_parts (task_occurrence_id,part_id,item_id,recorded_at_ms) VALUES (1,1,NULL,0)"
        )
        try db.execute(
            "INSERT INTO memory_step_signatures (app_id,signature_digest,verb,arguments_shape) VALUES (1,zeroblob(16),'click','none')"
        )
        try db.execute(
            "INSERT INTO memory_recall_calibration (query_id,need_position,part_id,rank,score,threshold,delivered) VALUES (1,0,1,0,0.8,0.5,1)"
        )
        #expect(try scalar(db, "SELECT cosine IS NULL AND lexical IS NULL FROM memory_recall_calibration") == 1)
        try db.execute(
            "INSERT INTO memory_part_qualifications (part_id,sequence,policy_id,verdict,evaluated_at_ms,complete) VALUES (1,1,1,'admitted',0,0)"
        )
        try db.execute("UPDATE memory_part_qualifications SET complete = 1")
        rejects(db, "UPDATE memory_part_qualifications SET complete = 0", code: 1811)
        rejects(db, "UPDATE memory_part_qualifications SET complete = 1", code: 1811)
        let relation =
            "INSERT INTO brain_relations (relation_id,relation_uuid,app_id,kind_id,element_key_id,verb,arguments_key,outcome,first_seen_ms,last_seen_ms) VALUES "
        try db.execute(relation + "(2,'kind-relation',1,1,NULL,'click','','already_satisfied',0,0)")
        rejects(db, relation + "(3,'duplicate-kind-relation',1,1,NULL,'click','','already_satisfied',0,0)")
        var invalid = personCommand
        invalid["arrival_kind"] = "'state'"
        invalid["arrival_state"] = "'mixed'"
        rejects(db, statement("memory_person_commands", invalid))
        try insert(db, "memory_agent_actions", action)
        try db.execute(
            "INSERT INTO memory_call_capabilities VALUES (1,'synthetic.capability','read','command','registered','synthetic')"
        )
    }

    @Test
    func knowledgeLookupsUseIndexes() throws {
        let db = try database()
        for (sql, index) in [
            (
                "SELECT part_id FROM memory_procedure_parts WHERE app_id = 1 AND part_kind = 'procedure'",
                "memory_procedure_parts_app_kind"
            ),
            (
                "SELECT part_id FROM memory_part_contract_items WHERE scene_id = 1 AND item_kind = 'entry_state'",
                "memory_part_contract_items_scene_kind"
            ),
            (
                "SELECT item_id FROM memory_todo_item_states WHERE linked_part_id = 1 ORDER BY todo_revision_id DESC",
                "memory_todo_item_states_part_revision"
            ),
        ] {
            let plan = try db.query("EXPLAIN QUERY PLAN " + sql) { try $0.text(3) ?? "" }.joined(separator: "\n")
            #expect(plan.contains(index))
            #expect(!plan.contains("SCAN "))
        }
    }

    @Test
    func segmentChecksCarryNoValue() throws {
        let db = try database()
        let row = [
            "segment_id": "1", "position": "0", "kind": "'value'", "app_id": "1", "operand": "'parameter'",
            "coverage": "'complete'",
        ]
        rejects(db, statement("memory_segment_checks", row))
        var invalid = row
        invalid["kind"] = "'state'"
        invalid["operand"] = "'none'"
        rejects(db, statement("memory_segment_checks", invalid))
        invalid = row
        invalid["operand"] = "'withheld'"
        invalid["parameter_name"] = "'file'"
        rejects(db, statement("memory_segment_checks", invalid))
        #expect(
            Set(try columns(db, "memory_segment_checks"))
                == Set([
                    "segment_id", "position", "kind", "app_id", "window_number", "subject_key", "operand",
                    "parameter_name", "expected_state", "coverage",
                ]))
    }

    @Test
    func takeoverIdempotent() throws {
        let db = try database()
        try db.execute(
            "INSERT INTO memory_task_attempts (task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision,task_revision_id) VALUES (1,1,1,'app','test',0,1,1)"
        )
        try db.execute("UPDATE memory_task_attempts SET takeover = 'person_episode'")
        try db.execute("UPDATE memory_task_attempts SET takeover = 'person_episode'")
        rejects(db, "UPDATE memory_task_attempts SET takeover = 'none'", code: 1811)
    }

    @Test
    func personCommandsHaveNoText() throws {
        let db = try database()
        #expect(
            Set(try columns(db, "memory_person_commands"))
                == Set([
                    "command_id", "segment_id", "position", "kind", "element_key_id", "menu_path", "key_code",
                    "modifiers", "effect_kind", "coverage", "cause", "scene_before_id", "scene_after_id",
                    "arrival_kind", "arrival_state", "arrival_parameter",
                ]))
        var invalid = personCommand
        invalid["segment_id"] = "NULL"
        rejects(db, statement("memory_person_commands", invalid))
        try insert(db, "memory_person_commands", personCommand)
    }

    @Test
    func sectionsLoadInOrder() throws {
        let db = try historicalTables()
        #expect(try names(db, type: "index").isEmpty)
        #expect(try names(db, type: "trigger").isEmpty)
        try db.execute(section("indexes"))
        try db.execute(section("triggers"))
        for row in try rows("Frozen tables") {
            #expect(try scalar(db, "SELECT count(*) FROM \(row[0])") == 1)
            rejects(db, "INSERT INTO \(row[0]) SELECT * FROM \(row[0])", code: 1811)
        }
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test
    func digestsAreStrictBlobs() throws {
        let db = try database()
        #expect(try !resource().contains("BLOB("))
        let fixtures: [String: [String: String]] = [
            "brain_scenes": [
                "scene_id": "1", "scene_uuid": "'scene'", "app_id": "1", "first_seen_ms": "0", "last_seen_ms": "0",
            ],
            "brain_element_keys": ["app_id": "1", "key_text": "'Save'", "first_seen_ms": "0"],
            "memory_elements": [:],
            "memory_element_sets": ["members": "zeroblob(0)"],
            "memory_task_values": [
                "task_id": "1", "revision": "1", "task_revision_id": "1", "position": "0",
                "name": "'file'", "value_kind": "'file'", "content": "'reference'",
                "sensitivity": "'personal'", "source": "'person'",
            ],
            "memory_parameter_bindings": [
                "parameter_id": "1", "route_id": "1", "task_occurrence_id": "1",
                "content": "'reference'", "source": "'person'",
            ],
            "memory_operation_argument_links": [
                "event_id": "1", "argument_name": "'file'", "position": "0", "link_kind": "'reference'",
            ],
            "memory_step_signatures": ["app_id": "1", "verb": "'click'", "arguments_shape": "'none'"],
            "memory_phase_families": [
                "app_id": "1", "kind": "'step'", "method_text": "'click'", "has_parameter": "0",
                "length": "1", "label": "'Save'", "members": "1",
                "procedures": "1", "first_member_seq": "1", "first_attempt_id": "1", "recorded_at_ms": "0",
            ],
            "memory_recall_texts": ["format": "'test'", "text": "'Save'"],
            "memory_procedure_candidates": [
                "task_id": "1", "task_occurrence_id": "1", "policy_version": "'test'",
                "built_at_ms": "0", "step_count": "1", "block_count": "1",
            ],
            "memory_procedure_interpretations": [
                "candidate_id": "1", "revision": "1", "contract_version": "1",
                "source": "'app'", "source_stream_id": "'test'", "task_revision": "1",
                "attempt_state": "'running'", "recorded_at_ms": "0",
            ],
        ]
        var inspected = Set<String>()
        for table in try names(db) {
            let fields = try db.query("PRAGMA table_info(\(table))") {
                (try $0.text(1) ?? "", try $0.text(2) ?? "")
            }.filter { $0.0.contains("digest") && $0.1 == "BLOB" }.map(\.0)
            guard !fields.isEmpty else { continue }
            inspected.insert(table)
            let base = try #require(fixtures[table], "A valid digest fixture is required for \(table)")
            for field in fields {
                let isolated = try database()
                var row = base
                for other in fields { row[other] = "zeroblob(16)" }
                for size in [15, 17] {
                    row[field] = "zeroblob(\(size))"
                    rejects(isolated, statement(table, row))
                }
                row[field] = "zeroblob(16)"
                try insert(isolated, table, row)
            }
        }
        #expect(inspected == Set(fixtures.keys))
        for table in ["brain_element_keys", "memory_elements", "memory_element_sets"] {
            let isolated = try database()
            var row = try #require(fixtures[table])
            row["digest"] = "zeroblob(16)"
            try insert(isolated, table, row)
            rejects(isolated, statement(table, row))
            row["replaced_by_id"] = "1"
            try insert(isolated, table, row)
        }
    }

    @Test
    func todoRevisionsRoundTrip() throws {
        let db = try database()
        try db.execute("INSERT INTO memory_todo_items VALUES (1,'item',1,1,'r1','plan')")
        for revision in 1...3 {
            try db.execute(
                "INSERT INTO memory_todo_revisions VALUES (\(revision),1,\(revision),1,'\(revision == 1 ? "drafted" : revision == 2 ? "revised" : "row_started")',NULL,\(revision))"
            )
            try db.execute(
                "INSERT INTO memory_todo_item_states (item_id,todo_revision_id,position,title,app_name,linked_part_id,status,expectation_revision_id) VALUES (1,\(revision),0,'Save','Synthetic',\(revision == 1 ? "NULL" : "1"),'\(revision == 3 ? "in_progress" : "pending")',\(min(revision,2)))"
            )
            if revision <= 2 {
                try db.execute(
                    "INSERT INTO memory_todo_item_expectations (item_id,todo_revision_id,predicate_position,kind,operand,parameter_name) VALUES (1,\(revision),0,'element','parameter','\(revision == 1 ? "draft" : "file")')"
                )
            }
        }
        let actual = try db.query(
            "SELECT s.title,s.app_name,s.linked_part_id,s.position,s.status,e.parameter_name FROM memory_todo_item_states s JOIN memory_todo_item_expectations e ON e.item_id=s.item_id AND e.todo_revision_id=s.expectation_revision_id ORDER BY s.todo_revision_id"
        ) {
            "\(try $0.text(0) ?? "")|\(try $0.text(1) ?? "")|\($0.integer(2) ?? 0)|\($0.integer(3) ?? 0)|\(try $0.text(4) ?? "")|\(try $0.text(5) ?? "")"
        }
        #expect(
            actual == [
                "Save|Synthetic|0|0|pending|draft", "Save|Synthetic|1|0|pending|file",
                "Save|Synthetic|1|0|in_progress|file",
            ])
        #expect(try scalar(db, "SELECT count(*) FROM memory_todo_items") == 1)
        rejects(
            db,
            "INSERT INTO memory_todo_item_states (item_id,todo_revision_id,position,title,status) VALUES (1,4,0,'Save','todo')"
        )
        rejects(
            db,
            "INSERT INTO memory_todo_item_states (item_id,todo_revision_id,position,title,status) VALUES (1,4,0,'\(String(repeating: "x", count: 121))','pending')"
        )
    }

    @Test
    func recallDocumentsShareTextAcrossFormats() throws {
        let db = try database(foreignKeys: true)
        try db.execute("INSERT INTO memory_recall_texts VALUES (1,zeroblob(16),'test','Save')")
        try db.execute("INSERT INTO memory_recall_documents VALUES (1,1,'format-one',0)")
        try db.execute("INSERT INTO memory_recall_documents VALUES (2,1,'format-two',0)")
        #expect(try scalar(db, "SELECT count(*) FROM memory_recall_documents WHERE text_id = 1") == 2)
        rejects(db, "INSERT INTO memory_recall_documents VALUES (3,1,'format-one',0)", code: 2067)
        #expect(try scalar(db, "SELECT count(*) FROM memory_recall_documents WHERE text_id = 1") == 2)
    }

    @Test
    func recallPiecesKeepTheirRole() throws {
        let db = try database()
        try db.execute("INSERT INTO memory_recall_texts VALUES (1,zeroblob(16),'test','Save')")
        try db.execute("INSERT INTO memory_recall_text_pieces VALUES (1,0,'label',1),(1,1,'contents',1)")
        #expect(
            try db.query("SELECT piece_kind FROM memory_recall_text_pieces ORDER BY position") { try $0.text(0) } == [
                "label", "contents",
            ])
        rejects(db, "INSERT INTO memory_recall_text_pieces VALUES (1,2,'label',1)")
    }

    @Test
    func vectorsBelongToOneSpace() throws {
        let db = try database()
        for id in 1...2 {
            try db.execute(
                "INSERT INTO memory_recall_spaces (space_int_id,space_id,model_id,model_revision,weights_digest,tokenizer_digest,dimensions,pooling,normalization,precision,query_prefix,document_prefix,maximum_tokens,recorded_at_ms) VALUES (\(id),'space\(id)','same-model','revision\(id)','\(String(repeating: "a", count: 64))','\(String(repeating: "b", count: 64))',2,'mean','l2','float32','','',100,0)"
            )
        }
        try db.execute("INSERT INTO memory_recall_vectors VALUES (1,1,1,0,zeroblob(8))")
        #expect(try scalar(db, "SELECT count(*) FROM memory_recall_vectors WHERE text_id=1 AND space_int_id=2") == 0)
        try db.execute("INSERT INTO memory_recall_vectors VALUES (1,2,1,0,zeroblob(8))")
    }

    @Test
    func mergeEndpointsTyped() throws {
        let db = try database()
        let base = [
            "merge_id": "1", "app_id": "1", "subject": "'kind'", "into_kind_id": "2", "action": "'merge'",
            "recorded_by": "'braus'", "reason_code": "'merged_same_screen'", "recorded_at_ms": "0",
        ]
        rejects(db, statement("brain_scene_merges", base))
        var row = base
        row["from_kind_id"] = "1"
        row["from_scene_id"] = "1"
        row["into_scene_id"] = "2"
        rejects(db, statement("brain_scene_merges", row))
        row = base
        row["from_kind_id"] = "2"
        rejects(db, statement("brain_scene_merges", row))
        row["from_kind_id"] = "1"
        row["action"] = "'split'"
        try insert(db, "brain_scene_merges", row)
        try db.execute("INSERT INTO brain_scene_kind_members VALUES (1,1,1,0,NULL),(2,1,2,1,1)")
        #expect(
            try scalar(
                db, "SELECT kind_id FROM brain_scene_kind_members WHERE scene_id=1 ORDER BY membership_id DESC LIMIT 1")
                == 2)
    }

    @Test
    func queueAcceptsAnyJobKind() throws {
        let db = try database()
        for code in ["index_rebuild", "segmentation", "brain_duplicates", "future_job"] {
            try db.execute(
                "INSERT INTO memory_consolidation_queue (job_kind,ref_id,enqueued_at_ms) VALUES ('\(code)',1,0)")
            try db.execute(
                "INSERT INTO memory_consolidation_cursors (job_kind,last_seq,algorithm_version,generation) VALUES ('\(code)',0,1,1)"
            )
        }
        for code in ["Upper", "has space", String(repeating: "x", count: 41)] {
            rejects(
                db, "INSERT INTO memory_consolidation_queue (job_kind,ref_id,enqueued_at_ms) VALUES ('\(code)',1,0)")
            rejects(
                db,
                "INSERT INTO memory_consolidation_cursors (job_kind,last_seq,algorithm_version,generation) VALUES ('\(code)',0,1,1)"
            )
        }
        try db.execute("DELETE FROM memory_consolidation_queue")
        #expect(try scalar(db, "SELECT count(*) FROM memory_consolidation_queue") == 0)
    }

    @Test
    func rejectReasonOnlyAtInsert() throws {
        let db = try database()
        try db.execute(
            "INSERT INTO memory_event_observations (observation_id,event_id,phase,observation_kind,status,reject_reason) VALUES (1,1,'after','capture','partial','incomplete')"
        )
        rejects(db, "UPDATE memory_event_observations SET reject_reason = 'uncertain_surface'", code: 1811)
    }
}
