#!/usr/bin/env python3
"""Offline PTY acceptance for pf's interactive slash-command path."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
bin_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()
with tempfile.TemporaryDirectory(prefix='pf-slash-') as temporary:
    directory = Path(temporary)
    master, slave = pty.openpty()
    env = dict(os.environ, PF_AGENT_DIR=str(directory/'agent'))
    env.pop('PF_MODEL', None)
    process = subprocess.Popen([str(Path(bin_dir)/'pf'), '--demo'], stdin=slave, stdout=slave, stderr=slave, cwd=directory, env=env)
    os.close(slave)
    pending = b''
    def until(marker):
        global pending
        wanted = marker.encode()
        end = time.monotonic()+15
        while wanted not in pending:
            assert time.monotonic() < end, (marker, pending.decode(errors='replace'))
            if select.select([master], [], [], 0.2)[0]:
                pending += os.read(master, 65536)
        found, pending = pending.split(wanted, 1)
        return found.decode(errors='replace')
    def send(line, marker='pf › '):
        os.write(master, (line+'\n').encode())
        return until(marker)
    try:
        until('pf › ')
        assert '/resume' in send('/help')
        send('first fixture message')
        assert 'Conversation renamed' in send('/name PTY fixture')
        assert 'Messages:' in send('/session')
        assert 'New conversation' in send('/new')
        assert 'PTY fixture' in send('/resume', 'Choose a number (empty cancels):')
        assert 'Resumed conversation' in send('1')
        assert 'Unknown command' in send('/not-a-command')
        assert 'does not take arguments' in send('/new unexpected')
        send('second fixture message')
        os.write(master, b'/quit\n')
        assert process.wait(timeout=10) == 0
        users = []
        for file in (directory/'agent').rglob('*.jsonl'):
            entries = [json.loads(line) for line in file.read_text().splitlines()]
            users += [e['message']['content'] for e in entries if e.get('type') == 'message' and e.get('message', {}).get('role') == 'user']
        assert len(users) == 2, users
        assert all('/not-a-command' not in str(value) and '/name' not in str(value) for value in users)
        print('Slash PTY smoke passed: help, name, session, new, resume, local errors and transcript isolation.')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        os.close(master)
