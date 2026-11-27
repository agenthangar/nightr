import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('battery_lab_host', Path(__file__).resolve().parents[1] / 'scripts/battery_lab_host.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def test_power_log_requires_actual_system_sleep_and_filters_old_events():
    began = 1795800000
    text = '''2026-11-27 00:00:00 -0800 Sleep Entering Sleep state due to 'Software Sleep': Using Batt (Charge:49%)
2026-11-27 12:00:01 -0800 Assertions PID 3(NightrApp) Released PreventUserIdleSystemSleep "Nightr coding-agent protection"
2026-11-27 12:00:02 -0800 Display Display is turned off
2026-11-27 12:00:03 -0800 Sleep Entering Sleep state due to 'Software Sleep': Using Batt (Charge:49%)
2026-11-27 12:00:10 -0800 Wake Wake from Normal Sleep
'''
    assert [event['kind'] for event in probe.events(text, began)] == ['release', 'sleep', 'wake']


def test_battery_reads_charge_and_source(monkeypatch):
    monkeypatch.setattr(probe, 'run', lambda _: "Now drawing from 'Battery Power'\n -InternalBattery-0 49%; discharging;")
    result = probe.battery()
    assert result['batteryPercent'] == 49
    assert result['onBattery'] is True
    assert result['sampledAt'] > 0


def test_evidence_correlates_low_release_sleep_and_full_wake():
    began = probe.timestamp('2026-11-27 12:00:00 -0800')
    state = {'began': began, 'cutoff': 50, 'assertionPID': 9, 'competingAssertionVerified': True}
    power = '''2026-11-27 12:00:01 -0800 Assertions PID 3(NightrApp) Released PreventUserIdleSystemSleep "Nightr coding-agent protection"
2026-11-27 12:00:02 -0800 Sleep Entering Sleep state due to 'Software Sleep': Using Batt (Charge:49%)
2026-11-27 12:00:03 -0800 DarkWake DarkWake from Normal Sleep
2026-11-27 12:00:08 -0800 Wake Wake from Normal Sleep
'''
    structured = [{'timestamp': '2026-11-27 12:00:00.900000-0800', 'eventMessage': 'battery-cutoff percent=49 cutoff=50'}]
    result = probe.evidence(power, structured, state)
    assert result['lowPercent'] == 49
    assert result['releasedAt'] == began + 1
    assert result['sleptAt'] == began + 2
    assert result['wokeAt'] == began + 8
    assert result['competitorActive']
    fullwake = power.replace('Wake Wake from Normal Sleep', 'DarkWake to FullWake from Normal Sleep')
    assert probe.evidence(fullwake, structured, state)['wokeAt'] == began + 8
    assert probe.evidence(power.replace('Using Batt', 'Using AC'), structured, state)['sleptAt'] is None
    assert probe.evidence(power, [], state)['sleptAt'] is None
    released = "2026-11-27 12:00:01 -0800 Assertions PID 9(caffeinate) Released PreventUserIdleSystemSleep\n"
    assert not probe.evidence(released + power, structured, state)['competitorActive']


def test_cleanup_refuses_another_run(tmp_path):
    from types import SimpleNamespace
    import json
    import pytest
    path = tmp_path / 'run.json'
    path.write_text(json.dumps({'fixtureID': 'fixture', 'runID': 'other'}))
    path.chmod(0o600)
    with pytest.raises(RuntimeError, match='ownership mismatch'):
        probe.owned_state(path, SimpleNamespace(fixture_id='fixture', run_id='mine'))


def test_prepare_and_cleanup_use_private_config_and_matching_contract(tmp_path, monkeypatch):
    import json
    from types import SimpleNamespace
    private = tmp_path / 'state'
    private.mkdir(mode=0o700)
    original = tmp_path / '.config/nosleep/config.json'
    original.parent.mkdir(parents=True)
    original.write_text('{"battery_below":20}')
    monkeypatch.setattr(probe, 'STATE_DIRECTORY', private)
    monkeypatch.setenv('HOME', str(tmp_path))
    monkeypatch.setattr(probe, 'verify_candidate', lambda *_: None)
    power = {'batteryPercent': 75, 'onBattery': False, 'sampledAt': 1234}
    marker = {'wakeCommand': ['/fixture/wake']}
    monkeypatch.setattr(probe, 'identify', lambda *args, **kwargs: (marker, power))
    active = {'holding': False, 'state': {'desiredEnabled': False}, 'settings': {}}
    monkeypatch.setattr(probe, 'controller', lambda: active)
    monkeypatch.setattr(probe, 'stopped', lambda: None)
    calls = []

    def command(argv, environment=None):
        calls.append(argv)
        if argv[-1] == 'assertions':
            return 'pid 123(caffeinate): [0x1] PreventUserIdleSystemSleep named: test'
        if argv[-1] == 'start':
            config = Path(environment['XDG_CONFIG_HOME']) / 'nosleep/config.json'
            settings = json.loads(config.read_text())
            assert settings['battery_below'] == 74
            active.update(holding=True, state={'desiredEnabled': True}, settings=settings)
        if argv[-1] == 'stop':
            active.update(holding=False, state={'desiredEnabled': False})
        return ''

    monkeypatch.setattr(probe, 'run', command)
    monkeypatch.setattr(probe.subprocess, 'Popen', lambda *args, **kwargs: SimpleNamespace(pid=123))
    monkeypatch.setattr(probe.subprocess, 'run', lambda *args, **kwargs: SimpleNamespace(stdout=''))
    common = ['--fixture-id', 'fixture', '--run-id', '123-1']
    prepared = probe.main(['prepare', *common, '--version', '0.1.3', '--cdhash', 'abcd'])
    assert prepared['status'] == 'ok'
    assert prepared['competitorActive'] is True
    assert prepared['holding'] is True
    assert prepared['cutoff'] == 74
    assert prepared['sampledAt'] == 1234
    assert original.read_text() == '{"battery_below":20}'
    assert probe.main(['cleanup', *common])['holding'] is False
    assert not (private / 'run.json').exists()
    assert not (private / '123-1').exists()
    assert probe.main(['cleanup', *common])['status'] == 'ok'
    assert ['/fixture/wake', 'cancel', '123-1'] in calls
    assert original.read_text() == '{"battery_below":20}'
