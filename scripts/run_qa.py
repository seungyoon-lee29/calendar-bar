#!/usr/bin/env python3
"""Launch an isolated QA bundle through LaunchServices, with bounded cleanup."""
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import time
from qa_preflight import launch_environment, preflight

seconds = int(sys.argv[1])
app = pathlib.Path(sys.argv[2]).resolve()
with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
if info.get('CFBundleIdentifier') not in ('local.ian.CalendarBar.qa', 'local.ian.CalendarBar.runtime.qa'):
    raise SystemExit('Only the isolated QA bundle is allowed')
binary = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])

def owned():
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=5)
    return [int(parts[0]) for line in output.splitlines()
            if len(parts := line.split(None, 1)) == 2 and parts[1] == binary]

if owned():
    raise SystemExit('QA instance already running at this path')
preflight(app, info['CFBundleIdentifier'])
launcher = subprocess.Popen(['open', '-W', str(app), '--args', *sys.argv[3:]], env=launch_environment())
code = 0
try:
    code = launcher.wait(timeout=seconds)
except (subprocess.TimeoutExpired, KeyboardInterrupt):
    code = 124
finally:
    for pid in owned():
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while owned() and time.monotonic() < deadline:
        time.sleep(0.05)
    for pid in owned():
        os.kill(pid, signal.SIGKILL)
    launcher.wait(timeout=10)
    deadline = time.monotonic() + 5
    while owned() and time.monotonic() < deadline:
        time.sleep(0.05)
    if owned():
        raise RuntimeError('QA process cleanup failed')
    print('QA_PROCESS_ABSENT', flush=True)
sys.exit(code)
