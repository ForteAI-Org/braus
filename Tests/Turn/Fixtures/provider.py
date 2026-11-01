#!/usr/bin/python3
"""A synthetic Claude process: captures its input and makes one authenticated status call."""
import json
import os
import socket
import sys

root = os.path.dirname(os.path.realpath(__file__))
arguments = sys.argv[1:]
message = sys.stdin.read()
with open(os.path.join(root, 'received.json'), 'w') as output:
    json.dump({'arguments': arguments, 'standardInput': message}, output)
config = json.loads(arguments[arguments.index('--mcp-config') + 1])
connection = config['mcpServers']['braus']['args'][2]
with open(connection) as source:
    endpoint = json.load(source)
with open(os.path.join(root, 'reply.jsonl')) as source:
    sys.stdout.write(source.read())
sys.stdout.flush()
with socket.create_connection(('127.0.0.1', endpoint['port']), timeout=5) as channel:
    stream = channel.makefile('rwb')
    for number, method, params in [
        (1, 'initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                           'clientInfo': {'name': 'turn-test', 'version': '1'}}),
        (2, 'tools/call', {'name': 'status', 'arguments': {}}),
    ]:
        frame = {'token': endpoint['token'], 'message': {'jsonrpc': '2.0', 'id': number,
                                                        'method': method, 'params': params}}
        stream.write((json.dumps(frame) + '\n').encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                raise RuntimeError('Tool host closed before answering')
            answer = json.loads(line)
            answer = answer.get('message', answer)
            if answer.get('id') == number:
                if 'error' in answer:
                    raise RuntimeError(answer['error'])
                break
