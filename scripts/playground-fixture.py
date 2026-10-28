#!/usr/bin/env python3
"""Local-only OpenAI-compatible fixture for manual Playground read/edit/resume QA.

Creates a temporary workspace. Enter the printed endpoint, model `fixture`, and
key `local-fixture-only` in Playground. No external provider is contacted.
"""
import http.server
import json
from pathlib import Path
import tempfile

root = Path(tempfile.mkdtemp(prefix='pi-playground-qa-'))
workspace = root / 'workspace'
workspace.mkdir()
(workspace / 'sample.txt').write_text('Hello from Pi.\n')

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = body['messages']
        users = sum(m['role'] == 'user' for m in messages)
        results = {m.get('tool_call_id') for m in messages if m['role'] == 'tool'}
        if users > 1:
            delta = {'role': 'assistant', 'content': f'Restored conversation: {users} user turns. The earlier file change is still in context.'}
            finish = 'stop'
        elif 'read_fixture' not in results:
            delta = {'role': 'assistant', 'content': 'I’ll read sample.txt first.', 'tool_calls': [{'index': 0, 'id': 'read_fixture', 'type': 'function', 'function': {'name': 'read', 'arguments': json.dumps({'path': 'sample.txt'})}}]}
            finish = 'tool_calls'
        elif 'edit_fixture' not in results:
            delta = {'role': 'assistant', 'content': 'Here is the proposed change.', 'tool_calls': [{'index': 0, 'id': 'edit_fixture', 'type': 'function', 'function': {'name': 'edit', 'arguments': json.dumps({'path': 'sample.txt', 'edits': [{'oldText': 'Hello from Pi.', 'newText': 'Hello from Pi Swift.'}]})}}]}
            finish = 'tool_calls'
        else:
            delta = {'role': 'assistant', 'content': 'The tool result is saved in this conversation. Expand the edit row to inspect its result and diff.'}
            finish = 'stop'
        with (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'user_turns': users, 'tool_results': sorted(str(v) for v in results), 'authenticated': self.headers.get('Authorization') == 'Bearer local-fixture-only'}) + '\n')
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for chunk in [{'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}, {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]}]:
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode()); self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n')
        except BrokenPipeError:
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
info = {'root': str(root), 'workspace': str(workspace), 'agent_dir': str(root / 'agent'), 'endpoint': f'http://127.0.0.1:{server.server_port}/v1'}
(root / 'fixture.json').write_text(json.dumps(info))
print(json.dumps(info), flush=True)
try:
    server.serve_forever()
finally:
    server.server_close()
