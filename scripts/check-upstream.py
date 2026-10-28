#!/usr/bin/env python3
"""Compare tracked upstream blobs. Read-only: never changes source or the compatibility lock."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import sys
import time
parser = argparse.ArgumentParser()
parser.add_argument('--ref', default='main', help='Upstream commit or ref to compare with the reviewed snapshot')
args = parser.parse_args()
lock = json.loads((Path(__file__).resolve().parents[1]/'Docs/upstream-lock.json').read_text())
changed = []
for entry in lock['trackedFiles']:
    url = f"https://raw.githubusercontent.com/{lock['repository']}/{args.ref}/{entry['path']}"
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "pi-swift-upstream-check", "Connection": "close"})
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
            break
        except Exception as error:
            if attempt == 2:
                print(f"Unable to check {entry['path']}: {error}", file=sys.stderr)
                sys.exit(2)
            time.sleep(0.5)
    blob = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    same = blob == entry['reviewedBlob']
    print(('same    ' if same else 'changed ')+entry['path'])
    if not same: changed.append(entry['path'])
print(f"{len(changed)} of {len(lock['trackedFiles'])} tracked files changed from reviewed head {lock['reviewedHead'][:9]}")
print('This checks source drift, not Swift behavioral compatibility.')
sys.exit(1 if changed else 0)
