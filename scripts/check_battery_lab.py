#!/usr/bin/env python3
"""Drive the designated battery fixture from its separate always-on coordinator."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import time

import check_upgrade
from fetch_upgrade_candidates import candidate_report, checked_context

SCRIPTS = Path(__file__).resolve().parent
CONFIG = Path('/etc/nightr-battery-lab.json')
DISCHARGE_LIMIT = 1800
WAKE_LIMIT = 2400


class Offline(Exception):
    """The SSH transport is unavailable. Power-log evidence is still required."""


class Fixture:
    def __init__(self, run):
        metadata = CONFIG.lstat()
        if metadata.st_uid != 0 or not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o022:
            raise ValueError('Coordinator fixture configuration must be root-owned')
        config = json.loads(CONFIG.read_text())
        self.host = config['sshHost']
        self.fixture = config['fixtureID']
        if not all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', v) for v in (self.host, self.fixture)):
            raise ValueError('Invalid fixture ID or pinned SSH alias')
        self.switch = {}
        if config.get('chargerMode', 'timed-relay') == 'timed-relay':
            self.switch = {'on': config['chargerOn'], 'off-for': config['chargerOffFor']}
        elif config['chargerMode'] != 'cable':
            raise ValueError('Unknown charger mode')
        self.last_cable_prompt = None
        for action, command in self.switch.items():
            if (not isinstance(command, list) or not command or not all(isinstance(arg, str) for arg in command)
                    or not Path(command[0]).is_absolute() or not os.access(command[0], os.X_OK)):
                raise ValueError('Charger configuration requires an absolute executable and argument list')
            if sum(arg.count('{seconds}') for arg in command) != (1 if action == 'off-for' else 0):
                raise ValueError('Timed charger command requires one {seconds} argument substitution')
        self.common = ['--fixture-id', self.fixture, '--run-id', run]
        self.transport = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=4']
        self.remote = None

    def ssh(self, argv, *, data=None, timeout=20):
        try:
            result = subprocess.run(['ssh', *self.transport, self.host, shlex.join(map(str, argv))],
                                    input=data, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as err:
            raise Offline() from err
        if result.returncode == 255:
            raise Offline()
        if result.returncode:
            # SSH diagnostics may identify the physical host. Retain only the failed operation.
            raise RuntimeError(f'Fixture command failed ({result.returncode})')
        return result.stdout

    def identify(self):
        raw = self.ssh(['python3', '-', 'identify', *self.common],
                       data=(SCRIPTS / 'battery_lab_host.py').read_bytes())
        if json.loads(raw)['status'] != 'ready':
            raise ValueError('Physical fixture identity unverified')

    def charger(self, action, *args):
        if not self.switch:
            if self.last_cable_prompt != action:
                instruction = 'Reconnect' if action == 'on' else 'Unplug'
                print(f'::notice::{instruction} the test MacBook charger now. The runner checks the power log.', flush=True)
                self.last_cable_prompt = action
            return
        command = self.switch[action]
        if action == 'off-for':
            command = [arg.replace('{seconds}', str(args[0])) for arg in command]
        subprocess.run(command, timeout=15, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @contextmanager
    def stage(self, image):
        path = self.ssh(['/usr/bin/mktemp', '-d', '/tmp/nightr-battery.XXXXXXXX']).decode().strip()
        if not re.fullmatch(r'/tmp/nightr-battery\.[a-zA-Z0-9]{8}', path):
            raise ValueError('Unexpected staging path')
        self.remote = path
        try:
            files = [SCRIPTS / name for name in ('battery_lab_host.py', 'install_lab_candidate.py',
                                                 'verify_release.py', 'nightr_install.py')]
            subprocess.run(['scp', '-q', *self.transport, *files, image, f'{self.host}:{path}/'],
                           check=True, timeout=600, capture_output=True)
            yield
        finally:
            self.ssh(['/bin/rm', '-rf', path])

    def install(self, image, team, version, sha, digest):
        result = json.loads(self.ssh(['python3', f'{self.remote}/install_lab_candidate.py', *self.common,
                                      '--dmg', f'{self.remote}/{image.name}', '--team-id', team, '--version', version,
                                      '--commit', sha, '--sha256', digest], timeout=880))
        if not re.fullmatch(r'[0-9a-f]{40}', result['cdhash']):
            raise ValueError('Installed code identity missing')
        return result['cdhash']

    def probe(self, command, *args):
        try:
            return json.loads(self.ssh(['python3', f'{self.remote}/battery_lab_host.py', command,
                                        *self.common, *args], timeout=40))
        except RuntimeError as error:
            raise RuntimeError(f'Fixture {command} failed: {error}') from error


def timestamp(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def verify_sleep(observed, first_low, began, cutoff):
    values = [observed.get(key) for key in ('lowAt', 'releasedAt', 'sleptAt', 'wokeAt')]
    if not all(timestamp(value) for value in values):
        raise ValueError('Missing cutoff, hold release, system sleep or full wake')
    low, release, sleep, wake = values
    first = min(first_low, low) if first_low is not None else low
    percent = observed.get('lowPercent')
    if type(percent) is not int or not 0 <= percent < cutoff or observed.get('cutoff') != cutoff:
        raise ValueError('Missing below-cutoff battery charge')
    # pmset timestamps have whole-second precision. The app observation is subsecond.
    if not (int(began) <= int(first) <= int(low) <= release <= sleep < wake and sleep - int(first) <= 60):
        raise ValueError('Power events out of order or outside the 60-second sleep window')
    if observed.get('competitorActive') is not True:
        raise ValueError('Missing competing idle assertion during the sleep test')
    return dict(firstLowAt=first, observedCharge=percent, releasedAt=release, sleptAt=sleep, wokeAt=wake)


def run_cycle(fixture, version, cdhash, report, now=time.monotonic, wait=time.sleep):
    identity = ['--version', version, '--cdhash', cdhash]
    fixture.probe('preflight', *identity)
    began_wait = now()
    try:
        report['stage'] = 'prepare'
        ready = fixture.probe('prepare', *identity)
        cutoff = ready['cutoff']
        if (ready.get('holding') is not True or ready.get('competitorActive') is not True
                or ready.get('onBattery') is not False or type(cutoff) is not int
                or not 40 <= ready['batteryPercent'] <= 100 or cutoff != ready['batteryPercent'] - 1
                or not timestamp(ready.get('began'))):
            raise ValueError('Fixture did not establish active protection and the competing assertion on AC')
        report.update(stage='discharge', cutoff=cutoff, startingCharge=ready['batteryPercent'])
        # The adapter must re-energize independently even if this process or SSH dies.
        fixture.charger('off-for', DISCHARGE_LIMIT)
        charging = False
        saw_battery = False
        first_low = None
        low_deadline = None
        while now() - began_wait < WAKE_LIMIT:
            try:
                observation = fixture.probe('observe' if first_low is not None or charging else 'sample')
            except Offline:
                # Loss of connectivity is a cue to restore AC, never proof of sleep.
                if not charging:
                    fixture.charger('on')
                    charging = True
                wait(3)
                continue
            saw_battery |= observation.get('onBattery') is True or timestamp(observation.get('lowAt'))
            if not charging and not saw_battery and now() - began_wait > 300:
                raise ValueError('MacBook did not switch to battery within five minutes')
            if timestamp(observation.get('lowAt')) and first_low is None:
                first_low = observation['lowAt']
                low_deadline = now() + 60
            if (observation.get('onBattery') is True and type(observation.get('batteryPercent')) is int
                    and observation['batteryPercent'] < cutoff and timestamp(observation.get('sampledAt'))):
                measurement = observation['sampledAt']
                first_low = measurement if first_low is None else min(first_low, measurement)
                if low_deadline is None:
                    low_deadline = now() + 60
            if observation.get('sleptAt') is not None and not charging:
                fixture.charger('on')
                charging = True
            if observation.get('wokeAt') is not None:
                report.update(verify_sleep(observation, first_low, ready['began'], cutoff))
                if observation.get('onBattery') is False and observation.get('holding') is True:
                    report['resumedOnAC'] = True
                    return
            if not charging and ((low_deadline is not None and now() > low_deadline)
                                 or now() - began_wait >= DISCHARGE_LIMIT):
                raise ValueError('Discharge deadline elapsed without system sleep evidence')
            wait(3)
        raise ValueError('Timed out waiting for system sleep, full wake and resumed protection on AC')
    finally:
        # An offline fixture can only clean up after its pre-armed wake. Keep the original
        # evidence even on failure, and require a successful cleanup for a passing receipt.
        try:
            fixture.charger('on')
        finally:
            cleanup_deadline = max(began_wait + WAKE_LIMIT, now() + 45)
            while True:
                try:
                    cleaned = fixture.probe('cleanup')
                    if cleaned.get('holding') is not False or cleaned.get('status') != 'ok':
                        raise RuntimeError('Fixture did not confirm stopped protection after cleanup')
                    break
                except Offline:
                    if now() >= cleanup_deadline:
                        raise RuntimeError('Fixture unreachable; cleanup pending')
                    wait(5)
            report['cleanup'] = 'passed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = dict(schemaVersion=1, status='failed', stage='provenance', version=args.version,
                  commit=os.environ.get('GITHUB_SHA'), runID=os.environ.get('GITHUB_RUN_ID'),
                  attempt=os.environ.get('GITHUB_RUN_ATTEMPT'))
    try:
        sha = checked_context(args.team_id)
        if (os.environ.get('GITHUB_WORKFLOW_REF') != 'agenthangar/nightr/.github/workflows/release.yml@refs/heads/main'
                or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
                or not all(re.fullmatch(r'[1-9][0-9]*', report[k] or '') for k in ('runID', 'attempt'))
                or not re.fullmatch(r'0\.[0-9]+\.[0-9]+', args.version)):
            raise ValueError('A protected main candidate dispatch is required')
        image = args.candidate / f'Nightr-{args.version}-universal.dmg'
        candidate_report(args.candidate / 'installer-acceptance.json', args.version, sha, report['runID'])
        manifest = check_upgrade.load_candidate(args.candidate / 'nightr-release.json', image, args.version)
        if manifest['teamID'] != args.team_id:
            raise ValueError('Candidate signing team differs from the configured team')
        report['dmgSHA256'] = manifest['asset']['sha256']
        report['stage'] = 'identify'
        fixture = Fixture(f"{report['runID']}-{report['attempt']}")
        # Lock the root-owned fixture descriptor across processes on this coordinator.
        with CONFIG.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fixture.identify()
            report['stage'] = 'transfer'
            with fixture.stage(image):
                report['stage'] = 'install'
                cdhash = fixture.install(image, args.team_id, args.version, sha, report['dmgSHA256'])
                report.update(cdhash=cdhash, stage='preflight')
                run_cycle(fixture, args.version, cdhash, report)
        report.update(status='passed', stage='complete')
    except Exception as error:
        # Keep host names, credentials, subprocess argv and personal logs off GitHub.
        report['error'] = str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__
        return 1
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        summary = f"Battery acceptance **{report['status']}** at {report['stage']}."
        if report['status'] == 'passed':
            seconds = report['sleptAt'] - int(report['firstLowAt'])
            summary += f" Charge {report['observedCharge']}%, cutoff {report['cutoff']}%, system sleep in {seconds:.0f}s. Full wake, resumed hold on AC and cleanup verified."
        print(summary)
        if location := os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(location, 'a') as stream:
                print(summary, file=stream)
    return 0


if __name__ == '__main__':
    def cancelled(_signum, _frame):
        raise RuntimeError('Coordinator run interrupted')
    signal.signal(signal.SIGTERM, cancelled)
    sys.exit(main())
