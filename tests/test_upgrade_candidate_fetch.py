"""Synthetic candidates/transport only; never install or invoke downloaded code."""
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from types import SimpleNamespace
import zipfile

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import fetch_upgrade_candidates as fetcher

SOURCE = 'a' * 40
ACCEPTANCE = 'b' * 40
TEAM = 'TEAM123456'


def run_metadata(identifier, **changes):
    return {'id': identifier, 'workflow_id': 42, 'path': fetcher.WORKFLOW, 'repository': {'full_name': fetcher.REPOSITORY},
            'event': 'workflow_dispatch', 'head_branch': 'main', 'status': 'completed', 'conclusion': 'success', 'head_sha': SOURCE, **changes}


def artifact(identifier=100, version='0.0.0', **changes):
    return {'id': identifier + 1000, 'name': f'nightr-{version}-{SOURCE}-{identifier}', 'expired': False,
            'size_in_bytes': 1, 'workflow_run': {'id': identifier, 'head_sha': SOURCE, 'head_branch': 'main'}, **changes}


def report(version='0.0.0', identifier=100, **changes):
    return {'schemaVersion': 1, 'status': 'passed_limited_acceptance', 'version': version, 'commit': SOURCE,
            'runID': str(identifier), 'freshInstall': 'passed', 'samePackageReinstall': 'passed', 'artifactVerification': 'passed', **changes}


def candidate_zip(tmp_path, version='0.0.0', identifier=100, *, team=TEAM, report_changes=None):
    image = tmp_path / f'{identifier}.dmg'; image.write_bytes(b'synthetic signed candidate bytes')
    name = f'Nightr-{version}-universal.dmg'
    manifest = {'schemaVersion': 1, 'version': version, 'platform': 'macos', 'minVersion': '13.0',
                'architectures': ['arm64', 'x86_64'], 'teamID': team, 'bundleID': 'ai.nightr.app',
                'controllerID': 'ai.nightr.controller', 'helperID': 'ai.nightr.powerhelper', 'protocolVersion': 1,
                'asset': {'name': name, 'url': f'https://github.com/{fetcher.REPOSITORY}/releases/download/v{version}/{name}',
                          'sha256': fetcher.check_upgrade.checks.installer._sha256(image), 'size': image.stat().st_size}}
    archive = tmp_path / f'{identifier}.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr(name, image.read_bytes())
        output.writestr('nightr-release.json', json.dumps(manifest))
        output.writestr('nightr.rb', '# synthetic never-executed cask')
        output.writestr('installer-acceptance.json', json.dumps(report(version, identifier, **(report_changes or {}))))
    return archive


@pytest.mark.parametrize('changes', [{'conclusion': 'failure'}, {'status': 'in_progress'}, {'event': 'pull_request'},
                                     {'head_branch': 'feature'}, {'workflow_id': 99}, {'repository': {'full_name': 'other/repo'}}])
def test_run_requires_successful_known_main_manual_workflow(changes):
    with pytest.raises(RuntimeError, match='successful main dispatch'):
        fetcher.validate_run(run_metadata(100, **changes), {'id': 42, 'path': fetcher.WORKFLOW}, '100')


@pytest.mark.parametrize('changes', [{'expired': True}, {'name': 'arbitrary'}, {'workflow_run': {'id': 99}},
                                     {'size_in_bytes': fetcher.MAX_ARCHIVE + 1}, {'digest': 'unknown:value'}])
def test_artifact_provenance_expiry_and_size_are_required(changes):
    with pytest.raises(RuntimeError): fetcher.select_artifact({'artifacts': [artifact(**changes)]}, '0.0.0', SOURCE, '100')


@pytest.mark.parametrize('malice', ['extra', 'traversal', 'symlink', 'directory', 'duplicate', 'oversize'])
def test_four_flat_regular_files_contract(tmp_path, malice):
    archive = candidate_zip(tmp_path)
    with zipfile.ZipFile(archive) as original:
        members = [(item, original.read(item)) for item in original.infolist()]
    with zipfile.ZipFile(archive, 'w') as output:
        for item, content in members:
            if item.filename == 'nightr.rb':
                if malice == 'traversal': item.filename = '../nightr.rb'
                elif malice == 'symlink': item.external_attr = (stat.S_IFLNK | 0o777) << 16
                elif malice == 'directory': item.filename = 'nightr.rb/'
                elif malice == 'oversize': content = b'x' * 65537
            output.writestr(item, content)
        if malice == 'extra': output.writestr('private.key', b'never retained')
        elif malice == 'duplicate': output.writestr('nightr.rb', b'duplicate')
    with pytest.raises(RuntimeError): fetcher.extract_candidate(archive, tmp_path / 'destination', '0.0.0')
    assert not (tmp_path / 'nightr.rb').exists()


def test_stream_limit_enforced_during_read_without_network(monkeypatch):
    class Process:
        def __init__(self):
            output_read, output_write = os.pipe(); error_read, error_write = os.pipe()
            os.write(output_write, b'exceeds limit'); os.close(output_write); os.close(error_write)
            self.stdout = os.fdopen(output_read, 'rb', buffering=0)
            self.stderr = os.fdopen(error_read, 'rb', buffering=0)
            self.killed = False
        def poll(self): return 0 if self.killed else None
        def kill(self): self.killed = True
        def wait(self, **kwargs): return 0
    process = Process()
    monkeypatch.setattr(fetcher.subprocess, 'Popen', lambda *a, **kw: process)
    output = io.BytesIO()
    with pytest.raises(RuntimeError, match='byte limit'): fetcher.gh_stream('fixed', output, 1)
    assert process.killed and output.getvalue() == b''


