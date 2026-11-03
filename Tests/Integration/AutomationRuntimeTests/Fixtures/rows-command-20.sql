-- Synthetic fixture: no application or person data.
INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic');
INSERT INTO memory_events(event_id,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
VALUES ('gesture','cli','fixture','action',1,0,'not_applicable'),
       ('check','cli','fixture','verification',1,1,'not_applicable');
INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status,started_at_ms,completed_at_ms,result_kind)
VALUES ('gesture',1,'command','completed',0,1,'acted_unverified');
INSERT INTO memory_operation_arguments(event_id,app_id,argument_name,value_kind,text_value)
VALUES ('gesture',1,'command','text','fixture.rename'),('gesture',1,'interface','text','fixture'),
       ('gesture',1,'args.name','text','demo.txt');
INSERT INTO memory_verifications(event_id,scope,method,verdict) VALUES ('check','call','state_read_back','passed');
INSERT INTO memory_operation_verifications(event_id,call_event_id,contract_version,condition_kind,method_version,performed)
VALUES ('check','gesture',1,'state_read_back','fixture-v1','requested');

        INSERT INTO memory_tasks(task_id,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
        VALUES ('task',1,'cli','test',0,'open',1);
        INSERT INTO memory_task_revisions(task_id,revision,recorded_at_ms,change_kind,goal) VALUES ('task',1,0,'opened','Save');
        INSERT INTO memory_task_occurrences(task_occurrence_id,started_at_ms,status) VALUES ('attempt',0,'in_progress');
        INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision)
        VALUES ('attempt','task',1,'cli','test',0,1);
        INSERT INTO memory_routes(route_id,name,status,created_at_ms) VALUES ('method','Save method','active',0);
        INSERT INTO memory_route_steps(step_id,route_id,position,step_kind,goal_text,app_id) VALUES ('step','method',0,'goal','Save',1);
        INSERT INTO memory_step_occurrences(step_occurrence_id,task_occurrence_id,step_id,started_at_ms,status)
        VALUES ('occur','attempt','step',0,'completed');
        INSERT INTO memory_task_events(task_occurrence_id,event_id,position,role) VALUES ('attempt','gesture',0,'action');
        INSERT INTO memory_step_events(step_occurrence_id,event_id,position,role) VALUES ('occur','gesture',0,'action');
        INSERT INTO memory_route_parameters(parameter_id,route_id,name,direction,value_type,is_required)
        VALUES ('parameter','method','input','input','text',1);
        INSERT INTO memory_parameter_details(parameter_id,route_id,role,value_kind,sensitivity)
        VALUES ('parameter','method','file name','text','ordinary');
        INSERT INTO memory_parameter_bindings(parameter_id,route_id,task_occurrence_id,content,text_value,source)
        VALUES ('parameter','method','attempt','text','demo.txt','request');
        INSERT INTO memory_step_operations(operation_id,route_id,step_id,position,tool_kind,app_id)
        VALUES ('operation','method','step',0,'command',1);
        INSERT INTO memory_operation_argument_segments(route_id,operation_id,argument_name,argument_position,argument_index,segment_position,segment_kind,literal_text,parameter_id)
        VALUES ('method','operation','args.name',0,0,0,'literal','Save ',NULL),
               ('method','operation','args.name',0,0,1,'parameter',NULL,'parameter');
        INSERT INTO memory_procedure_candidates(candidate_id,task_id,task_occurrence_id,policy_version,structure_digest,built_at_ms,step_count,block_count)
        VALUES ('candidate','task','attempt','app-blocks-2','old-fnv',0,1,1);
        INSERT INTO memory_candidate_steps(candidate_id,position,step_occurrence_id,call_event_id,block_index,app_id)
        VALUES ('candidate',0,'occur','gesture',0,1);
        INSERT INTO memory_procedure_interpretations(interpretation_id,candidate_id,revision,contract_version,payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
        VALUES ('interpretation','candidate',1,1,'old-fnv','cli','test',1,'running',0);
        INSERT INTO memory_procedure_versions(route_id,interpretation_id,candidate_id,task_id,task_occurrence_id,contract_version,built_at_ms)
        VALUES ('method','interpretation','candidate','task','attempt',1,0);
        INSERT INTO memory_procedure_parts(part_id,route_id,part_kind,parent_part_id,first_position,last_position,step_id,app_id,label,declared_outcome)
        VALUES ('method/procedure','method','procedure',NULL,0,0,NULL,1,'Save method','completed'),
               ('method/step-0','method','step','method/procedure',0,0,'step',1,'Save','not_declared');
        INSERT INTO memory_part_states(part_id,sequence,state,reason,recorded_by,recorded_at_ms)
        VALUES ('method/step-0',1,'usable','historical decision','braus-cli',0);

INSERT INTO memory_operation_arguments(operation_id,route_id,app_id,argument_name,value_kind,text_value)
VALUES ('operation','method',1,'command','text','fixture.rename'),('operation','method',1,'interface','text','fixture');
