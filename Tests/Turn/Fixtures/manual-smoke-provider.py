#!/usr/bin/python3
"""Scripted decisions, actual Braus chat invocation/internal bridge and real apps.

No model is exercised by this child. It records requests before dispatch and
answers immediately; the private endpoint token is never written to evidence.
"""
from pathlib import Path
import json
import re
import socket
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_support import app_oracle, write

ROOT = Path(__file__).resolve().parent
CONTEXT = json.loads((ROOT / 'context.json').read_text())
TRACE = []
PROOF = {'decision_maker': 'scripted_child', 'real_cli_frontdoor': CONTEXT.get('real_cli_frontdoor', True),
         'external_mcp_client': False, 'functional': 'not_evaluated', 'checks': [],
         'cleanup': 'not_evaluated'}
STREAM = None


def call(name, arguments, expected_error=False):
    if name in ('status', 'close_session'):
        name, arguments = 'call', {'name': name, 'arguments': arguments}
    number = len(TRACE) + 1
    record = {'id': number, 'tool': name, 'arguments': arguments}
    TRACE.append(record)
    write(ROOT / 'tool-trace.json', TRACE)
    request = {'jsonrpc': '2.0', 'id': number, 'method': 'tools/call',
               'params': {'name': name, 'arguments': arguments}}
    STREAM.write((json.dumps({'token': ENDPOINT['token'], 'message': request}) + '\n').encode())
    STREAM.flush()
    while True:
        line = STREAM.readline()
        if not line:
            raise RuntimeError('Tool host closed without an answer')
        answer = json.loads(line)
        answer = answer.get('message', answer)
        if answer.get('id') == number:
            break
    record['answer'] = answer
    write(ROOT / 'tool-trace.json', TRACE)
    if 'error' in answer:
        raise RuntimeError('RPC refusal: ' + str(answer['error']))
    result = answer['result']
    if bool(result.get('isError', False)) != expected_error:
        raise RuntimeError('Unexpected tool outcome: ' + name)
    if 'structuredContent' in result:
        return result['structuredContent']
    for block in result.get('content', []):
        if block.get('type') == 'text':
            try:
                return json.loads(block['text'])
            except ValueError:
                pass
    return result


def opened(bundle, process, window=None):
    arguments = {'app': bundle}
    if window:
        arguments['window'] = window
    value = call('open_session', arguments)
    scene = value.get('scene', '')
    if '(' + bundle + ')' not in scene:
        raise RuntimeError('Requested app identity missing from returned scene')
    if window and window not in scene.split('\n')[0]:
        raise RuntimeError('Requested window missing from returned scene header')
    oracle = app_oracle(CONTEXT['kit'], bundle, process)
    if not oracle['has_window']:
        raise RuntimeError('Independent requested-app/window oracle failed')
    if window and not any(window in row['title'] for app in oracle['applications'] for row in app['windows']):
        raise RuntimeError('Independent requested-window oracle failed')
    PROOF['checks'].append({'app': bundle, 'window': window, 'oracle': oracle})
    write(ROOT / 'functional.json', PROOF)
    if not value.get('session'):
        raise RuntimeError('Opening returned no session identity')
    return value


def scenario():
    if CONTEXT['case'] == 'S1':
        opened('com.apple.Maps', 'Maps')
        observed = call('observe', {'full': True})
        if '(com.apple.Maps)' not in observed.get('scene', ''):
            raise RuntimeError('Observe silently changed application')
        PROOF['functional'] = 'passed'
        return
    first = opened('com.apple.calculator', 'Calculator')
    call('open_session', {'app': 'org.braus.smoke.definitely-missing-' + CONTEXT['nonce']}, True)
    if call('status', {}).get('session') != first['session']:
        raise RuntimeError('Failed B replacement changed retained A identity')
    observed = call('observe', {'full': True})
    if '(com.apple.calculator)' not in observed.get('scene', ''):
        raise RuntimeError('Failed B replacement lost A observation')
    if opened('com.apple.calculator', 'Calculator')['session'] != first['session']:
        raise RuntimeError('Resuming retained A created a different session')
    PROOF['failed_B_retains_A'] = 'passed'
    if CONTEXT['windows_ready']:
        opened('com.apple.TextEdit', 'TextEdit', CONTEXT['window_a'])
        second = opened('com.apple.TextEdit', 'TextEdit', CONTEXT['window_b'])
        resumed = opened('com.apple.TextEdit', 'TextEdit')
        if resumed['session'] != second['session'] or CONTEXT['window_b'] not in resumed.get('scene', '').split('\n')[0]:
            raise RuntimeError('Nil-window resume lost the selected window/identity')
        opened('com.apple.calculator', 'Calculator')
        PROOF['normal_switch_and_other_window'] = 'passed'
        PROOF['functional'] = 'passed'
    else:
        PROOF['normal_switch_and_other_window'] = 'BLOCKED: ' + CONTEXT['windows_reason']
        PROOF['functional'] = 'blocked'


try:
    argv = sys.argv[1:]
    sys.stdin.read()
    if not argv or argv[0] != 'exec':
        raise ValueError('Expected actual Braus Codex exec invocation')
    instructions = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
    server = next(a for a in argv if a.startswith('mcp_servers.braus='))
    bridge_args, _ = json.JSONDecoder().raw_decode(server.split('args=', 1)[1])
    ENDPOINT = json.loads(Path(bridge_args[2]).read_text())
    write(ROOT / 'delivered-context.json', {'provider': 'codex', 'instructions': instructions})
    with socket.create_connection(('127.0.0.1', ENDPOINT['port']), timeout=120) as channel:
        STREAM = channel.makefile('rwb')
        try:
            scenario()
        except BaseException as error:
            PROOF['functional'] = 'failed'
            PROOF['error'] = str(error)
        finally:
            try:
                closed = call('close_session', {})
                status = call('status', {})
                if closed.get('status') != 'closed' or 'session' not in status or status['session'] is not None or closed.get('warning'):
                    raise RuntimeError('Close left an active session or cleanup warning')
                PROOF['cleanup'] = 'passed'
                PROOF['release'] = {'close_answer_received': True, 'status_answer_received': True,
                                    'session_absent': status.get('session') is None,
                                    'cleanup_warning_absent': not closed.get('warning')}
                PROOF['process_exit_claimed'] = False
            except BaseException as error:
                PROOF['cleanup'] = 'failed'
                PROOF['cleanup_error'] = str(error)
        write(ROOT / 'functional.json', PROOF)
    print(json.dumps({'type': 'thread.started', 'thread_id': str(uuid.uuid4())}))
    print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 0, 'output_tokens': 0}}))
except BaseException as error:
    PROOF['functional'] = 'failed'
    PROOF['error'] = str(error)
    write(ROOT / 'functional.json', PROOF)
    print(str(error), file=sys.stderr)
    sys.exit(1)
