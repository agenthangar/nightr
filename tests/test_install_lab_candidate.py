"""Safe candidate identity and inactive-host guards."""
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('install_lab_candidate', SCRIPTS / 'install_lab_candidate.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def test_cdhash_requires_complete_output(monkeypatch):
    monkeypatch.setattr(lab, 'command', lambda args: SimpleNamespace(stderr='CDHash=' + 'a' * 40 + '\n'))
    assert lab.cdhash(Path('/synthetic.app')) == 'a' * 40
    monkeypatch.setattr(lab, 'command', lambda args: SimpleNamespace(stderr='unavailable'))
    with pytest.raises(RuntimeError, match='hash is unavailable'):
        lab.cdhash(Path('/synthetic.app'))


def test_install_refuses_active_controller(monkeypatch):
    monkeypatch.setattr(lab, 'command', lambda *args, **kwargs: SimpleNamespace(returncode=0))
    with pytest.raises(RuntimeError, match='process remains'):
        lab.require_inactive()


def test_install_rejects_unbound_image_before_verification(monkeypatch, tmp_path):
    monkeypatch.setattr(lab.sys, 'platform', 'darwin')
    calls = []
    monkeypatch.setattr(lab, 'command', lambda argv, **kwargs: calls.append(argv))
    image = tmp_path / 'candidate.dmg'
    image.write_bytes(b'synthetic')
    args = SimpleNamespace(commit='a' * 40, sha256='0' * 64, dmg=image,
                           fixture_id='lab', run_id='run')
    with pytest.raises(RuntimeError, match='expected digest'):
        lab.install(args)
    assert len(calls) == 1
    assert calls[0][2:] == ['identify', '--fixture-id', 'lab', '--run-id', 'run']


@pytest.mark.parametrize('same', [True, False])
def test_verified_candidate_quiesces_and_reopens(monkeypatch, tmp_path, same):
    args, calls = candidate_fixture(monkeypatch, tmp_path, same)
    assert lab.install(args) == {'cdhash': 'a' * 40}
    assert calls.index('verify package') < calls.index('quiesce') < calls.index('finish-update')
    assert ('install' in calls) is not same


def test_failed_install_reopens_stopped_previous_app(monkeypatch, tmp_path):
    args, calls = candidate_fixture(monkeypatch, tmp_path, False, fail=True)
    with pytest.raises(RuntimeError, match='synthetic installer failure'):
        lab.install(args)
    assert calls.index('quiesce') < calls.index('install') < calls.index('finish-update')


def test_wrong_source_is_rejected_before_quiescing(monkeypatch, tmp_path):
    args, calls = candidate_fixture(monkeypatch, tmp_path, True)
    args.commit = 'c' * 40
    with pytest.raises(RuntimeError, match='source revision'):
        lab.install(args)
    assert 'quiesce' not in calls


def candidate_fixture(monkeypatch, tmp_path, same, fail=False):
    import contextlib
    import plistlib
    monkeypatch.setattr(lab.sys, 'platform', 'darwin')
    calls = []
    mount = tmp_path / 'mount'
    candidate = mount / 'Nightr.app'
    info = candidate / 'Contents/Info.plist'
    info.parent.mkdir(parents=True)
    info.write_bytes(plistlib.dumps({'NightrSourceRevision': 'b' * 40}))
    app = tmp_path / 'installed.app'
    app.mkdir()
    monkeypatch.setattr(lab.installer, 'APP', app)
    image = tmp_path / 'candidate.dmg'
    image.write_bytes(b'synthetic')
    args = SimpleNamespace(dmg=image, commit='b' * 40, sha256=lab.installer._sha256(image),
                           fixture_id='lab', run_id='run', team_id='ABCDEFGHIJ', version='0.1.3')
    monkeypatch.setattr(lab.installer, 'mounted_dmg', lambda *args: contextlib.nullcontext(mount))
    monkeypatch.setattr(lab.installer, 'verify_app', lambda *args: calls.append('verify app'))
    monkeypatch.setattr(lab.installer, 'verify_package', lambda *args: calls.append('verify package'))
    monkeypatch.setattr(lab.installer, 'verify_installed_receipt', lambda *args: '0.1.3')
    monkeypatch.setattr(lab.installer, 'assert_no_marker', lambda: calls.append('marker clear'))
    monkeypatch.setattr(lab, 'quiesce', lambda team: calls.append('quiesce') or True)
    monkeypatch.setattr(lab, 'require_inactive', lambda: None)
    installed = [same]
    monkeypatch.setattr(lab, 'cdhash', lambda path: 'a' * 40 if path == candidate or installed[0] else 'c' * 40)

    def command(argv, **kwargs):
        if '/usr/sbin/installer' in argv:
            calls.append('install')
            if fail:
                raise RuntimeError('synthetic installer failure')
            installed[0] = True
        if 'finish-update' in argv:
            calls.append('finish-update')
        if 'status' in argv:
            return SimpleNamespace(stdout='{"status":{"holding":false,"state":{"desiredEnabled":false}}}')
        if '/usr/bin/pgrep' in argv:
            return SimpleNamespace(stdout='123')
        if '/bin/ps' in argv:
            return SimpleNamespace(stdout=str(app / 'Contents/MacOS/NightrApp'))
        return SimpleNamespace(stdout='', stderr='', returncode=0)
    monkeypatch.setattr(lab, 'command', command)
    return args, calls
