#!/usr/bin/env python3
"""Retain signed products and existing Apple submission IDs; never resubmit pending work.

Only trusted checked-out build tooling runs. Checkpoint products are data inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
import unicodedata
import zipfile

REPOSITORY = 'agenthangar/nightr'
WORKFLOW = '.github/workflows/release.yml'
PRODUCTS = {'app': 'Nightr.zip', 'guard': 'ai.nightr.installguard', 'package': 'Nightr.pkg', 'dmg': 'submitted.dmg'}
LOGS = {phase + '-notary.log' for phase in ['app', 'package', 'dmg']}
ALLOWLIST = {'checkpoint.json', *PRODUCTS.values(), *LOGS}
MAX_PRODUCT = 3 * 1024**3


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def bounded_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise RuntimeError('Checkpoint metadata must be a bounded regular file')
    return json.loads(path.read_text())


def context(version, team):
    values = {'sourceSHA': os.environ.get('GITHUB_SHA', ''), 'producerRunID': os.environ.get('GITHUB_RUN_ID', ''),
              'repository': os.environ.get('GITHUB_REPOSITORY', ''), 'workflow': WORKFLOW,
              'version': version, 'teamID': team}
    if (values['repository'] != REPOSITORY or not re.fullmatch(r'[0-9a-f]{40}', values['sourceSHA']) or
            not re.fullmatch(r'[0-9]+', values['producerRunID']) or not re.fullmatch(r'0\.[0-9]+\.[0-9]+', version) or
            not re.fullmatch(r'[A-Z0-9]{10}', team) or os.environ.get('GITHUB_REF') != 'refs/heads/main'):
        raise RuntimeError('Checkpoint requires a main-dispatch GitHub run with exact source/version/team identity')
    return values


class Checkpoint:
    def __init__(self, directory, version, team, *, resume_run_id=None):
        self.directory = directory
        expected = context(version, team)
        if resume_run_id:
            self.data = bounded_json(directory / 'checkpoint.json')
            for key, value in expected.items():
                required = str(resume_run_id) if key == 'producerRunID' else value
                if self.data.get(key) != required:
                    raise RuntimeError(f'Checkpoint provenance differs: {key}')
            self.validate()
            self.data['producerRunID'] = expected['producerRunID']
            self.save()
        else:
            if directory.exists() and any(directory.iterdir()):
                raise RuntimeError('Refusing an existing checkpoint without an explicit resume run')
            directory.mkdir(parents=True, exist_ok=True)
            self.data = {'schemaVersion': 1, **expected, 'phase': 'build', 'products': {}, 'submissions': {}}
            self.save()

    def save(self):
        payload = json.dumps(self.data, indent=2, sort_keys=True) + '\n'
        if len(payload.encode()) > 65536: raise RuntimeError('Checkpoint metadata exceeds its limit')
        fd, temporary = tempfile.mkstemp(prefix='.checkpoint-', dir=self.directory)
        try:
            with os.fdopen(fd, 'w') as output:
                output.write(payload); output.flush(); os.fsync(output.fileno())
            os.replace(temporary, self.directory / 'checkpoint.json')
        finally:
            if os.path.exists(temporary): os.unlink(temporary)

    def validate(self):
        if (self.data.get('schemaVersion') != 1 or self.data.get('phase') not in ['build', 'app', 'package', 'dmg'] or
                not isinstance(self.data.get('products'), dict) or not isinstance(self.data.get('submissions'), dict)):
            raise RuntimeError('Invalid checkpoint schema')
        for path in self.directory.iterdir():
            if path.name not in ALLOWLIST or path.is_symlink() or not path.is_file() or (path.name in LOGS and path.stat().st_size > 32768):
                raise RuntimeError('Unexpected checkpoint entry')
        for kind, item in self.data['products'].items():
            if kind not in PRODUCTS or not isinstance(item, dict) or item.get('name') != PRODUCTS[kind]:
                raise RuntimeError('Unexpected checkpoint product')
            path = self.directory / item['name']
            if (path.is_symlink() or not path.is_file() or not isinstance(item.get('size'), int) or
                    not 0 < item['size'] <= MAX_PRODUCT or path.stat().st_size != item['size'] or
                    not re.fullmatch(r'[0-9a-f]{64}', item.get('sha256', '')) or digest(path) != item['sha256']):
                raise RuntimeError('Checkpoint product size/digest differs')
        for phase, item in self.data['submissions'].items():
            if phase not in ['app', 'package', 'dmg'] or phase not in self.data['products'] or not isinstance(item, dict):
                raise RuntimeError('Invalid checkpoint submission')
            if item.get('status') not in ['submission_unknown', 'pending', 'Accepted', 'Invalid', 'Rejected']:
                raise RuntimeError('Invalid checkpoint submission status')
            if item['status'] != 'submission_unknown': uuid.UUID(item['id'])
        expected_files = {'checkpoint.json', *(item['name'] for item in self.data['products'].values()), *LOGS}
        if any(path.name not in expected_files for path in self.directory.iterdir()):
            raise RuntimeError('Unrecorded checkpoint product')
        if self.data['products'] and not {'app', 'guard'} <= self.data['products'].keys():
            raise RuntimeError('Checkpoint lacks the signed app or installer guard')
        if 'dmg' in self.data['products'] and 'package' not in self.data['products']:
            raise RuntimeError('Checkpoint DMG lacks its package')

    def path(self, kind):
        return self.directory / PRODUCTS[kind]

    def has(self, kind):
        return kind in self.data['products']

    def retain(self, kind, source):
        target = self.path(kind)
        if self.has(kind):
            if digest(source) != self.data['products'][kind]['sha256']:
                raise RuntimeError('Refusing to replace submitted product bytes')
            return target
        if source.is_symlink() or not source.is_file() or not 0 < source.stat().st_size <= MAX_PRODUCT:
            raise RuntimeError('Signed product must be a bounded regular file')
        shutil.copy2(source, target)
        self.data['products'][kind] = {'name': target.name, 'size': target.stat().st_size, 'sha256': digest(target)}
        self.save()
        return target

    def notarize(self, phase, profile, run):
        """Persist an ID before waiting. Unknown outcomes never submit again."""
        path = self.path(phase)
        self.data['phase'] = phase
        submission = self.data['submissions'].get(phase)
        if submission is None:
            submission = {'status': 'submission_unknown'}
            self.data['submissions'][phase] = submission
            self.save()  # If upload or JSON parsing fails, reconciliation is required.
            reply = json.loads(run('/usr/bin/xcrun', 'notarytool', 'submit', path,
                                   '--keychain-profile', profile, '--output-format', 'json', timeout=300))
            identifier = str(uuid.UUID(reply['id']))
            submission.update(id=identifier, status='pending')
            self.save()
        elif submission['status'] == 'submission_unknown':
            raise RuntimeError('Notary submission outcome unknown; reconcile Apple history before retrying')
        identifier = submission['id']
        print(f'Waiting for existing {phase} notary submission {identifier}', flush=True)
        try:
            reply = json.loads(run('/usr/bin/xcrun', 'notarytool', 'wait', identifier,
                                   '--keychain-profile', profile, '--timeout', '25m', '--output-format', 'json', timeout=1560))
        except (subprocess.SubprocessError, ValueError):
            # A bounded wait failure does not authorize a fresh upload. info may
            # distinguish a rejection from an ordinary still-pending timeout.
            try:
                reply = json.loads(run('/usr/bin/xcrun', 'notarytool', 'info', identifier,
                                       '--keychain-profile', profile, '--output-format', 'json', timeout=60))
            except (subprocess.SubprocessError, ValueError):
                self.save()
                raise RuntimeError(f'Notarization pending/unavailable: {identifier}; checkpoint retained')
        if reply.get('id', identifier).lower() != identifier.lower():
            raise RuntimeError('Apple returned a different submission ID')
        status = reply.get('status')
        if status not in ['Accepted', 'Invalid', 'Rejected']:
            submission['status'] = 'pending'
            self.save()
            raise RuntimeError(f'Notarization pending: {identifier}; resume this submission')
        submission['status'] = status
        self.save()
        log = run('/usr/bin/xcrun', 'notarytool', 'log', identifier, '--keychain-profile', profile, timeout=60)
        if len(log.encode()) > 4 * 1024 * 1024:
            raise RuntimeError('Notary log exceeds bounded input limit; Accepted state and original submission are retained')
        parsed = json.loads(log)
        # Accepted logs may enumerate hundreds of Python Mach-O tickets. Keep
        # their binding fields and counts without turning large logs into a
        # rejection or retaining an unbounded diagnostic artifact.
        retained = log if len(log.encode()) <= 32768 else json.dumps({
            'jobId': str(parsed.get('jobId', ''))[:128], 'sha256': str(parsed.get('sha256', ''))[:128],
            'status': str(parsed.get('status', status))[:128], 'statusCode': str(parsed.get('statusCode', ''))[:128],
            'statusSummary': str(parsed.get('statusSummary', ''))[:2000],
            'archiveFilename': str(parsed.get('archiveFilename', ''))[:256],
            'ticketCount': len(parsed.get('ticketContents') or []), 'issueCount': len(parsed.get('issues') or []),
            'diagnostics': 'Compact summary: complete Apple log exceeded retained diagnostic limit.'
        }, indent=2)
        (self.directory / (phase + '-notary.log')).write_text(retained)
        if (parsed.get('jobId', identifier).lower() != identifier.lower() or
                parsed.get('sha256', self.data['products'][phase]['sha256']).lower() != self.data['products'][phase]['sha256']):
            raise RuntimeError('Apple notary log differs from the exact submitted product')
        if status != 'Accepted': raise RuntimeError(f'Notarization {status}: {identifier}; see retained log')


def validate_app_zip(path):
    """Check every entry before ditto handles signed-bundle metadata."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000 or sum(item.file_size for item in entries) > 8 * 1024**3:
            raise RuntimeError('App archive exceeds extraction limits')
        names, links, aliases = set(), {}, set()
        def equivalent(name):
            return unicodedata.normalize('NFD', name).casefold()
        for item in entries:
            name = item.filename.rstrip('/')
            parts = PurePosixPath(name).parts
            if (not parts or parts[0] not in ['Nightr.app', '__MACOSX'] or '..' in parts or
                    name.startswith('/') or '\\' in name or equivalent(name) in aliases or '\x00' in name or str(PurePosixPath(name)) != name):
                raise RuntimeError('Unsafe app archive path')
            names.add(name)
            aliases.add(equivalent(name))
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                if item.file_size > 4096: raise RuntimeError('Oversized app symlink')
                target = archive.read(item).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if target.startswith('/') or '\\' in target or not resolved.startswith('Nightr.app/'):
                    raise RuntimeError('App archive symlink escapes its bundle')
                links[equivalent(name)] = target
            elif stat.S_IFMT(mode) not in [0, stat.S_IFREG, stat.S_IFDIR]:
                raise RuntimeError('Unsupported app archive entry')
        if any(any(equivalent(str(parent)) in links for parent in PurePosixPath(name).parents) for name in names):
            raise RuntimeError('App archive entry descends through a symlink')
        for name in names:
            if equivalent(name) not in links: continue
            todo, resolved, hops = list(PurePosixPath(name).parts), [], 0
            while todo:
                part = todo.pop(0)
                if part == '.': continue
                if part == '..':
                    if not resolved: raise RuntimeError('App symlink resolution escapes extraction root')
                    resolved.pop()
                    continue
                resolved.append(part)
                current = equivalent('/'.join(resolved))
                if current in links:
                    hops += 1
                    if hops > 40: raise RuntimeError('App symlink cycle or excessive nesting')
                    resolved.pop()
                    todo = list(PurePosixPath(links[current]).parts) + todo
            if not resolved or equivalent(resolved[0]) != equivalent('Nightr.app'):
                raise RuntimeError('App symlink chain escapes its bundle')



