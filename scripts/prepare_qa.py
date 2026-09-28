#!/usr/bin/env python3
"""Copy the built app into an isolated, ad-hoc signed synthetic QA bundle."""
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
app = root / "build/CalendarBarQA.app"
if app.exists():
    raise SystemExit("QA bundle already exists; choose a fresh build directory or remove only the old QA copy after quitting it")
shutil.copytree(root / "build/CalendarBar.app", app)
info_path = app / "Contents/Info.plist"
with info_path.open("rb") as source:
    info = plistlib.load(source)
info.update(CFBundleIdentifier="local.ian.CalendarBar.qa", CFBundleName="Calendar Bar QA", CFBundleDisplayName="Calendar Bar QA")
with info_path.open("wb") as destination:
    plistlib.dump(info, destination)
for command in (
    ["codesign", "--force", "--sign", "-", str(app)],
    ["codesign", "--verify", "--strict", str(app)],
):
    subprocess.run(["python3", str(root / "scripts/run.py"), "120", *command], check=True)
print(app)
