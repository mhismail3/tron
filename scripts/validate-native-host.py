#!/usr/bin/env python3
"""Read-only native-helper composition validation; no launch/registration/TCC."""
import argparse
from pathlib import Path
import plistlib
import re
import stat

BUNDLE = 'Contents/Library/Native/Tron Native Host.app'
EXECUTABLE = BUNDLE + '/Contents/MacOS/TronNativeHost'
SERVICE = 'com.tron.mac.native-host'
AGENT = {
    'Label': SERVICE,
    'BundleProgram': EXECUTABLE,
    'MachServices': {SERVICE: True},
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
    if agent != AGENT or agent.get('RunAtLoad') is not True or agent.get('MachServices', {}).get(SERVICE) is not True:
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
    _, info = regular(app, EXECUTABLE)
    if not info.st_mode & 0o111:
        raise ValueError('Native host is not executable')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    args = parser.parse_args()
    validate(Path(args.app))
    print('Native helper composition verified')
