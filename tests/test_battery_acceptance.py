"""Release acceptance exercises fake fixtures only."""
from pathlib import Path
import sys

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import check_battery_lab as lab


class Fixture:
    def __init__(self, observations):
        self.observations = iter(observations)
        self.calls = []
        self.clock = 0

    def charger(self, *command):
        self.calls.append(command)

    def probe(self, command, *_):
        self.calls.append(command)
        if command == 'preflight':
            return {'status': 'ready'}
        if command == 'prepare':
            return {'status': 'ok', 'cutoff': 74, 'began': 1234.5, 'onBattery': False,
                    'batteryPercent': 75, 'holding': True, 'competitorActive': True}
        if command == 'cleanup':
            return {'status': 'ok', 'holding': False}
        item = next(self.observations)
        if isinstance(item, Exception):
            raise item
        return item

    def wait(self, seconds):
        self.clock += seconds


EVIDENCE = {'cutoff': 74, 'lowAt': 1250.7, 'lowPercent': 73, 'releasedAt': 1250,
            'sleptAt': 1251, 'wokeAt': 1305, 'competitorActive': True,
            'holding': True, 'onBattery': False}


def exercise(fixture, report):
    lab.run_cycle(fixture, '0.1.2', 'd' * 40, report, lambda: fixture.clock, fixture.wait)


def test_sleep_wake_and_resume_require_positive_evidence():
    low = dict(batteryPercent=73, onBattery=True, sampledAt=1249.1)
    fixture = Fixture([low, lab.Offline(), EVIDENCE])
    report = {}
    exercise(fixture, report)
    assert report['firstLowAt'] == 1249.1
    assert report['resumedOnAC'] and report['cleanup'] == 'passed'
    assert fixture.calls == ['preflight', 'prepare', ('off-for', 1800), 'sample', 'observe',
                             ('on',), 'observe', ('on',), 'cleanup']


@pytest.mark.parametrize('change', [
    {'sleptAt': None}, {'lowPercent': 74}, {'releasedAt': None}, {'competitorActive': False},
    {'sleptAt': 1311, 'wokeAt': 1400}, {'releasedAt': 1255}, {'wokeAt': 1248},
])
def test_incomplete_or_late_evidence_fails_and_restores_fixture(change):
    fixture = Fixture([lab.Offline(), {**EVIDENCE, **change}])
    report = {}
    with pytest.raises(ValueError):
        exercise(fixture, report)
    assert fixture.calls[-2:] == [('on',), 'cleanup']
    assert 'resumedOnAC' not in report


def test_release_only_times_out_on_battery_even_if_controller_stopped_holding():
    low = dict(batteryPercent=73, onBattery=True, sampledAt=1249.1, holding=False)
    fixture = Fixture([low] * 30)
    with pytest.raises(ValueError, match='without system sleep'):
        exercise(fixture, {})
    assert fixture.calls[-2:] == [('on',), 'cleanup']


def test_cleanup_failure_fails_otherwise_successful_run(monkeypatch):
    fixture = Fixture([lab.Offline(), EVIDENCE])
    probe = fixture.probe
    monkeypatch.setattr(fixture, 'probe', lambda action, *args:
                        {'status': 'ok', 'holding': True} if action == 'cleanup' else probe(action, *args))
    with pytest.raises(RuntimeError, match='cleanup'):
        exercise(fixture, {})


def test_regular_outlet_prompts_for_cable_once_per_change(capsys, monkeypatch):
    fixture = object.__new__(lab.Fixture)
    fixture.switch = {}
    fixture.last_cable_prompt = None
    monkeypatch.setattr(lab.subprocess, 'run', lambda *_a, **_kw: pytest.fail('cable mode ran a relay command'))
    fixture.charger('off-for', 1800)
    fixture.charger('on')
    fixture.charger('on')
    output = capsys.readouterr().out
    assert output.count('Unplug') == 1
    assert output.count('Reconnect') == 1


def test_release_gate_consumes_exact_candidate_and_requires_hardware_success():
    jobs = yaml.safe_load((ROOT / '.github/workflows/release.yml').read_text())['jobs']
    candidate, battery = jobs['candidate'], jobs['battery-acceptance']
    assert battery['needs'] == 'candidate'
    assert battery['if'] == "github.ref == 'refs/heads/main'"
    assert 'continue-on-error' not in battery
    assert all('continue-on-error' not in step for step in battery['steps'])
    assert battery['runs-on']['group'] == 'nightr-battery-lab'
    assert battery['steps'][1]['with']['artifact-ids'] == '${{ needs.candidate.outputs.candidate-artifact }}'
    assert candidate['outputs']['candidate-artifact'] == '${{ steps.retain.outputs.artifact-id }}'
    assert battery['steps'][-1]['with']['if-no-files-found'] == 'error'
