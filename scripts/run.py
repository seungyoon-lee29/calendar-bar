#!/usr/bin/env python3
"""Run a command with a deadline and clean up its process group."""
import os
import signal
import subprocess
import sys
import time


def signal_group(group, sig):
    try:
        os.killpg(group, sig)
        return True
    except ProcessLookupError:
        return False


def cleanup(process):
    # The group can outlive its leader, including after a successful exit.
    if signal_group(process.pid, signal.SIGTERM):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            process.poll()  # Reap the leader so it cannot keep the group alive.
            if not signal_group(process.pid, 0):
                break
            time.sleep(0.05)
        else:
            signal_group(process.pid, signal.SIGKILL)
    process.wait()


seconds = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    code = process.wait(timeout=seconds)
except (subprocess.TimeoutExpired, KeyboardInterrupt):
    code = 124
finally:
    cleanup(process)
sys.exit(code)