@pytest.fixture
def transport(tmp_path, monkeypatch):
    archives = {100: candidate_zip(tmp_path), 101: candidate_zip(tmp_path, '0.1.0', 101)}
    listings = {}
    for identifier, archive in archives.items():
        item = artifact(identifier, '0.0.0' if identifier == 100 else '0.1.0')
        item.update(size_in_bytes=archive.stat().st_size, digest='sha256:' + fetcher.check_upgrade.checks.installer._sha256(archive))
        listings[identifier] = item
    runs = {100: run_metadata(100), 101: run_metadata(101)}
    def api(endpoint):
        if endpoint == 'actions/workflows/release.yml': return {'id': 42, 'path': fetcher.WORKFLOW}
        identifier = int(endpoint.split('/')[2])
        return {'artifacts': [listings[identifier]]} if 'artifacts?' in endpoint else runs[identifier]
    def stream(endpoint, output, maximum, **kwargs):
        identifier = int(endpoint.split('/')[2]) - 1000
        content = archives[identifier].read_bytes()
        assert len(content) <= maximum
        output.write(content)
        return len(content)
    monkeypatch.setattr(fetcher, 'api', api)
    monkeypatch.setattr(fetcher, 'gh_stream', stream)
    monkeypatch.setattr(fetcher, 'checked_context', lambda team: ACCEPTANCE)
    git = []
    monkeypatch.setattr(fetcher.subprocess, 'run', lambda command, **kw: git.append(command))
    args = SimpleNamespace(baseline_run_id='100', final_run_id='101', baseline_version='0.0.0', final_version='0.1.0',
                           team_id=TEAM, output=tmp_path / 'candidates')
    return SimpleNamespace(args=args, archives=archives, listings=listings, runs=runs, git=git)


def test_later_acceptance_commit_accepts_same_source_ancestor_candidates(transport):
    provenance = {}
    fetcher.fetch(transport.args, provenance)
    assert transport.git == [['git', 'merge-base', '--is-ancestor', SOURCE, ACCEPTANCE]]
    assert provenance['sourceSHA'] == SOURCE and provenance['workflowSHA'] == ACCEPTANCE
    assert provenance['status'] == 'passed_candidate_acquisition'
    assert provenance['baseline']['artifactID'] == 1100
    assert provenance['final']['acceptance']['samePackageReinstall'] == 'passed'


@pytest.mark.parametrize('failure', ['different_source', 'not_ancestor', 'report', 'team', 'digest'])
def test_acquisition_refuses_untrusted_candidate_pair(transport, monkeypatch, failure):
    if failure == 'different_source': transport.runs[101]['head_sha'] = 'c' * 40
    elif failure == 'not_ancestor':
        monkeypatch.setattr(fetcher.subprocess, 'run', lambda *a, **kw: (_ for _ in ()).throw(subprocess.CalledProcessError(1, 'git')))
    elif failure == 'report':
        monkeypatch.setattr(fetcher, 'candidate_report', lambda *a: (_ for _ in ()).throw(RuntimeError('wrong report')))
    elif failure == 'team': transport.args.team_id = 'OTHER12345'
    elif failure == 'digest': transport.listings[100]['digest'] = 'sha256:' + 'f' * 64
    with pytest.raises((RuntimeError, subprocess.CalledProcessError)): fetcher.fetch(transport.args, {})


@pytest.mark.parametrize('changes', [{'commit': 'c' * 40}, {'runID': '99'}, {'version': '0.1.0'}, {'freshInstall': 'started'},
                                     {'samePackageReinstall': 'untested'}, {'status': 'not_started'}])
def test_report_must_prove_the_exact_candidate(tmp_path, changes):
    path = tmp_path / 'report.json'; path.write_text(json.dumps(report(**changes)))
    with pytest.raises(RuntimeError, match='exact run/source/version'):
        fetcher.candidate_report(path, '0.0.0', SOURCE, '100')


def test_workflow_has_readonly_no_signing_authority_and_uploads_only_reports():
    import yaml
    source = (Path(__file__).resolve().parents[1] / '.github/workflows/upgrade-acceptance.yml').read_text()
    workflow = yaml.safe_load(source)
    assert workflow['permissions'] == {'contents': 'read', 'actions': 'read'}
    assert set(workflow.get('on', workflow.get(True))) == {'workflow_dispatch'}
    job = workflow['jobs']['acceptance']
    assert job['if'] == "github.ref == 'refs/heads/main'" and job['runs-on'] == 'macos-15'
    assert 'environment' not in job and 'secrets.' not in source
    steps = job['steps']; checkout = steps[0]['with']
    assert checkout == {'ref': '${{ github.sha }}', 'persist-credentials': False, 'fetch-depth': 0}
    token = [step for step in steps if 'GH_TOKEN' in step.get('env', {})]
    assert len(token) == 1 and 'fetch_upgrade_candidates.py' in token[0]['run']
    install = next(step for step in steps if 'check_upgrade.py' in step.get('run', ''))
    assert 'sudo' not in install['run'] and 'GH_TOKEN' not in install.get('env', {})
    upload = next(step for step in steps if step.get('uses', '').startswith('actions/upload-artifact@'))
    assert upload['if'] == 'always()'
    assert set(upload['with']['path'].splitlines()) == {'dist/candidate-provenance.json', 'dist/upgrade-acceptance.json'}
