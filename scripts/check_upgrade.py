#!/usr/bin/env python3
"""Disposable GitHub-hosted macOS acceptance of a real signed managed upgrade.

No workflow integration or release publication. Never run on a developer Mac.
Only candidate acquisition and sudo's no-prompt option differ from production.
Controller resume, helper/login authorization and recovery are not exercised.
"""
from __future__ import annotations

import argparse
import errno
import importlib.util
import json
import os
from pathlib import Path
import pty
import pwd
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import check_installer as checks

UNTESTED = ['public HTTPS acquisition', 'controller finish-update/resume',
            'helper/login authorization', 'rollback/reboot recovery']


def require_runner(opt_in):
    checks.require_disposable(opt_in)
    uid = os.getuid()
    home = Path(pwd.getpwuid(uid).pw_dir)
    if uid == 0 or os.geteuid() != uid or os.environ.get('HOME') != str(home) or Path.home() != home:
        raise RuntimeError('Acceptance requires the real nonroot runner UID and passwd HOME')
    return home


def load_candidate(manifest_path, image, version):
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > 1024 * 1024:
        raise RuntimeError('Candidate manifest must be a bounded regular file')
    data = checks.installer.validate_manifest(json.loads(manifest_path.read_text()))
    if data['version'] != version:
        raise RuntimeError('Candidate version differs from the required acceptance version')
    if image.is_symlink() or not image.is_file() or image.stat().st_size != data['asset']['size']:
        raise RuntimeError('Retained candidate size/type differs from its manifest')
    if checks.installer._sha256(image) != data['asset']['sha256']:
        raise RuntimeError('Retained candidate checksum differs from its manifest')
    return data


def candidate_download(candidates):
    """The sole acquisition substitute: exact URLs, bounded retained bytes."""
    def download(url, target, maximum):
        if url not in candidates:
            raise RuntimeError('Unexpected acquisition URL; no network fallback is permitted')
        image = candidates[url]
        total = 0
        with image.open('rb') as source, Path(target).open('wb') as output:
            while block := source.read(1024 * 1024):
                total += len(block)
                if total > maximum:
                    raise RuntimeError('Retained candidate exceeds the production download limit')
                output.write(block)
        return total
    return download


def owned_private(path, directory=False):
    metadata = path.lstat()
    kind = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not kind or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != (0o700 if directory else 0o600):
        raise RuntimeError(f'Incorrect nonroot private state ownership/type/mode: {path.name}')
    if not directory and metadata.st_nlink != 1:
        raise RuntimeError('Private state must have one link')


class NoPromptSubprocess:
    """Module-local proxy; signature checks and every subprocess still execute."""
    def __init__(self, module, report):
        self.module = module
        self.report = report

    def __getattr__(self, name):
        return getattr(subprocess, name)

    def run(self, arguments, **kwargs):
        arguments = [str(value) for value in arguments]
        if arguments and arguments[0] == '/usr/bin/sudo':
            if arguments[:2] != ['/usr/bin/sudo', '--']:
                raise RuntimeError('Unexpected production sudo prefix')
            command = arguments[2:]
            if (len(command) == 5 and command[0] == '/usr/sbin/installer' and
                    command[1] == '-pkg' and command[3:] == ['-target', '/']):
                request = self.module.state_directory() / 'install-request.json'
                owned_private(request)
                if request.stat().st_size > 16384:
                    raise RuntimeError('Managed request exceeds the production size limit')
                data = json.loads(request.read_text())
                identity = self.module.current_process_identity()
                if (data.get('schemaVersion') != 1 or data.get('owner') != identity or data.get('packagePath') != command[2] or
                        data.get('version') != '0.1.0' or data.get('originalVersion') != '0.0.0' or
                        data.get('operation') != 'install' or data.get('teamID') != self.report['teamID']):
                    raise RuntimeError('Managed request does not bind this nonroot process and upgrade')
                uuid.UUID(data['transaction'])
                self.report['requestProvenance'] = {'uid': identity['uid'], 'pid': identity['pid'],
                                                     'transaction': data['transaction'], 'verified': True}
            elif (len(command) == 3 and command[0] == str(self.module.INSTALL_GUARD) and
                  command[1] == 'finish' and command[2] == self.report.get('requestProvenance', {}).get('transaction')):
                pass
            else:
                raise RuntimeError('Unexpected privileged target or transaction; acceptance stops')
            arguments.insert(1, '-n')
        try:
            return subprocess.run(arguments, **kwargs)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            for output in (error.stdout, error.stderr):
                if output:
                    print((output.decode(errors='replace') if isinstance(output, bytes) else output)[-16384:], file=sys.stderr)
            raise