def verify_restored(app, guard, team, version, run):
    from nightr_install import BUNDLE_ID
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleShortVersionString') != version or info.get('NightrTeamID') != team:
        raise RuntimeError('Restored signed app identity/version differs')
    targets = [(app, 'ai.nightr.app'), (guard, 'ai.nightr.installguard')]
    targets += [(app / 'Contents/MacOS' / name, identifier) for name, identifier in [
        ('nightr-native', 'ai.nightr.controller'), ('nightr-powerhelper', 'ai.nightr.powerhelper'), ('NightrNetworkWorker', 'ai.nightr.networkworker')]]
    for path, identifier in targets:
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R=' + requirement, path)
        executable = app / 'Contents/MacOS/NightrApp' if path == app else path
        if sorted(run('/usr/bin/lipo', '-archs', executable).split()) != ['arm64', 'x86_64']:
            raise RuntimeError('Restored executable is not universal')
    for arch in ['arm64', 'x86_64']:
        run('/usr/bin/codesign', '--verify', '--strict', '--all-architectures', f'-R=anchor apple generic and certificate leaf[subject.OU] = "{team}"',
            app / 'Contents/Resources/runtime' / arch / 'bin/python3')
        if run('/usr/bin/lipo', '-archs', app / 'Contents/Resources/runtime' / arch / 'bin/python3').split() != [arch]:
            raise RuntimeError('Restored bundled runtime architecture differs')


