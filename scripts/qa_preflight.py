"""QA launch identity checks; inventory reads only public NSWorkspace APIs."""
import json
import pathlib
import subprocess
import sys


def inventory(bundle_id):
    scripts = pathlib.Path(__file__).resolve().parent
    result = subprocess.run(
        [sys.executable, str(scripts / 'run.py'), '30', 'swift',
         str(scripts / 'qa_inventory.swift'), bundle_id],
        check=True, capture_output=True, text=True, timeout=45)
    return json.loads(result.stdout)


def validate(app, state, allow_unregistered=False):
    expected = pathlib.Path(app).resolve()
    candidates = {pathlib.Path(path).resolve() for path in state['candidates']}
    if candidates - {expected}:
        raise RuntimeError('Another application path has the same QA bundle identifier; quit and unregister that exact QA copy first')
    if state['running']:
        raise RuntimeError('A QA instance with this bundle identifier is already running')
    if not candidates and not allow_unregistered:
        raise RuntimeError('QA bundle registration could not be verified')
    return bool(candidates)


def preflight(app, bundle_id, query=inventory, register=None):
    if validate(app, query(bundle_id), allow_unregistered=True):
        return
    if register is None:
        def register(path):
            subprocess.run([
                '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                '-f', str(path)], check=True, timeout=15)
    register(app)
    validate(app, query(bundle_id))
