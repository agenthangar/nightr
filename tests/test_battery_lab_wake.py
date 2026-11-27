"""Wake fixture tests replace every system and power command."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest

spec = importlib.util.spec_from_file_location('battery_lab_wake', Path(__file__).resolve().parents[1] / 'scripts/battery_lab_wake.py')
wake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wake)


@pytest.fixture
def fixture(tmp_path, monkeypatch):
    monkeypatch.setattr(wake, 'DIRECTORY', tmp_path)
    monkeypatch.setattr(wake, 'protected', lambda *args, **kwargs: None)
    monkeypatch.setattr(wake.time, 'time', lambda: 1795810000)
    scheduled = []
    commands = []

    def run(argv):
        commands.append(argv)
        if argv == ['/usr/bin/pmset', '-g', 'sched']:
            return '\n'.join(f" [0] wake at {dt.datetime.strptime(date, '%m/%d/%y %H:%M:%S').strftime('%m/%d/%Y %H:%M:%S')} by '{owner}'" for date, owner in scheduled)
        if argv[1:3] == ['schedule', 'wake']:
            scheduled.append(tuple(argv[3:5]))
        elif argv[1:4] == ['schedule', 'cancel', 'wake']:
            scheduled.remove(tuple(argv[4:6]))
        else:
            raise AssertionError(argv)
        return ''

    monkeypatch.setattr(wake, 'run', run)
    return scheduled, commands


def test_arm_retries_same_timer_and_cancel_targets_only_owned_event(fixture):
    scheduled, commands = fixture
    unrelated = ('11/27/26 23:59:59', 'other.utility')
    scheduled.append(unrelated)
    first = wake.operate('arm', '123-1', 2100, 'fixture')
    assert first['wakeAt'] == 1795812100
    assert wake.operate('arm', '123-1', 2100, 'fixture') == first
    assert len([cmd for cmd in commands if cmd[1:3] == ['schedule', 'wake']]) == 1
    assert wake.operate('cancel', '123-1', None, 'fixture')['status'] == 'ok'
    assert scheduled == [unrelated]
    assert wake.operate('cancel', '123-1', None, 'fixture')['status'] == 'ok'
    assert all(cmd != ['/usr/bin/pmset', 'schedule', 'cancel'] for cmd in commands)


def test_another_run_cannot_replace_or_cancel_timer(fixture):
    wake.operate('arm', '123-1', 2100, 'fixture')
    for action in ['arm', 'cancel']:
        with pytest.raises(RuntimeError, match='Another run'):
            wake.operate(action, '999-1', 2100, 'fixture')


def test_already_fired_timer_cleanup_succeeds(fixture):
    scheduled, commands = fixture
    wake.operate('arm', '123-1', 2100, 'fixture')
    scheduled.clear()
    assert wake.operate('cancel', '123-1', None, 'fixture')['status'] == 'ok'
    assert not any(cmd[1:3] == ['schedule', 'cancel'] for cmd in commands)


def test_failed_verification_retains_recovery_record(fixture, monkeypatch):
    commands = []
    monkeypatch.setattr(wake, 'run', lambda argv: commands.append(argv) or '')
    with pytest.raises(RuntimeError, match='could not be verified'):
        wake.operate('arm', '123-1', 2100, 'fixture')
    record = json.loads((wake.DIRECTORY / 'wake.json').read_text())
    assert record['owner'] == 'ai.nightr.battery-lab.123-1'
    assert commands[1][1:3] == ['schedule', 'wake']


def test_cancel_race_with_fired_event_succeeds(fixture, monkeypatch):
    wake.operate('arm', '123-1', 2100, 'fixture')
    checks = iter([True, False, False])
    monkeypatch.setattr(wake, 'scheduled', lambda _: next(checks))
    def fail(_):
        raise subprocess.CalledProcessError(1, ['pmset'])
    monkeypatch.setattr(wake, 'run', fail)
    assert wake.operate('cancel', '123-1', None, 'fixture')['status'] == 'ok'


@pytest.mark.parametrize('arguments', [ ['arm', '../../x', '2100'], ['arm', '123-1', '60'], ['cancel', '123-1', '2100'] ])
def test_invalid_invocations_fail_before_authorization(arguments, monkeypatch):
    monkeypatch.setattr(wake, 'authorize', lambda: pytest.fail('must reject before authorization'))
    with pytest.raises(RuntimeError):
        wake.main(arguments)


def test_authorization_rejects_unprivileged_execution(monkeypatch):
    monkeypatch.setattr(wake.os, 'geteuid', lambda: 501)
    with pytest.raises(RuntimeError, match='installed isolated'):
        wake.authorize()


def test_protected_rejects_writable_or_symlink_paths(tmp_path):
    directory = tmp_path / 'writable'
    directory.mkdir(mode=0o777)
    path = directory / 'adapter'
    path.write_text('')
    with pytest.raises(RuntimeError, match='protected root ownership'):
        wake.protected(path)
