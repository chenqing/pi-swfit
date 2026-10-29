#!/usr/bin/env python3
"""Exercise resource discovery, Tab completion, reload and expansion through pf's real PTY."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
pf = os.environ.get('PF_TEST_EXECUTABLE')
if not pf:
    pf = str(Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()) / 'pf')
with tempfile.TemporaryDirectory(prefix='pf-resource-commands-') as temporary:
    directory = Path(temporary)
    agent = directory / 'agent'
    prompts = agent / 'prompts'
    prompts.mkdir(parents=True)
    (prompts / 'review.md').write_text('---\ndescription: Review files\nargument-hint: file\n---\nReview $1; rest ${@:2}; default ${3:-none}')
    skills = agent / 'skills' / 'inspect'
    skills.mkdir(parents=True)
    (skills / 'SKILL.md').write_text('---\nname: inspect\ndescription: Inspect fixture\ndisable-model-invocation: true\n---\nRead fixture instructions.')
    project = directory / '.pi' / 'prompts'
    project.mkdir(parents=True)
    (project / 'project-only.md').write_text('Project resource')
    master, slave = pty.openpty()
    env = dict(os.environ, PF_AGENT_DIR=str(agent))
    env.pop('PF_MODEL', None)
    process = subprocess.Popen([pf, '--demo'], stdin=slave, stdout=slave, stderr=slave, cwd=directory, env=env)
    os.close(slave)
    pending = b''
    def until(marker):
        global pending
        wanted = marker.encode()
        deadline = time.monotonic() + 15
        while wanted not in pending:
            assert time.monotonic() < deadline, (marker, pending.decode(errors='replace'))
            if select.select([master], [], [], .2)[0]:
                pending += os.read(master, 65536)
        found, pending = pending.split(wanted, 1)
        return found.decode(errors='replace')
    def send(line):
        os.write(master, (line + '\n').encode())
        return until('pf › ')
    def users():
        return [e['message']['content'] for file in agent.rglob('*.jsonl')
                for e in map(json.loads, file.read_text().splitlines())
                if e.get('type') == 'message' and e.get('message', {}).get('role') == 'user']
    try:
        until('pf › ')
        help_text = send('/help')
        assert '/review' in help_text and '/skill:inspect' in help_text and '/project-only' not in help_text
        os.write(master, b'/rev\t')
        until('/review ')
        assert not users(), 'Tab must not submit'
        send('"two files" tail')
        assert 'Review two files; rest tail; default none' in str(users())
        send('/skill:inspect additional instructions')
        assert '<skill name="inspect"' in str(users()) and 'additional instructions' in str(users())
        (prompts / 'review.md').unlink()
        (prompts / 'fresh.md').write_text('Fresh ${1:-fallback}')
        assert 'reload' in send('/reload').lower()
        help_text = send('/help')
        assert '/fresh' in help_text and '/review' not in help_text
        send('/fresh')
        assert 'Fresh fallback' in str(users())
        assert 'Unknown command' in send('/review')
        assert len(users()) == 3, users()
        os.write(master, b'/quit\n')
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try: os.read(master, 65536)
                except OSError: break
        assert process.wait(timeout=3) == 0
        batch = subprocess.run([pf, '--demo', '--trust-project', '-p', '/project-only'], input='', capture_output=True, text=True, cwd=directory, env=env, timeout=15)
        assert batch.returncode == 0, batch.stderr
        assert 'Project resource' in str(users())
        print('Resource slash PTY smoke passed: discovery, Tab without send, quoted args, user-only skill, reload, local errors and project trust.')
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=10)
        os.close(master)
