#!/usr/bin/python3
"""Offline provider: real authenticated MCP requests, no external model or app."""
import json
import os
import socket
import sys

root = os.path.dirname(os.path.realpath(__file__))
args = sys.argv[1:]
message = sys.stdin.read()
if args and args[0] == 'exec':
    provider = 'codex'
    instructions = json.loads(next(a.split('=', 1)[1] for a in args if a.startswith('developer_instructions=')))
    server = next(a for a in args if a.startswith('mcp_servers.braus='))
    bridge_args, _ = json.JSONDecoder().raw_decode(server.split('args=', 1)[1])
    connection_file = bridge_args[2]
else:
    provider = 'claude'
    instructions = args[args.index('--append-system-prompt') + 1]
    config = json.loads(args[args.index('--mcp-config') + 1])
    connection_file = config['mcpServers']['braus']['args'][2]
with open(connection_file) as stream:
    endpoint = json.load(stream)
with open(os.path.join(root, 'delivered.json'), 'w') as stream:
    json.dump({'provider': provider, 'instructions': instructions}, stream)
with open(os.path.join(root, 'commands.json')) as stream:
    commands = json.load(stream)
answers = []
with socket.create_connection(('127.0.0.1', endpoint['port']), timeout=30) as channel:
    stream = channel.makefile('rwb')
    for number, command in enumerate(commands, 1):
        request = {'jsonrpc':'2.0', 'id':number, 'method':command['method'], 'params':command['params']}
        stream.write((json.dumps({'token':endpoint['token'], 'message':request})+'\n').encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                raise RuntimeError('Tool host closed before answering')
            answer = json.loads(line)
            answer = answer.get('message', answer)
            if answer.get('id') == number:
                break
        if 'error' in answer:
            raise RuntimeError(answer['error'])
        if bool(answer['result'].get('isError')) != command.get('isError', False):
            raise RuntimeError('Unexpected rejection status for command '+str(number))
        answers.append(answer)
with open(os.path.join(root, 'answers.json'), 'w') as stream:
    json.dump(answers, stream)
with open(os.path.join(root, 'reply.jsonl')) as stream:
    sys.stdout.write(stream.read())
sys.stdout.flush()