def verify_user_state(module, baseline, final, result, report):
    directory = module.state_directory()
    owned_private(directory, directory=True)
    for name in ['installation.json', 'package.lock']:
        owned_private(directory / name)
    owned_private(directory / 'packages', directory=True)
    if (result != module.read_record() or result['owner'] != 'direct' or result['version'] != final['version'] or
            result['teamID'] != final['teamID'] or result['artifactSHA256'] != final['asset']['sha256']):
        raise RuntimeError('The actual ownership record does not describe the managed upgrade')
    for manifest in [baseline, final]:
        cached = directory / 'packages' / manifest['asset']['name']
        owned_private(cached)
        if cached.stat().st_size != manifest['asset']['size'] or module._sha256(cached) != manifest['asset']['sha256']:
            raise RuntimeError('Actual rollback or upgraded cache does not match its manifest')
    checks.assert_absent(directory / 'install-request.json')
    if not report.get('requestProvenance', {}).get('verified'):
        raise RuntimeError('No actual managed request was observed')
    # Reacquire all three production locks after the update releases them.
    with module.installation_lock() as held:
        if not isinstance(held, module.PackageLockHandle) or not held.held:
            raise RuntimeError('Machine update lock was not reacquired')
        with module.global_installation_lock(required=True, path=module.CONTROLLER_LOCK):
            pass
    report['userState'] = 'verified nonroot record, old/new cache digests, removed request, reacquirable locks'


