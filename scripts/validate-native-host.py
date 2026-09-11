#!/usr/bin/env python3
"""Read-only native-helper composition validation; no launch/registration/TCC."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import stat

BUNDLE = 'Contents/Library/Native/Tron Native Host.app'
EXECUTABLE = BUNDLE + '/Contents/MacOS/TronNativeHost'
SERVICE = 'com.tron.mac.native-host'
CAPTURE_SERVICE = SERVICE + '.capture'
CLIENT = 'Contents/Library/Native/tron-native-capture.node'
CLIENT_INPUTS = 'Contents/Library/Native/tron-native-capture.inputs.json'
AGENT = {
    'Label': SERVICE,
    'BundleProgram': EXECUTABLE,
    'MachServices': {SERVICE: True, CAPTURE_SERVICE: True},
    'AssociatedBundleIdentifiers': ['com.tron.mac'],
    'LimitLoadToSessionType': 'Aqua',
    'RunAtLoad': True,
}


def regular(app, relative):
    path = app / relative
    for parent in [path, *path.parents]:
        if parent == app.parent:
            break
        if parent.is_symlink():
            raise ValueError('Symlink in native composition: ' + relative)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Non-regular native composition file: ' + relative)
    return path, info


def plist(app, relative):
    path, info = regular(app, relative)
    if info.st_size <= 0 or info.st_size > 65536:
        raise ValueError('Native plist outside size bound')
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError('Native plist is not a dictionary')
    return value


def validate(app):
    app = Path(app).absolute()
    agent = plist(app, 'Contents/Library/LaunchAgents/' + SERVICE + '.plist')
    if agent != AGENT or agent.get('RunAtLoad') is not True or any(agent.get('MachServices', {}).get(name) is not True for name in (SERVICE, CAPTURE_SERVICE)):
        raise ValueError('Native LaunchAgent does not match its declared Aqua Mach service')
    parent = plist(app, 'Contents/Info.plist')
    host = plist(app, BUNDLE + '/Contents/Info.plist')
    team = parent.get('TronSigningTeam')
    if not isinstance(team, str) or not re.fullmatch(r'[A-Z0-9]{10}', team) or host.get('TronSigningTeam') != team:
        raise ValueError('Native and parent signing-team metadata differ')
    if host.get('CFBundleIdentifier') != SERVICE or host.get('CFBundleExecutable') != 'TronNativeHost':
        raise ValueError('Native bundle identity/executable mismatch')
    if host.get('LSUIElement') is not True or host.get('LSBackgroundOnly') is not False:
        raise ValueError('Native helper must be an accessory Aqua application')
    # Only the explicitly placed helper is valid. Xcode's automatic embedding
    # of an application dependency can otherwise add a second Resources copy.
    for candidate in (app / 'Contents').rglob('*.app'):
        if candidate == app / BUNDLE:
            continue
        metadata = candidate / 'Contents/Info.plist'
        if metadata.exists() and plist(app, str(metadata.relative_to(app))).get('CFBundleIdentifier') == SERVICE:
            raise ValueError('Duplicate native helper bundle outside its canonical location')
    _, info = regular(app, EXECUTABLE)
    if not info.st_mode & 0o111:
        raise ValueError('Native host is not executable')
    _, client_info = regular(app, CLIENT)
    inputs, inputs_info = regular(app, CLIENT_INPUTS)
    if client_info.st_size < 1024 or not 0 < inputs_info.st_size <= 65536:
        raise ValueError('Native client artifact outside size bounds')
    with inputs.open('rb') as file:
        data = file.read(65537)
    if len(data) > 65536:
        raise ValueError('Native client artifact outside size bounds')
    metadata = json.loads(data)
    if (not isinstance(metadata, dict) or set(metadata) != {'schema', 'testOnly', 'inputs'}
            or metadata.get('schema') != 1 or metadata.get('testOnly') is not False
            or not isinstance(metadata.get('inputs'), dict) or not 1 <= len(metadata['inputs']) <= 32
            or not all(isinstance(k, str) and 0 < len(k) <= 256 and isinstance(v, str)
                       and re.fullmatch('[a-f0-9]{64}', v) for k, v in metadata['inputs'].items())):
        raise ValueError('Native client production input manifest is invalid')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    args = parser.parse_args()
    validate(Path(args.app))
    print('Native helper composition verified')
