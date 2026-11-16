"""Inline codesign requirements must be expressions, never file path arguments."""
import ast
import contextlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import notary_checkpoint as checkpoint
import verify_release as release


@pytest.mark.skipif(sys.platform != 'darwin', reason='Apple codesign inline requirement contract')
def test_real_codesign_accepts_matching_inline_requirement_and_rejects_mismatch(tmp_path):
    # Only a temporary byte-copy is signed ad-hoc. No identity, Keychain, code
    # launch, installer, Gatekeeper override, power command or network is used.
    binary = tmp_path / 'fixture'
    shutil.copyfile('/usr/bin/true', binary)
    binary.chmod(0o755)
    identifier = 'ai.nightr.test.inline-requirement'
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                    '--identifier', identifier, str(binary)], check=True, capture_output=True, timeout=30)
    command = ['/usr/bin/codesign', '--verify', '--strict', '--all-architectures']
    subprocess.run([*command, f'-R=identifier "{identifier}"', str(binary)],
                   check=True, capture_output=True, timeout=30)
    # Identifier and Apple-anchor constraints remain meaningful: an ad-hoc
    # fixture cannot impersonate a Developer ID signature even with the right ID.
    for requirement in ['identifier "ai.nightr.test.other"',
                        f'anchor apple generic and identifier "{identifier}"']:
        result = subprocess.run([*command, '-R=' + requirement, str(binary)],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode != 0
        assert 'requirement' in result.stderr.lower()
        assert 'No such file' not in result.stderr


def test_all_release_verifiers_avoid_requirement_file_syntax():
    # Audit less frequently reached resume/fetch paths too. These scripts only
    # use inline expressions; a bare -R reintroduces codesign's file-path mode.
    for name in ['nightr_install.py', 'notary_checkpoint.py', 'verify_release.py', 'build_release.py']:
        tree = ast.parse((ROOT / 'scripts' / name).read_text())
        assert not any(isinstance(node, ast.Constant) and node.value == '-R' for node in ast.walk(tree)), name


def test_restored_checkpoint_checks_exact_inline_identity_and_team(tmp_path):
    app = tmp_path / 'Nightr.app'
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'ai.nightr.app', 'CFBundleShortVersionString': '0.1.0', 'NightrTeamID': 'ABCDE12345'}))
    guard = tmp_path / 'guard'
    calls = []
    def run(*args, **kwargs):
        calls.append(args)
        if args[0] == '/usr/bin/lipo':
            if '/runtime/arm64/' in str(args[-1]): return 'arm64'
            if '/runtime/x86_64/' in str(args[-1]): return 'x86_64'
            return 'x86_64 arm64'
        return ''
    checkpoint.verify_restored(app, guard, 'ABCDE12345', '0.1.0', run)
    checks = [args for args in calls if args[0] == '/usr/bin/codesign']
    assert len(checks) == 7
    for args, identifier in zip(checks[:5], ['ai.nightr.app', 'ai.nightr.installguard',
                                          'ai.nightr.controller', 'ai.nightr.powerhelper', 'ai.nightr.networkworker']):
        assert args[:-2] == ('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures')
        assert args[-2] == f'-R=anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "ABCDE12345"'
    for args in checks[5:]:
        assert args[:-2] == ('/usr/bin/codesign', '--verify', '--strict', '--all-architectures')
        assert args[-2] == '-R=anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"'


def test_release_verifies_dmg_and_both_package_guards_with_inline_requirements(tmp_path, monkeypatch):
    app = tmp_path / 'Nightr.app'
    for arch in ['arm64', 'x86_64']:
        interpreter = app / 'Contents/Resources/runtime' / arch / 'bin/python3'
        interpreter.parent.mkdir(parents=True); interpreter.touch()
    (app / 'Contents/Resources/libexec').mkdir()
    (app / 'Contents/Resources/libexec/nightr_install.py').touch()
    @contextlib.contextmanager
    def mount(*args): yield tmp_path
    installer = release.nightr_install
    monkeypatch.setattr(installer, 'mounted_dmg', mount)
    monkeypatch.setattr(installer, 'verify_app', lambda *args: None)
    monkeypatch.setattr(installer, 'verify_package', lambda *args: None)
    monkeypatch.setattr(installer, '_sha256', lambda *args: 'identical fixture digest')
    calls = []
    def run(args, **kwargs):
        calls.append(args)
        return 'arm64 x86_64' if args[0] == '/usr/bin/lipo' else ''
    monkeypatch.setattr(installer, 'run', run)
    monkeypatch.setattr(sys, 'argv', ['verify_release', '--dmg', str(tmp_path / 'signed.dmg'),
                                    '--team-id', 'ABCDE12345', '--version', '0.1.0'])
    assert release.main() == 0
    checks = [args for args in calls if args[0] == '/usr/bin/codesign']
    assert checks[0] == ['/usr/bin/codesign', '--verify', '--strict',
                         '-R=anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"', tmp_path / 'signed.dmg']
    for args in checks[1:3]:
        assert args[:-2] == ['/usr/bin/codesign', '--verify', '--strict', '--all-architectures']
        assert args[-2] == '-R=anchor apple generic and identifier "ai.nightr.installguard" and certificate leaf[subject.OU] = "ABCDE12345"'
    assert str(checks[1][-1]).endswith('/Payload/Library/PrivilegedHelperTools/ai.nightr.installguard')
    assert str(checks[2][-1]).endswith('/Scripts/ai.nightr.installguard')
