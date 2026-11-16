"""Candidate contracts; installation is mocked, signing proof uses temp ad-hoc code."""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import check_installer as acceptance
import build_release as build


def test_cli_alias_survives_payload_copy_inside_the_bundle(tmp_path):
    app = tmp_path / 'Nightr.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    (macos / 'nightr-native').write_bytes(b'fixture native executable')
    build.create_cli_alias(macos)
    copied = tmp_path / 'payload/Nightr.app'
    shutil.copytree(app, copied, symlinks=True)
    for bundle in (app, copied):
        alias = bundle / 'Contents/MacOS/nightr'
        assert alias.is_symlink()
        assert os.readlink(alias) == 'nightr-native'
        assert alias.resolve() == bundle / 'Contents/MacOS/nightr-native'


@pytest.mark.skipif(sys.platform != 'darwin', reason='macOS codesign structure check')
def test_cli_alias_allows_strict_bundle_sealing_without_script_signatures(tmp_path):
    # Ad-hoc, temporary copies only: no private identity, Keychain change, launch,
    # Gatekeeper override, or notarization claim.
    app = tmp_path / 'Fixture.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    for name in ('Fixture', 'nightr-native'):
        # Copy bytes, not the system binary's protected filesystem flags.
        shutil.copyfile('/usr/bin/true', macos / name)
        (macos / name).chmod(0o755)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'ai.nightr.test.fixture', 'CFBundleExecutable': 'Fixture',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    }))
    build.create_cli_alias(macos)
    for path in (macos / 'nightr-native', app):
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path)],
                       check=True, capture_output=True, text=True, timeout=30)
    copied = tmp_path / 'payload/Fixture.app'
    shutil.copytree(app, copied, symlinks=True)
    for path in (app, copied):
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(path)],
                       check=True, capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize('opt_in,platform,markers', [
    (False, 'darwin', {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS'}),
    (True, 'linux', {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS'}),
    (True, 'darwin', {}),
    (True, 'darwin', {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_OS': 'macOS'}),
])
def test_install_refuses_unsafe_hosts(monkeypatch, opt_in, platform, markers):
    monkeypatch.setattr(acceptance.sys, 'platform', platform)
    for key in ['GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'RUNNER_OS']:
        monkeypatch.delenv(key, raising=False)
    for key, value in markers.items(): monkeypatch.setenv(key, value)
    with pytest.raises(RuntimeError, match='Refusing installation'):
        acceptance.require_disposable(opt_in)


def test_existing_state_is_never_removed(tmp_path):
    path = tmp_path / 'state'
    path.symlink_to(tmp_path / 'missing')
    with pytest.raises(RuntimeError, match='Refusing existing'):
        acceptance.assert_absent(path)
    assert path.is_symlink()


def test_receipt_query_failure_cannot_mean_fresh(monkeypatch):
    monkeypatch.setattr(acceptance, 'assert_absent', lambda path: None)
    monkeypatch.setattr(acceptance, 'run', lambda *a, **kw: (_ for _ in ()).throw(RuntimeError('receipt database failed')))
    with pytest.raises(RuntimeError, match='receipt database failed'): acceptance.require_fresh()


def test_existing_receipt_is_refused(monkeypatch):
    monkeypatch.setattr(acceptance, 'assert_absent', lambda path: None)
    monkeypatch.setattr(acceptance, 'run', lambda *a, **kw: SimpleNamespace(stdout='com.apple.example\nai.nightr.package\n'))
    with pytest.raises(RuntimeError, match='existing Nightr package receipt'): acceptance.require_fresh()


@pytest.mark.parametrize('failure', [None, 'freshInstall', 'samePackageReinstall'])
def test_acceptance_installs_real_package_twice_and_keeps_failure_state(tmp_path, monkeypatch, failure):
    events = []
    monkeypatch.setattr(acceptance, 'require_disposable', lambda opt: events.append('gate'))
    monkeypatch.setattr(acceptance, 'require_fresh', lambda: events.append('fresh check'))
    @contextlib.contextmanager
    def mount(*args):
        events.append('mount')
        try: yield tmp_path
        finally: events.append('detach')
    monkeypatch.setattr(acceptance.installer, 'mounted_dmg', mount)
    monkeypatch.setattr(acceptance.installer, 'verify_package', lambda *a: events.append('verify package'))
    def run(command, **kwargs):
        events.append('install' if command[0] == '/usr/bin/sudo' else 'verify release')
        if command[0] == '/usr/bin/sudo':
            assert command == ['/usr/bin/sudo', '-n', '/usr/sbin/installer', '-verboseR', '-dumplog', '-pkg', tmp_path / 'Nightr.pkg', '-target', '/']
    monkeypatch.setattr(acceptance, 'run', run)
    calls = []
    def verify(*args):
        calls.append(True)
        events.append('verify installed')
        if failure == ('freshInstall' if len(calls) == 1 else 'samePackageReinstall'):
            raise RuntimeError('guard kept pending marker')
    monkeypatch.setattr(acceptance, 'verify_installation', verify)
    args = SimpleNamespace(disposable_github_runner=True, dmg=tmp_path / 'signed.dmg', team_id='TEAM123456', version='0.1.0')
    report = {'status': 'failed'}
    if failure:
        with pytest.raises(RuntimeError, match='pending marker'): acceptance.accept(args, report)
        assert report[failure] == 'started'
        assert report['status'] == 'failed'
    else:
        acceptance.accept(args, report)
        assert report['freshInstall'] == report['samePackageReinstall'] == 'passed'
        assert report['status'] == 'passed_limited_acceptance'
    assert events[:5] == ['gate', 'fresh check', 'verify release', 'mount', 'verify package']
    assert events[-1] == 'detach'
    assert events.count('install') == (1 if failure == 'freshInstall' else 2)


def test_failed_acceptance_writes_honest_report(tmp_path, monkeypatch):
    monkeypatch.setattr(acceptance, 'accept', lambda *a: (_ for _ in ()).throw(RuntimeError('refused')))
    report = tmp_path / 'report.json'
    assert acceptance.main(['--dmg', 'candidate.dmg', '--team-id', 'TEAM123456', '--version', '0.1.0', '--report', str(report)]) == 1
    result = json.loads(report.read_text())
    assert result['status'] == 'failed' and result['freshInstall'] == 'untested'
    assert 'version-changing update' in result['untested']



def test_build_failure_keeps_stdout_diagnostics(monkeypatch, capsys):
    def run(*a, **kw): raise subprocess.CalledProcessError(1, 'swift', output='compiler diagnostic', stderr='linker diagnostic')
    monkeypatch.setattr(build.subprocess, 'run', run)
    with pytest.raises(subprocess.CalledProcessError): build.run('swift', 'build')
    diagnostic = capsys.readouterr().err
    assert 'compiler diagnostic' in diagnostic and 'linker diagnostic' in diagnostic


def test_installed_version_and_pending_marker_fail_before_smoke_commands(monkeypatch):
    commands = []
    monkeypatch.setattr(acceptance, 'run', lambda *a, **kw: commands.append(a))
    monkeypatch.setattr(acceptance.installer, 'verify_installed_receipt', lambda team: '0.1.1')
    with pytest.raises(RuntimeError, match='Installed version'):
        acceptance.verify_installation('TEAM123456', '0.1.0')
    monkeypatch.setattr(acceptance.installer, 'verify_installed_receipt', lambda team: '0.1.0')
    monkeypatch.setattr(acceptance.installer, 'assert_no_marker', lambda: (_ for _ in ()).throw(RuntimeError('pending marker')))
    with pytest.raises(RuntimeError, match='pending marker'):
        acceptance.verify_installation('TEAM123456', '0.1.0')
    assert commands == []


def test_candidate_workflow_has_no_publish_authority_and_pins_dispatch():
    import yaml
    workflow = yaml.safe_load((ROOT / '.github/workflows/release.yml').read_text())
    assert workflow['permissions'] == {'contents': 'read', 'actions': 'read'}
    job = workflow['jobs']['candidate']
    assert job['if'] == "github.ref == 'refs/heads/main'"
    assert job.get('permissions', workflow['permissions']) == {'contents': 'read', 'actions': 'read'}
    steps = job['steps']
    assert steps[0]['with']['ref'] == '${{ github.sha }}'
    # Enforce the actual set of allowed action capabilities; no publication
    # action or token-bearing shell step can be appended unnoticed.
    assert {step['uses'].split('@')[0] for step in steps if 'uses' in step} == {
        'actions/checkout', 'actions/setup-python', 'actions/upload-artifact'}
    shell_steps = [step for step in steps if 'run' in step]
    assert all('gh release' not in step['run'] for step in shell_steps)
    token_steps = [step for step in shell_steps if 'GH_TOKEN' in step.get('env', {})]
    assert len(token_steps) == 1 and 'scripts/notary_checkpoint.py --fetch-run' in token_steps[0]['run']
    setup = next(step for step in steps if step.get('uses', '').startswith('actions/setup-python@'))
    credentials = next(step for step in shell_steps if 'security import' in step['run'])
    assert setup['with']['python-version'] == '3.13'
    assert steps.index(setup) < steps.index(token_steps[0]) < steps.index(credentials)
    acceptance_step = next(step for step in shell_steps if 'scripts/check_installer.py' in step['run'])
    cleanup_step = next(step for step in shell_steps if 'security delete-keychain' in step['run'])
    assert cleanup_step['if'] == 'always()' and steps.index(cleanup_step) < steps.index(acceptance_step)
    assert '--disposable-github-runner' in acceptance_step['run']
    upload = next(step for step in steps if step.get('uses', '').startswith('actions/upload-artifact@'))
    assert upload['if'] == 'always()'
    assert all(value in upload['with']['name'] for value in ['inputs.version', 'github.sha', 'github.run_id'])
