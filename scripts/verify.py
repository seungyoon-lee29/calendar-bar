#!/usr/bin/env python3
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
for command in (["swift", "test", "--jobs", "2"], ["python3", "-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_run.py"], ["python3", "scripts/build.py"]):
    result = subprocess.run(["python3", "scripts/run.py", "600", *command], cwd=root)
    print("VERIFY", command, "EXIT", result.returncode, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
