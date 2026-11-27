#!/usr/bin/env python3
"""Install an exact signed candidate on an already identified dedicated lab Mac."""
import argparse
import contextlib
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import signal
import time
import tempfile

import nightr_install as installer


def command(arguments, timeout=30, allowed=(0,)):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode not in allowed:
        raise RuntimeError(f'{arguments[0]} failed: {result.stderr[-4096:]}')
    return result


def cdhash(app):
    output = command(['/usr/bin/codesign', '-d', '--verbose=4', app]).stderr
    match = re.search(r'^CDHash=([0-9a-f]{40}|[0-9a-f]{64})$', output, re.MULTILINE)
    if not match:
        raise RuntimeError('Candidate code directory hash is unavailable')
    return match[1]


def require_inactive():
    for name in ('NightrApp', 'nightr-native'):
        result = command(['/usr/bin/pgrep', '-x', name], allowed=(0, 1))
        if result.returncode == 0:
            raise RuntimeError('Nightr process remains after quiescing')


def quiesce(team):
    if not installer.APP.exists():
        require_inactive()
        return
    installer.verify_installed_receipt(team)
    cli = installer.APP / 'Contents/MacOS/nightr-native'
    response = json.loads(command([cli, 'status', '--json']).stdout)
    status = response.get('status')
    if not status or status['holding'] or status['state']['desiredEnabled']:
        raise RuntimeError('Lab controller must be confirmed stopped')
    command([cli, 'package', 'prepare-update'])
    for name in ('NightrApp', 'nightr-native'):
        found = command(['/usr/bin/pgrep', '-x', name], allowed=(0, 1))
        for value in found.stdout.split():
            pid = int(value)
            executable = command(['/bin/ps', '-p', str(pid), '-o', 'comm=']).stdout.strip()
            if executable != str(installer.APP / 'Contents/MacOS' / name):
                raise RuntimeError('Unexpected Nightr process path')
            os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while True:
        try:
            require_inactive()
            return True
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)


def install(args):
    if sys.platform != 'darwin':
        raise RuntimeError('Dedicated lab installation requires macOS')
    if not re.fullmatch(r'[0-9a-f]{40}', args.commit):
        raise RuntimeError('Expected a full source commit')
    command([sys.executable, Path(__file__).with_name('battery_lab_host.py'),
             'identify', '--fixture-id', args.fixture_id, '--run-id', args.run_id])
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256):
        raise RuntimeError('Expected a SHA256 digest')
    if args.dmg.is_symlink() or not args.dmg.is_file() or installer._sha256(args.dmg) != args.sha256:
        raise RuntimeError('Candidate image differs from expected digest')
    command([sys.executable, Path(__file__).with_name('verify_release.py'),
             '--dmg', args.dmg, '--team-id', args.team_id, '--version', args.version], timeout=600)
    with tempfile.TemporaryDirectory(prefix='nightr-lab-install-') as temporary:
        with installer.mounted_dmg(args.dmg, Path(temporary)) as mount:
            candidate = mount / 'Nightr.app'
            installer.verify_app(candidate, args.team_id, args.version)
            with (candidate / 'Contents/Info.plist').open('rb') as source:
                if plistlib.load(source).get('NightrSourceRevision') != args.commit:
                    raise RuntimeError('Candidate source revision differs from requested commit')
            expected = cdhash(candidate)
            same = False
            if installer.APP.exists():
                installer.verify_installed_receipt(args.team_id)
                same = cdhash(installer.APP) == expected
            installer.verify_package(mount / 'Nightr.pkg', args.team_id)
            previously_stopped = quiesce(args.team_id)
            try:
                if not same:
                    require_inactive()
                    prefix = [] if os.geteuid() == 0 else ['/usr/bin/sudo', '-n', '--']
                    command([*prefix, '/usr/sbin/installer', '-pkg', mount / 'Nightr.pkg', '-target', '/'], timeout=180)
                if installer.verify_installed_receipt(args.team_id) != args.version:
                    raise RuntimeError('Installed receipt differs from candidate version')
                installer.verify_app(installer.APP, args.team_id, args.version)
                if cdhash(installer.APP) != expected:
                    raise RuntimeError('Installed application differs from candidate')
                installer.assert_no_marker()
            except Exception:
                if previously_stopped:
                    try:
                        installer.verify_installed_receipt(args.team_id)
                        installer.assert_no_marker()
                        command([installer.APP / 'Contents/MacOS/nightr-native', 'package', 'finish-update'])
                    except Exception as recovery_error:
                        print(f'Lab controller recovery failed: {recovery_error}', file=sys.stderr)
                raise
    command([installer.APP / 'Contents/MacOS/nightr-native', 'package', 'finish-update'])
    status = json.loads(command([installer.APP / 'Contents/MacOS/nightr-native', 'status', '--json']).stdout).get('status')
    if not status or status['holding'] or status['state']['desiredEnabled']:
        raise RuntimeError('Installed lab controller is not confirmed stopped')
    pid = command(['/usr/bin/pgrep', '-x', 'NightrApp']).stdout.strip()
    if not pid.isdigit() or command(['/bin/ps', '-p', pid, '-o', 'comm=']).stdout.strip() != str(installer.APP / 'Contents/MacOS/NightrApp'):
        raise RuntimeError('Running controller identity is unavailable')
    return {'cdhash': expected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dmg', required=True, type=Path)
    for name in ('team-id', 'version', 'commit', 'sha256', 'fixture-id', 'run-id'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            result = install(args)
        print(json.dumps(result))
        return 0
    except Exception as error:
        print(f'Lab candidate installation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
