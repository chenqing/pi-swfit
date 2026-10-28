#!/usr/bin/env python3
"""Offline CLI integration: real local SSE transport, tool call, JSONL, persistence, and failure exit."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
bin_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()
pf = str(Path(bin_dir) / 'pf')
with tempfile.TemporaryDirectory(prefix='pf-smoke-') as temporary:
    directory = Path(temporary)
    fixture = directory / 'fixture.txt'
    fixture.write_text('local fixture content')
    env = dict(os.environ, PF_AGENT_DIR=str(directory/'agent'), OPENAI_API_KEY='local-fixture-only')
    def run(*args, code=0, input=''):
        p = subprocess.run([pf, *args], input=input, text=True, capture_output=True, cwd=directory, env=env, timeout=20)
        assert p.returncode == code, (args, p.returncode, p.stderr, p.stdout)
        return p
    assert run('--version').stdout.startswith('pf ')
    assert 'User turns in this session: 1' in run('--demo', '-p', 'first').stdout
    assert 'User turns in this session: 2' in run('--demo', '-c', '-p', 'second').stdout
    assert 'User turns in this session: 1' in run('--demo', '--no-session', '-p', 'fresh').stdout
    assert 'Unsupported option' in run('--unknown-option', code=1).stderr
    events = [json.loads(line) for line in run('--demo', '--no-session', '--mode', 'json', 'hello').stdout.splitlines()]
    assert events[0]['type'] == 'session'
    assert {'agent_start', 'message_update', 'message_end', 'agent_end', 'agent_settled'} <= {e['type'] for e in events}
    assert 'User turns in this session: 1' in run('--demo', '-p', '--no-session', input='piped prompt').stdout

    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            if body['model'] == 'failure':
                self.send_response(401); self.send_header('Content-Type', 'application/json'); self.end_headers()
                self.wfile.write(b'{"error":{"message":"fixture unauthorized"}}'); return
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            has_tool = any(m['role'] == 'tool' for m in body['messages'])
            if has_tool:
                assert any('local fixture content' in str(m.get('content')) for m in body['messages'] if m['role'] == 'tool')
                chunks = [{'choices':[{'index':0,'delta':{'role':'assistant','content':'fixture-ok'},'finish_reason':None}]},
                          {'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]
            else:
                chunks = [{'choices':[{'index':0,'delta':{'role':'assistant','tool_calls':[{'index':0,'id':'call_fixture','type':'function','function':{'name':'read','arguments':json.dumps({'path':str(fixture)})}}]},'finish_reason':None}]},
                          {'choices':[{'index':0,'delta':{},'finish_reason':'tool_calls'}]}]
            try:
                for chunk in chunks:
                    self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode()); self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
            except BrokenPipeError: pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    base = ['--no-session','--provider','openai','--model','fixture','--api','openai-completions','--base-url',f'http://127.0.0.1:{server.server_port}/v1','--tools','read']
    try:
        assert run(*base, '-p', 'read fixture').stdout.strip() == 'fixture-ok'
        json_run = run(*base, '--mode', 'json', 'read fixture')
        events = [json.loads(line) for line in json_run.stdout.splitlines()]
        assert any(e['type']=='tool_execution_end' and not e['isError'] for e in events)
        assert any(e['type']=='message_end' and e['message'].get('role')=='assistant' for e in events)
        failing = base.copy(); failing[failing.index('--model')+1] = 'failure'
        assert 'fixture unauthorized' in run(*failing,'-p','fail',code=1).stderr
    finally:
        server.shutdown(); server.server_close()
print('pf smoke: help/version, session resume, stdin, JSONL, real local SSE + read tool, and nonzero failure exit passed')