def verify_package(path, team, version, run):
    import xml.etree.ElementTree as ET
    output = run('/usr/sbin/pkgutil', '--check-signature', path)
    if not re.search(r'Developer ID Installer: [^\n]+ \(' + re.escape(team) + r'\)', output):
        raise RuntimeError('Restored package signing team differs')
    with tempfile.TemporaryDirectory(prefix='nightr-checkpoint-pkg-') as temporary:
        expanded = Path(temporary) / 'expanded'
        run('/usr/sbin/pkgutil', '--expand-full', path, expanded, timeout=120)
        info = ET.parse(expanded / 'PackageInfo').getroot()
        if info.get('identifier') != 'ai.nightr.package' or info.get('version') != version:
            raise RuntimeError('Restored package identity/version differs')
        verify_restored(expanded / 'Payload/Applications/Nightr.app', expanded / 'Payload/Library/PrivilegedHelperTools/ai.nightr.installguard', team, version, run)
        requirement = f'anchor apple generic and identifier "ai.nightr.installguard" and certificate leaf[subject.OU] = "{team}"'
        run('/usr/bin/codesign', '--verify', '--strict', '--all-architectures', '-R=' + requirement, expanded / 'Scripts/ai.nightr.installguard')
        if digest(expanded / 'Scripts/ai.nightr.installguard') != digest(expanded / 'Payload/Library/PrivilegedHelperTools/ai.nightr.installguard'):
            raise RuntimeError('Restored package guards differ')


