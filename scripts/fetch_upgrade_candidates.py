#!/usr/bin/env python3
"""Fetch two successful same-source signed candidates for disposable upgrade acceptance.

Fixed repository/workflow only. Retained products are data, never executed here.
This does not change notarization checkpoint recovery's exact-source contract.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import tempfile
import time
import zipfile

import check_upgrade

REPOSITORY = 'agenthangar/nightr'
WORKFLOW = '.github/workflows/release.yml'
MAX_IMAGE = check_upgrade.checks.installer.MAX_ARTIFACT
MAX_ARCHIVE = MAX_IMAGE + 2 * 1024**2
MAX_METADATA = 1024**2


def gh_stream(endpoint, output, maximum, *, timeout=180):
    """Drain both pipes with a deadline and enforce the byte limit while reading."""
    process = subprocess.Popen(['gh', 'api', f'repos/{REPOSITORY}/{endpoint}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as streams:
            streams.register(process.stdout, selectors.EVENT_READ, 'output')
            streams.register(process.stderr, selectors.EVENT_READ, 'error')
            while streams.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise TimeoutError('GitHub candidate transfer exceeded its deadline')
                for key, _ in streams.select(min(1, remaining)):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        streams.unregister(key.fileobj)
                    elif key.data == 'output':
                        count += len(block)
                        if count > maximum: raise RuntimeError('GitHub candidate transfer exceeds its byte limit')
                        output.write(block)
                    # Drain stderr but never retain auth/host diagnostics in the
                    # public provenance report. The exit code remains a failure.
            if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
                raise RuntimeError('GitHub candidate API request failed')
        return count
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def api(endpoint):
    output = io.BytesIO()
    gh_stream(endpoint, output, MAX_METADATA, timeout=60)
    return json.loads(output.getvalue())


def checked_context(team):
    sha = os.environ.get('GITHUB_SHA', '')
    if (os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_REF') != 'refs/heads/main' or
            not re.fullmatch(r'[0-9a-f]{40}', sha) or not re.fullmatch(r'[A-Z0-9]{10}', team)):
        raise RuntimeError('Candidate acquisition requires exact main checkout and independently configured team')
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, timeout=30).strip()
    if actual != sha: raise RuntimeError('Acceptance checkout differs from the dispatched SHA')
    return sha


def validate_run(run, workflow, run_id):
    if (not isinstance(workflow.get('id'), int) or workflow.get('path') != WORKFLOW or
            run.get('id') != int(run_id) or run.get('workflow_id') != workflow['id'] or run.get('path') != WORKFLOW or
            run.get('repository', {}).get('full_name') != REPOSITORY or run.get('event') != 'workflow_dispatch' or
            run.get('head_branch') != 'main' or run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            not re.fullmatch(r'[0-9a-f]{40}', run.get('head_sha', ''))):
        raise RuntimeError('Candidate run is not a successful main dispatch of the known release workflow')
    return run['head_sha']


def select_artifact(listing, version, sha, run_id):
    name = f'nightr-{version}-{sha}-{run_id}'
    matches = [item for item in listing.get('artifacts', []) if item.get('name') == name]
    if len(matches) != 1: raise RuntimeError('Expected exactly one named candidate artifact')
    artifact = matches[0]
    owner = artifact.get('workflow_run', {})
    if (artifact.get('expired') is not False or not isinstance(artifact.get('id'), int) or artifact['id'] <= 0 or
            owner.get('id') != int(run_id) or owner.get('head_sha') != sha or owner.get('head_branch') != 'main' or
            not isinstance(artifact.get('size_in_bytes'), int) or not 0 < artifact['size_in_bytes'] <= MAX_ARCHIVE):
        raise RuntimeError('Candidate artifact provenance/size/expiry differs')
    metadata_digest = artifact.get('digest')
    if metadata_digest is not None and not re.fullmatch(r'sha256:[0-9a-f]{64}', metadata_digest):
        raise RuntimeError('Unsupported candidate artifact digest')
    return artifact


def extract_candidate(archive_path, destination, version):
    limits = {f'Nightr-{version}-universal.dmg': MAX_IMAGE, 'nightr-release.json': MAX_METADATA,
              'nightr.rb': 65536, 'installer-acceptance.json': 65536}
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if len(entries) != 4 or set(names) != set(limits) or len(set(names)) != 4:
            raise RuntimeError('Candidate ZIP must contain exactly the four expected flat files')
        if sum(item.file_size for item in entries) > sum(limits.values()):
            raise RuntimeError('Candidate ZIP aggregate exceeds extraction limit')
        for item in entries:
            if (item.flag_bits & 1 or stat.S_IFMT(item.external_attr >> 16) not in [0, stat.S_IFREG] or
                    item.is_dir() or not 0 < item.file_size <= limits[item.filename]):
                raise RuntimeError('Candidate ZIP has an encrypted, nonregular or oversized entry')
        destination.mkdir(parents=True, exist_ok=False)
        for item in entries:
            count = 0
            with archive.open(item) as source, (destination / item.filename).open('xb') as output:
                while block := source.read(1024 * 1024):
                    count += len(block)
                    if count > limits[item.filename] or count > item.file_size:
                        raise RuntimeError('Candidate entry exceeds its declared extraction limit')
                    output.write(block)
            if count != item.file_size: raise RuntimeError('Candidate entry size differs after extraction')


def candidate_report(path, version, sha, run_id):
    if path.stat().st_size > 65536: raise RuntimeError('Candidate acceptance report exceeds limit')
    report = json.loads(path.read_text())
    expected = {'schemaVersion': 1, 'status': 'passed_limited_acceptance', 'version': version,
                'commit': sha, 'runID': str(run_id), 'freshInstall': 'passed', 'samePackageReinstall': 'passed',
                'artifactVerification': 'passed'}
    if not isinstance(report, dict) or any(report.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Candidate report does not prove this exact run/source/version passed fresh and reinstall checks')
    return {key: report[key] for key in expected}


def fetch_one(run_id, version, source_sha, team, destination):
    artifact = select_artifact(api(f'actions/runs/{run_id}/artifacts?per_page=100'), version, source_sha, run_id)
    with tempfile.TemporaryDirectory(prefix='nightr-upgrade-candidate-') as temporary:
        archive_path = Path(temporary) / 'candidate.zip'
        with archive_path.open('wb') as output:
            count = gh_stream(f'actions/artifacts/{artifact["id"]}/zip', output, MAX_ARCHIVE)
        if count != artifact['size_in_bytes']: raise RuntimeError('Downloaded artifact size differs from GitHub metadata')
        archive_digest = check_upgrade.checks.installer._sha256(archive_path)
        if artifact.get('digest') is not None and artifact['digest'] != 'sha256:' + archive_digest:
            raise RuntimeError('Downloaded artifact digest differs from GitHub metadata')
        extract_candidate(archive_path, destination, version)
    report = candidate_report(destination / 'installer-acceptance.json', version, source_sha, run_id)
    manifest_path = destination / 'nightr-release.json'
    image = destination / f'Nightr-{version}-universal.dmg'
    manifest = check_upgrade.load_candidate(manifest_path, image, version)
    if manifest['teamID'] != team: raise RuntimeError('Candidate manifest differs from the independently configured team')
    return {'runID': str(run_id), 'artifactID': artifact['id'], 'artifactName': artifact['name'],
            'archiveSHA256': archive_digest, 'metadataDigest': artifact.get('digest'),
            'manifestSHA256': check_upgrade.checks.installer._sha256(manifest_path),
            'dmgSHA256': manifest['asset']['sha256'], 'version': version, 'acceptance': report}


def fetch(args, provenance):
    for value in [args.baseline_run_id, args.final_run_id]:
        if not re.fullmatch(r'[1-9][0-9]{0,19}', value): raise RuntimeError('Candidate run IDs must be positive decimal integers')
    workflow_sha = checked_context(args.team_id)
    workflow = api('actions/workflows/release.yml')
    sources = [validate_run(api(f'actions/runs/{run_id}'), workflow, run_id) for run_id in [args.baseline_run_id, args.final_run_id]]
    if sources[0] != sources[1]: raise RuntimeError('Baseline and final candidates must have the same source SHA')
    source = sources[0]
    subprocess.run(['git', 'merge-base', '--is-ancestor', source, workflow_sha], check=True, timeout=30, capture_output=True)
    provenance.update(sourceSHA=source, workflowSHA=workflow_sha, teamID=args.team_id, repository=REPOSITORY, workflow=WORKFLOW)
    if check_upgrade.checks.installer.version_key(args.baseline_version) >= check_upgrade.checks.installer.version_key(args.final_version):
        raise RuntimeError('Final candidate must be newer than baseline')
    provenance['baseline'] = fetch_one(args.baseline_run_id, args.baseline_version, source, args.team_id, args.output / 'baseline')
    provenance['final'] = fetch_one(args.final_run_id, args.final_version, source, args.team_id, args.output / 'final')
    provenance['status'] = 'passed_candidate_acquisition'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-run-id', required=True)
    parser.add_argument('--final-run-id', required=True)
    parser.add_argument('--baseline-version', default='0.0.0')
    parser.add_argument('--final-version', default='0.1.0')
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args(argv)
    provenance = {'schemaVersion': 1, 'status': 'failed', 'runID': os.environ.get('GITHUB_RUN_ID'),
                  'workflowSHA': os.environ.get('GITHUB_SHA'), 'baseline': 'untested', 'final': 'untested'}
    try:
        fetch(args, provenance)
    except Exception as error:
        provenance['error'] = f'{type(error).__name__}: {error}'[-4096:]
        print(provenance['error'], file=os.sys.stderr)
        return 1
    finally:
        payload = json.dumps(provenance, indent=2, sort_keys=True) + '\n'
        if len(payload.encode()) > 65536: raise RuntimeError('Candidate provenance report exceeds limit')
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(payload)
    return 0


if __name__ == '__main__': raise SystemExit(main())
