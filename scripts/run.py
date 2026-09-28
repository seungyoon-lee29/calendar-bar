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
    except PermissionError:
        # Some macOS launch environments report EPERM for an already empty
        # group. Verify independently; a live inaccessible group remains an error.
        inventory = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="],
                                   capture_output=True, text=True, timeout=5, check=True)
        if any(len(row.split()) >= 2 and int(row.split()[1]) == group
               for row in inventory.stdout.splitlines()):
            raise
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
    deadline = time.monotonic() + 5
    while signal_group(process.pid, 0):
        if time.monotonic() >= deadline:
            raise RuntimeError("process group cleanup could not be verified")
        time.sleep(0.05)


def main():
    seconds = int(sys.argv[1])
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    try:
        code = process.wait(timeout=seconds)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        code = 124
    finally:
        cleanup(process)
    sys.exit(code)


if __name__ == "__main__":
    main()
