#!/usr/bin/env python3
"""Opt-in signed package acceptance, ONLY on a disposable GitHub-hosted Mac.

Installs and reinstalls the actual candidate. Never removes existing Nightr
state, repairs failed transactions, launches UI, or authorizes services.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

import nightr_install as installer

ROOT = Path(__file__).resolve().parent.parent
LINK = Path('/usr/local/bin/nightr')
STATE = installer.GLOBAL_LOCK.parent
UNTESTED = ['helper/login authorization', 'version-changing update', 'reboot recovery',
            'setup --check (production sampling deferred; no helper readiness asserted)']


def run(arguments, *, timeout=60, env=None, allowed=(0,)):
    """Bound commands and preserve their last diagnostics, including failures."""
    try:
        result = subprocess.run([str(value) for value in arguments], capture_output=True,
                                text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as error:
        for output in (error.stdout, error.stderr):
            if output:
                print((output.decode(errors='replace') if isinstance(output, bytes) else output)[-16384:], file=sys.stderr)
        raise
    for output in (result.stdout, result.stderr):
        if output: print(output[-16384:], file=sys.stderr, flush=True)
    if result.returncode not in allowed:
        raise RuntimeError(f'{arguments[0]} exited {result.returncode}')
    return result


def require_disposable(opt_in):
    expected = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS'}
    if not opt_in or sys.platform != 'darwin' or any(os.environ.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Refusing installation: explicit opt-in and a disposable GitHub-hosted macOS runner are required')


def assert_absent(path):
    try: path.lstat()
    except FileNotFoundError: return
    raise RuntimeError(f'Refusing existing Nightr state: {path}')


def require_fresh():
    for path in [installer.APP, LINK, STATE, installer.INSTALL_GUARD,
                 Path('/var/db/ai.nightr.powerhelper'),
                 Path('/Library/PrivilegedHelperTools/ai.nightr.powerhelper'),
                 Path('/Library/LaunchDaemons/ai.nightr.powerhelper.plist'),
                 Path('/Library/LaunchAgents/ai.nightr.agent.plist')]:
        assert_absent(path)
    # Query all receipts successfully: an unavailable receipt database is not
    # evidence of absence. Also refuse orphaned files under the receipt name.
    receipts = run(['/usr/sbin/pkgutil', '--pkgs']).stdout.splitlines()
    if any(name == 'ai.nightr' or name.startswith('ai.nightr.') for name in receipts):
        raise RuntimeError('Refusing existing Nightr package receipt')
    if list(Path('/var/db/receipts').glob('ai.nightr.*')):
        raise RuntimeError('Refusing existing Nightr receipt files')


def verify_root(path, mode=None, directory=False):
    metadata = path.lstat()
    correct_type = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if (metadata.st_uid != 0 or not correct_type or metadata.st_mode & 0o022 or
            (mode is not None and stat.S_IMODE(metadata.st_mode) != mode) or
            (not directory and metadata.st_nlink != 1)):
        raise RuntimeError(f'Unsafe installed ownership/type/mode: {path}')


def verify_installation(team, version):
    if installer.verify_installed_receipt(team) != version:
        raise RuntimeError('Installed version differs from the candidate')
    installer.assert_no_marker()
    # Validate every payload entry's owner, including data and bundled Python.
    for path in [installer.APP, *installer.APP.rglob('*')]:
        metadata = path.lstat()
        if metadata.st_uid != 0 or (not path.is_symlink() and metadata.st_mode & 0o022):
            raise RuntimeError(f'Unsafe installed payload ownership/mode: {path}')
        if path.is_symlink() and not path.resolve().is_relative_to(installer.APP):
            raise RuntimeError(f'Installed payload symlink escapes the app: {path}')
    metadata = LINK.lstat()
    if not stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != 0 or os.readlink(LINK) != str(installer.APP / 'Contents/MacOS/nightr'):
        raise RuntimeError('The root-owned canonical command link is missing or different')
    verify_root(installer.INSTALL_GUARD, mode=0o755)
    verify_root(STATE, mode=0o755, directory=True)
    # Public lock files intentionally permit users to take kernel locks. Their
    # exact 0666 modes are part of the guard contract, not a writable-state bug.
    for name, mode in [('update.lock', 0o666), ('controller.lock', 0o666), ('installer-guard.lock', 0o600)]:
        metadata = (STATE / name).lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != mode:
            raise RuntimeError(f'Incorrect root lock type/owner/mode: {name}')
    # A read-only launchd query provides limited setup evidence. It must report
    # absence, not contact or launch the embedded helper. setup --check calls
    # production power/network sampling, so that command remains deferred.
    status = run(['/bin/launchctl', 'print', 'system/ai.nightr.powerhelper'], allowed=(113,))
    if 'Could not find service' not in status.stderr:
        raise RuntimeError('Cannot establish that the helper remains unregistered')
    with tempfile.TemporaryDirectory(prefix='nightr-acceptance-home-') as temporary:
        env = {key: value for key, value in os.environ.items() if not key.startswith('COV_CORE_')}
        env.update(HOME=temporary, XDG_CONFIG_HOME=temporary + '/config', XDG_STATE_HOME=temporary + '/state', XDG_CACHE_HOME=temporary + '/cache')
        if run([LINK, '--version'], env=env).stdout.strip() != version:
            raise RuntimeError('Installed CLI version differs from the candidate')
        if 'nightr' not in run([LINK, '--help'], env=env).stdout.lower():
            raise RuntimeError('Installed CLI help is missing')
        run([installer.APP / 'Contents/Resources/runtime/bin/python3', '-I', '-c',
             'import ssl; print(ssl.OPENSSL_VERSION)'], env=env)


def accept(args, report):
    require_disposable(args.disposable_github_runner)
    require_fresh()
    report['preflight'] = 'passed; no existing Nightr state'
    run([sys.executable, ROOT / 'scripts/verify_release.py', '--dmg', args.dmg,
         '--team-id', args.team_id, '--version', args.version], timeout=600)
    report['artifactVerification'] = 'passed'
    with tempfile.TemporaryDirectory(prefix='nightr-acceptance-') as temporary:
        with installer.mounted_dmg(args.dmg, Path(temporary)) as mount:
            package = mount / 'Nightr.pkg'
            installer.verify_package(package, args.team_id)
            for stage in ['freshInstall', 'samePackageReinstall']:
                report[stage] = 'started'
                run(['/usr/bin/sudo', '-n', '/usr/sbin/installer', '-pkg', package, '-target', '/'], timeout=600)
                verify_installation(args.team_id, args.version)
                report[stage] = 'passed'
    report['status'] = 'passed_limited_acceptance'
    report['helperStatus'] = 'unregistered; readiness not asserted'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disposable-github-runner', action='store_true')
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'0\.[0-9]+\.[0-9]+', args.version) or not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
        parser.error('A stable version and genuine Developer ID team are required')
    report = {'schemaVersion': 1, 'status': 'failed', 'version': args.version,
              'commit': os.environ.get('GITHUB_SHA'), 'runID': os.environ.get('GITHUB_RUN_ID'),
              'freshInstall': 'untested', 'samePackageReinstall': 'untested', 'untested': UNTESTED}
    try:
        accept(args, report)
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'[-16384:]
        print(report['error'], file=sys.stderr)
        return 1
    finally:
        # Reports never clear failed root markers or delete installed state.
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    return 0


if __name__ == '__main__': raise SystemExit(main())
