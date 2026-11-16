"""Synthetic contracts only: never install, elevate, sign or contact services."""
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import check_upgrade as upgrade


@pytest.mark.parametrize('uid,euid,home', [(0, 0, '/runner'), (501, 0, '/runner'), (501, 501, '/sandbox')])
def test_runner_rejects_root_or_sandbox_home(monkeypatch, uid, euid, home):
    monkeypatch.setattr(upgrade.checks, 'require_disposable', lambda opt: None)
    monkeypatch.setattr(upgrade.os, 'getuid', lambda: uid)
    monkeypatch.setattr(upgrade.os, 'geteuid', lambda: euid)
    monkeypatch.setattr(upgrade.pwd, 'getpwuid', lambda uid: SimpleNamespace(pw_dir='/runner'))
    monkeypatch.setenv('HOME', home)
    with pytest.raises(RuntimeError, match='real nonroot'): upgrade.require_runner(True)


def test_exact_candidate_download_keeps_production_checksum_verification(tmp_path, monkeypatch):
    source = tmp_path / 'retained.dmg'
    source.write_bytes(b'signed candidate bytes')
    url = 'https://github.com/agenthangar/nightr/releases/download/v0.1.0/Nightr-0.1.0-universal.dmg'
    download = upgrade.candidate_download({url: source})
    module = upgrade.checks.installer
    monkeypatch.setattr(module, 'download', download)
    manifest = {'asset': {'name': 'copy.dmg', 'url': url, 'size': source.stat().st_size, 'sha256': module._sha256(source)}}
    assert module.download_verified_package(manifest, tmp_path).read_bytes() == source.read_bytes()
    source.write_bytes(b'tampered image bytes!!')
    with pytest.raises(module.InstallError, match='checksum mismatch'):
        module.download_verified_package(manifest, tmp_path)
    with pytest.raises(RuntimeError, match='Unexpected acquisition'):
        download('https://evil.example/image', tmp_path / 'other.dmg', 100)
    with pytest.raises(RuntimeError, match='production download limit'):
        download(url, tmp_path / 'small.dmg', 1)


@pytest.mark.parametrize('command', [
    ['/usr/bin/sudo', '--', '/bin/sh', '-c', 'anything'],
    ['/usr/bin/sudo', '-n', '--', '/usr/sbin/installer'],
    ['/usr/bin/sudo', '--', '/Library/PrivilegedHelperTools/ai.nightr.installguard', 'finish', 'wrong-transaction'],
])
def test_proxy_refuses_unexpected_privileged_targets(monkeypatch, command):
    module = SimpleNamespace(INSTALL_GUARD=Path('/Library/PrivilegedHelperTools/ai.nightr.installguard'))
    calls = []
    monkeypatch.setattr(upgrade.subprocess, 'run', lambda *a, **kw: calls.append(a))
    with pytest.raises(RuntimeError, match='Unexpected'):
        upgrade.NoPromptSubprocess(module, {}).run(command, check=True)
    assert calls == []