def accept(args, report):
    home = require_runner(args.disposable_github_runner)
    if not sys.stdin.isatty():
        raise RuntimeError('The managed coordinator requires a real PTY')
    checks.require_fresh()
    checks.assert_absent(home / 'Library/Application Support/Nightr')
    baseline = load_candidate(args.baseline_manifest, args.baseline_dmg, '0.0.0')
    final = load_candidate(args.final_manifest, args.final_dmg, '0.1.0')
    if baseline['teamID'] != args.team_id or final['teamID'] != args.team_id:
        raise RuntimeError('Candidate signing team differs from the independently configured team')
    report['teamID'] = args.team_id
    checks.run(['/usr/bin/sudo', '-n', '/usr/bin/true'])
    for manifest, image in [(baseline, args.baseline_dmg), (final, args.final_dmg)]:
        checks.run([sys.executable, checks.ROOT / 'scripts/verify_release.py', '--dmg', image,
                    '--team-id', manifest['teamID'], '--version', manifest['version']], timeout=600)
    report['artifactVerification'] = 'passed both retained signed DMGs and manifests'
    with tempfile.TemporaryDirectory(prefix='nightr-baseline-') as temporary:
        with checks.installer.mounted_dmg(args.baseline_dmg, Path(temporary)) as mount:
            checks.installer.verify_package(mount / 'Nightr.pkg', baseline['teamID'])
            report['baselineInstall'] = 'started'
            checks.run(['/usr/bin/sudo', '-n', '/usr/sbin/installer', '-verboseR', '-pkg', mount / 'Nightr.pkg', '-target', '/'], timeout=600)
    checks.verify_installation(baseline['teamID'], baseline['version'])
    report['baselineInstall'] = 'passed'
    # Only execute the module from the now verified root-owned signed baseline.
    path = checks.installer.APP / 'Contents/Resources/libexec/nightr_install.py'
    spec = importlib.util.spec_from_file_location('nightr_signed_baseline_installer', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.download = candidate_download({baseline['asset']['url']: args.baseline_dmg,
                                          final['asset']['url']: args.final_dmg})
    module.subprocess = NoPromptSubprocess(module, report)
    baseline = module.validate_manifest(baseline)
    final = module.validate_manifest(final)
    report['baselineAdoption'] = 'started'
    with module.installation_lock(), tempfile.TemporaryDirectory(prefix='nightr-adopt-') as temporary:
        adopted = module.adopt_direct(baseline, Path(temporary), explicit_claim=True)
    if adopted['version'] != baseline['version'] or adopted['owner'] != 'direct':
        raise RuntimeError('Actual baseline adoption failed')
    report['baselineAdoption'] = 'passed explicit production adoption'
    deferred = []
    report['managedUpgrade'] = 'started'
    with module.installation_lock() as held, tempfile.TemporaryDirectory(prefix='nightr-upgrade-') as temporary:
        if not isinstance(held, module.PackageLockHandle) or not held.held:
            raise RuntimeError('Managed upgrade requires the actual machine update lock')
        result = module.perform('update', final, Path(temporary), global_lock_held=held, resume_after_unlock=deferred)
    if deferred != ['finish-update']:
        raise RuntimeError('Expected production controller resume was not deferred')
    report['deferredActions'] = deferred
    checks.verify_installation(final['teamID'], final['version'])
    verify_user_state(module, baseline, final, result, report)
    report['managedUpgrade'] = 'passed 0.0.0 to 0.1.0; protected finish completed'
    report['status'] = 'passed_limited_acceptance'


def run_pty(command, timeout=1800):
    master, slave = pty.openpty()
    process = None
    tail = b''
    try:
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                                   env={key: value for key, value in os.environ.items() if not key.startswith('COV_CORE_')})
        os.close(slave)
        slave = -1
        deadline = time.monotonic() + timeout
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError('Disposable upgrade acceptance exceeded its outer deadline; do not retry or clear pending state. ' + tail[-16384:].decode(errors='replace'))
            if select.select([master], [], [], min(1, max(0, deadline - time.monotonic())))[0]:
                try: block = os.read(master, 8192)
                except OSError as error:
                    if error.errno != errno.EIO: raise
                    break
                if not block: break
                tail = (tail + block)[-65536:]
                sys.stderr.buffer.write(block)
                sys.stderr.buffer.flush()
            elif process.poll() is not None:
                break
        return process.wait(timeout=10), tail.decode(errors='replace')
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        os.close(master)
        if slave >= 0: os.close(slave)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disposable-github-runner', action='store_true')
    parser.add_argument('--team-id', required=True, help='Independent expected Developer ID team (not derived from candidate manifests)')
    for name in ['baseline-manifest', 'baseline-dmg', 'final-manifest', 'final-dmg', 'report']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--_worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    report = {'schemaVersion': 1, 'status': 'failed', 'baselineInstall': 'untested', 'managedUpgrade': 'untested',
              'commit': os.environ.get('GITHUB_SHA'), 'runID': os.environ.get('GITHUB_RUN_ID'), 'untested': UNTESTED}
    try:
        if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
            raise RuntimeError('A configured 10-character Developer ID team is required')
        require_runner(args.disposable_github_runner)
        if args._worker:
            accept(args, report)
        else:
            # Replace stale evidence before spawning; a timeout cannot inherit a
            # previous run's successful stage claims.
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n')
            code, tail = run_pty([sys.executable, str(Path(__file__).resolve()), *(argv if argv is not None else sys.argv[1:]), '--_worker'])
            if args.report.is_file(): report = json.loads(args.report.read_text())
            if code != 0:
                report['diagnosticTail'] = tail[-16384:]
                raise RuntimeError(f'Disposable PTY worker exited {code}')
            if report.get('status') != 'passed_limited_acceptance':
                raise RuntimeError('Worker did not produce a successful limited-acceptance report')
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'[-16384:]
        print(report['error'], file=sys.stderr)
        return 1
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    return 0


if __name__ == '__main__': raise SystemExit(main())
