#!/usr/bin/env python3
"""Build a locally signed macOS application bundle."""
import pathlib, plistlib, shutil, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
def run(*args):
    subprocess.run(["python3", str(root / "scripts/run.py"), "300", *args], cwd=root, check=True)
run("swift", "build", "-c", "release", "--jobs", "2")
bindir = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True, timeout=30).strip()
app = root / "build/CalendarBar.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(pathlib.Path(bindir) / "CalendarBar", macos / "CalendarBar")
info = {
    "CFBundleExecutable": "CalendarBar", "CFBundleIdentifier": "local.ian.CalendarBar",
    "CFBundleName": "CalendarBar", "CFBundleDisplayName": "캘린더 바",
    "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
    "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSCalendarsFullAccessUsageDescription": "선택한 캘린더의 일정을 읽어서 표시합니다. 일정을 추가하거나 수정하지 않습니다.",
    "NSCalendarsUsageDescription": "선택한 캘린더의 일정을 읽어서 표시합니다."
}
with (app / "Contents/Info.plist").open("wb") as out:
    plistlib.dump(info, out)
run("codesign", "--force", "--sign", "-", str(app))
run("codesign", "--verify", "--strict", str(app))
print(app)