def verify_run(run, workflow, artifact, version, run_id, sha):
    expected_name = f'nightr-checkpoint-{version}-{sha}-{run_id}'
    if (run.get('id') != int(run_id) or run.get('workflow_id') != workflow.get('id') or
            workflow.get('path') != WORKFLOW or run.get('path') != WORKFLOW or
            run.get('event') != 'workflow_dispatch' or run.get('head_branch') != 'main' or run.get('head_sha') != sha or
            run.get('repository', {}).get('full_name') != REPOSITORY or run.get('status') != 'completed' or
            artifact.get('name') != expected_name or artifact.get('expired') is not False or
            artifact.get('workflow_run', {}).get('id') != int(run_id) or
            not isinstance(artifact.get('size_in_bytes'), int) or not 0 < artifact['size_in_bytes'] <= MAX_PRODUCT * 3):
        raise RuntimeError('GitHub run/artifact provenance differs from the exact main-dispatch checkpoint')


def fetch(run_id, version, team, destination):
    current = context(version, team)
    if not re.fullmatch(r'[0-9]+', run_id) or run_id == current['producerRunID']:
        raise RuntimeError('Resume requires an earlier completed run ID')
    def api(endpoint):
        return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{endpoint}'], timeout=60, text=True))
    run = api('actions/runs/' + run_id)
    workflow = api('actions/workflows/release.yml')
    # The artifact list is scoped to the independently verified run, not an
    # arbitrary download URL or user-selected archive.
    name = f'nightr-checkpoint-{version}-{current["sourceSHA"]}-{run_id}'
    matches = [item for item in api('actions/runs/' + run_id + '/artifacts?per_page=100')['artifacts'] if item['name'] == name]
    if len(matches) != 1: raise RuntimeError('Expected exactly one named checkpoint artifact')
    artifact = matches[0]
    verify_run(run, workflow, artifact, version, run_id, current['sourceSHA'])
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='nightr-checkpoint-download-') as temporary:
        archive_path = Path(temporary) / 'artifact.zip'
        with archive_path.open('wb') as output:
            subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/actions/artifacts/{int(artifact["id"])}/zip'], stdout=output, check=True, timeout=180)
        if archive_path.stat().st_size > MAX_PRODUCT * 3: raise RuntimeError('Checkpoint archive exceeds download limit')
        with zipfile.ZipFile(archive_path) as archive:
            entries = archive.infolist()
            if len(entries) > len(ALLOWLIST) or sum(item.file_size for item in entries) > MAX_PRODUCT * 3:
                raise RuntimeError('Checkpoint archive exceeds extraction limit')
            names = set()
            for item in entries:
                if item.filename not in ALLOWLIST or item.filename in names or stat.S_IFMT(item.external_attr >> 16) not in [0, stat.S_IFREG]:
                    raise RuntimeError('Unexpected checkpoint archive entry')
                names.add(item.filename)
                limit = 65536 if item.filename == 'checkpoint.json' else 32768 if item.filename in LOGS else MAX_PRODUCT
                if item.file_size > limit: raise RuntimeError('Checkpoint entry exceeds its limit')
                with archive.open(item) as source, (destination / item.filename).open('xb') as output:
                    shutil.copyfileobj(source, output)
    # Validate provenance and all digests before signing secrets are imported.
    checkpoint = Checkpoint(destination, version, team, resume_run_id=run_id)
    # Static validation runs before the workflow imports any signing material.
    # Nothing from the app/package is executed here or in the build continuation.
    def command(*args, **kwargs):
        return subprocess.check_output([str(value) for value in args], text=True, timeout=kwargs.get('timeout', 60)).strip()
    validate_app_zip(checkpoint.path('app'))
    with tempfile.TemporaryDirectory(prefix='nightr-checkpoint-verify-') as temporary:
        root = Path(temporary)
        command('/usr/bin/ditto', '-x', '-k', checkpoint.path('app'), root, timeout=120)
        verify_restored(root / 'Nightr.app', checkpoint.path('guard'), team, version, command)
    if checkpoint.has('package'):
        verify_package(checkpoint.path('package'), team, version, command)
    if checkpoint.has('dmg'):
        command('/usr/bin/codesign', '--verify', '--strict', f'-R=anchor apple generic and certificate leaf[subject.OU] = "{team}"', checkpoint.path('dmg'))
    # Keep the fetched producer ID until the actual build claims the checkpoint.
    checkpoint.data['producerRunID'] = run_id
    checkpoint.save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch-run', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    fetch(args.fetch_run, args.version, args.team_id, args.output)