def test_proxy_validates_real_request_and_only_adds_no_prompt(tmp_path, monkeypatch):
    transaction = '01234567-0123-0123-0123-0123456789ab'
    identity = {'pid': 123, 'uid': os.getuid(), 'bootID': 'synthetic'}
    request = tmp_path / 'install-request.json'
    request.write_text(json.dumps({'schemaVersion': 1, 'owner': identity, 'packagePath': '/Volumes/signed/Nightr.pkg',
                                   'version': '0.1.0', 'originalVersion': '0.0.0', 'operation': 'install',
                                   'teamID': 'TEAM123456', 'transaction': transaction}))
    request.chmod(0o600)
    module = SimpleNamespace(state_directory=lambda: tmp_path, current_process_identity=lambda: identity,
                             INSTALL_GUARD=Path('/Library/PrivilegedHelperTools/ai.nightr.installguard'))
    calls = []
    monkeypatch.setattr(upgrade.subprocess, 'run', lambda command, **kw: calls.append((command, kw)))
    report = {'teamID': 'TEAM123456'}
    proxy = upgrade.NoPromptSubprocess(module, report)
    command = ['/usr/bin/sudo', '--', '/usr/sbin/installer', '-pkg', '/Volumes/signed/Nightr.pkg', '-target', '/']
    proxy.run(command, check=True, timeout=180)
    assert calls[0] == (['/usr/bin/sudo', '-n', *command[1:]], {'check': True, 'timeout': 180})
    assert report['requestProvenance']['uid'] == os.getuid()
    proxy.run(['/usr/bin/sudo', '--', str(module.INSTALL_GUARD), 'finish', transaction], check=True, timeout=30)
    assert calls[1][0][1] == '-n'
    request.write_text(request.read_text().replace('"pid": 123', '"pid": 456'))
    with pytest.raises(RuntimeError, match='bind this nonroot process'):
        proxy.run(command, check=True)
    assert len(calls) == 2


def test_nonprivileged_signature_commands_pass_through_unchanged(monkeypatch):
    calls = []
    monkeypatch.setattr(upgrade.subprocess, 'run', lambda command, **kw: calls.append(command))
    command = ['/usr/bin/codesign', '--verify', '--strict', '/Applications/Nightr.app']
    upgrade.NoPromptSubprocess(SimpleNamespace(), {}).run(command, check=True)
    assert calls == [command]


def test_outer_failure_replaces_stale_success_report(tmp_path, monkeypatch):
    report = tmp_path / 'report.json'
    report.write_text(json.dumps({'status': 'passed_limited_acceptance', 'managedUpgrade': 'passed'}))
    monkeypatch.setattr(upgrade, 'require_runner', lambda opt: tmp_path)
    monkeypatch.setattr(upgrade, 'run_pty', lambda *a, **kw: (_ for _ in ()).throw(TimeoutError('bounded timeout')))
    arguments = ['--disposable-github-runner', '--team-id', 'TEAM123456', '--baseline-manifest', 'old.json', '--baseline-dmg', 'old.dmg',
                 '--final-manifest', 'new.json', '--final-dmg', 'new.dmg', '--report', str(report)]
    assert upgrade.main(arguments) == 1
    data = json.loads(report.read_text())
    assert data['status'] == 'failed' and data['managedUpgrade'] == 'untested'
    assert 'controller finish-update/resume' in data['untested']


@pytest.mark.parametrize('baseline_team,final_team', [('OTHER12345', 'OTHER12345'), ('TEAM123456', 'OTHER12345')])
def test_manifest_teams_must_match_independent_configuration_before_privileged_commands(tmp_path, monkeypatch, baseline_team, final_team):
    monkeypatch.setattr(upgrade, 'require_runner', lambda opt: tmp_path)
    monkeypatch.setattr(upgrade.sys, 'stdin', SimpleNamespace(isatty=lambda: True))
    monkeypatch.setattr(upgrade.checks, 'require_fresh', lambda: None)
    monkeypatch.setattr(upgrade.checks, 'assert_absent', lambda path: None)
    monkeypatch.setattr(upgrade, 'load_candidate', lambda manifest, image, version: {
        'version': version, 'teamID': baseline_team if version == '0.0.0' else final_team})
    commands = []
    monkeypatch.setattr(upgrade.checks, 'run', lambda *a, **kw: commands.append(a))
    args = SimpleNamespace(disposable_github_runner=True, team_id='TEAM123456', baseline_manifest=tmp_path / 'old.json',
                           baseline_dmg=tmp_path / 'old.dmg', final_manifest=tmp_path / 'new.json', final_dmg=tmp_path / 'new.dmg')
    with pytest.raises(RuntimeError, match='independently configured team'):
        upgrade.accept(args, {})
    assert commands == []
