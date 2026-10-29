#!/usr/bin/env python3
"""Offline PTY acceptance for pf's interactive slash-command path."""
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import termios
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
pf = os.environ.get('PF_TEST_EXECUTABLE')
if not pf:
    bin_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()
    pf = str(Path(bin_dir) / 'pf')
with tempfile.TemporaryDirectory(prefix='pf-navigation-') as temporary:
    directory = Path(temporary)
    master, slave = pty.openpty()
    env = dict(os.environ, PF_AGENT_DIR=str(directory/'agent'))
    env.pop('PF_MODEL', None)
    process = subprocess.Popen([pf, '--demo'], stdin=slave, stdout=slave, stderr=slave, cwd=directory, env=env)
    terminal_before = termios.tcgetattr(slave)
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
        assert 'Thinking level: off' in send('/thinking off')
        assert 'Available levels: off' in send('/thinking high')
        send('first fixture message')
        second = 'second fixture message\n第二行'
        os.write(master, 'second fixture message\x16\n第二行\n'.encode())
        until('No network or tools were used.')
        until('pf › ')
        menu = send('/fork', 'Choose a number (empty cancels):')
        assert 'second fixture message' in menu
        send('2')
        until('第二行')  # multiline prefill is editable, never auto-submitted
        os.write(master, b'\x7f' * len(second) + 'edited 中文 fork message\n'.encode())  # Backspace edits the Unicode prefill without sending history
        until('No network or tools were used.')
        until('pf › ')
        menu = send('/tree', 'Choose a number (empty cancels):')
        match = re.search(r'(\d+)\. first fixture message', menu)
        assert match, menu
        send(match.group(1), 'Choose a number (empty cancels):')
        send('1')  # No summary; no provider request
        until('first fixture message')
        os.write(master, b'\x15alternate root\n')
        until('No network or tools were used.')
        until('pf › ')
        os.write(master, b'/quit\n')
        # Drain libedit's terminal output while waiting for normal shutdown.
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try: os.read(master, 65536)
                except OSError: break
        assert process.wait(timeout=3) == 0
        files = list((directory/'agent').rglob('*.jsonl'))
        assert len(files) == 2, files
        transcripts = [[json.loads(line) for line in f.read_text().splitlines()] for f in files]
        fork = next(entries for entries in transcripts if entries[0].get('parentSession'))
        source = next(entries for entries in transcripts if not entries[0].get('parentSession'))
        def users(entries):
            contents = [e['message']['content'] for e in entries if e.get('type') == 'message' and e.get('message', {}).get('role') == 'user']
            return [value if isinstance(value, str) else ''.join(part.get('text', '') for part in value) for value in contents]
        assert users(source) == ['first fixture message', second], users(source)
        assert users(fork) == ['first fixture message', 'edited 中文 fork message', 'alternate root'], users(fork)
        assert not any('/fork' in str(e) or '/tree' in str(e) for e in transcripts)
        assert termios.tcgetattr(slave)[3] == terminal_before[3], 'terminal mode not restored'
        pending = b''
        process = subprocess.Popen([pf, '--demo', '--no-session'], stdin=slave, stdout=slave, stderr=slave, cwd=directory, env=env)
        until('pf › ')
        process.send_signal(signal.SIGINT)
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]: os.read(master, 65536)
        assert process.wait(timeout=3) == 130
        assert termios.tcgetattr(slave)[3] == terminal_before[3], 'SIGINT left terminal in raw mode'
        print('Navigation PTY smoke passed: thinking validation, fork, tree, Unicode/multiline editing, original preservation, branches and SIGINT terminal restoration.')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        os.close(master)
        os.close(slave)
