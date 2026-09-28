#!/usr/bin/env python3
"""Regression tests using isolated process groups; no app or account access."""
import os
import importlib.util
from unittest.mock import patch
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = pathlib.Path(__file__).with_name("run.py")
CHILD = """
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(__import__('os').getpid()))
time.sleep(60)
"""
PARENT = """
import os, pathlib, subprocess, sys, time
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
subprocess.Popen([sys.executable, '-c', sys.argv[3], sys.argv[2]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
while not pathlib.Path(sys.argv[2]).exists():
    time.sleep(0.01)
if sys.argv[4] == 'timeout':
    time.sleep(60)
print('parent output', flush=True)
sys.exit(int(sys.argv[4]))
"""

def alive(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, timeout=5)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


class GroupProbeTests(unittest.TestCase):
    def load_runner(self):
        spec = importlib.util.spec_from_file_location("bounded_runner", RUNNER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_permission_error_is_absent_only_with_empty_process_inventory(self):
        runner = self.load_runner()
        inventory = subprocess.CompletedProcess([], 0, "  10 10 S\n", "")
        with patch.object(runner.os, "killpg", side_effect=PermissionError(1, "denied")), patch.object(runner.subprocess, "run", return_value=inventory):
            self.assertFalse(runner.signal_group(12345, 0))

    def test_permission_error_for_existing_group_is_reported(self):
        runner = self.load_runner()
        inventory = subprocess.CompletedProcess([], 0, "12346 12345 S\n", "")
        with patch.object(runner.os, "killpg", side_effect=PermissionError(1, "denied")), patch.object(runner.subprocess, "run", return_value=inventory):
            with self.assertRaises(PermissionError):
                runner.signal_group(12345, signal.SIGTERM)


class RunnerTests(unittest.TestCase):
    def check_cleanup(self, mode, expected):
        with tempfile.TemporaryDirectory() as directory:
            parent_path = pathlib.Path(directory) / "parent"
            child_path = pathlib.Path(directory) / "child"
            try:
                result = subprocess.run(
                    [sys.executable, str(RUNNER), "1" if mode == "timeout" else "10",
                     sys.executable, "-c", PARENT, str(parent_path), str(child_path), CHILD, mode],
                    capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stderr)
                child = int(child_path.read_text())
                deadline = time.monotonic() + 2
                while alive(child) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertFalse(alive(child), "runner left a SIGTERM-ignoring descendant alive")
                if mode != "timeout":
                    self.assertIn("parent output", result.stdout)
            finally:
                if parent_path.exists():
                    try:
                        os.killpg(int(parent_path.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if child_path.exists():
                    child = int(child_path.read_text())
                    deadline = time.monotonic() + 2
                    while alive(child) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertFalse(alive(child), "test cleanup failed")

    def test_timeout_cleans_descendant_even_when_parent_exits_on_sigterm(self):
        self.check_cleanup("timeout", 124)

    def test_successful_parent_exit_cleans_descendant(self):
        self.check_cleanup("0", 0)

    def test_failed_parent_exit_preserves_exit_code_and_cleans_descendant(self):
        self.check_cleanup("7", 7)


if __name__ == "__main__":
    unittest.main()
