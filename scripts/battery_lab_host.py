#!/usr/bin/env python3
"""Probe for a designated battery lab MacBook, controlled from an awake host.

Provision /Library/Application Support/NightrBatteryLab/fixture.json, owned by
root with no group/world write, containing fixtureID, hardwareUUID, login,
wakeVerified=true and wakeCommand=["/absolute/root-owned/wake-adapter"].
The adapter accepts `arm RUN_ID 2100` and `cancel RUN_ID`. Its wake must have been
verified on this hardware with lid open before setting wakeVerified. Each arm
must arrange a full wake within 2100 seconds, including on battery. The coordinator
restores charging independently on every exit. Use a dedicated console login.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import pwd
import re
import signal
import shutil
import stat
import subprocess
import time

APP = Path('/Applications/Nightr.app')
CLI = APP / 'Contents/MacOS/nightr'
MARKER = Path('/Library/Application Support/NightrBatteryLab/fixture.json')
STATE_DIRECTORY = Path.home() / '.local/state/nightr-battery-lab'


def run(argv, environment=None):
    return subprocess.check_output(argv, text=True, timeout=15, stderr=subprocess.STDOUT, env=environment)


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def battery():
    text = run(['/usr/bin/pmset', '-g', 'batt'])
    match = re.search(r'InternalBattery[^\n]*?\b(\d+)%;', text)
    source = re.search(r"^Now drawing from '(AC Power|Battery Power)'", text)
    if not source or not match or not 0 <= int(match[1]) <= 100:
        raise RuntimeError('Internal battery unavailable')
    return {'batteryPercent': int(match[1]), 'onBattery': source[1] == 'Battery Power', 'sampledAt': time.time()}


def protected_file(path):
    for current in [path, *path.parents]:
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise RuntimeError('Fixture configuration must be root-owned and protected')
    if not path.is_file():
        raise RuntimeError('Fixture configuration must be a regular file')


def identify(fixture_id, require_ready=True):
    protected_file(MARKER)
    marker = json.loads(MARKER.read_text())
    uuid = run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'])
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', uuid)
    console_uid = os.stat('/dev/console').st_uid
    if (marker.get('fixtureID') != fixture_id or marker.get('login') != pwd.getpwuid(os.getuid()).pw_name
            or not match or marker.get('hardwareUUID') != match[1]
            or console_uid != os.getuid() or os.getuid() == 0
            or marker.get('wakeVerified') is not True):
        raise RuntimeError('Dedicated fixture, console login or verified wake mismatch')
    wake = marker.get('wakeCommand')
    if (not isinstance(wake, list) or not wake or not all(isinstance(x, str) for x in wake)
            or not Path(wake[0]).is_absolute()):
        raise RuntimeError('Fixture wakeCommand must be an absolute argv array')
    protected_file(Path(wake[0]))
    power = battery()
    if require_ready and (power['onBattery'] or power['batteryPercent'] < 40):
        raise RuntimeError('Fixture requires AC and at least 40% charge')
    lid = run(['/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '4'])
    if require_ready and '"AppleClamshellState" = No' not in lid:
        raise RuntimeError('Open lid could not be confirmed')
    if os.environ.get('XDG_CONFIG_HOME') or os.environ.get('XDG_STATE_HOME'):
        raise RuntimeError('Dedicated login requires default configuration paths')
    return marker, power


def controller():
    reply = json.loads(run([str(CLI), 'status', '--json']))
    status = reply.get('status')
    if not status or reply.get('error'):
        raise RuntimeError('Controller status unavailable')
    return status


def verify_candidate(version, cdhash):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)])
    signature = run(['/usr/bin/codesign', '-dv', '--verbose=4', str(APP)])
    if not re.search(r'^CDHash=' + re.escape(cdhash) + '$', signature, re.M):
        raise RuntimeError('Candidate CDHash mismatch')
    actual = run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', str(APP / 'Contents/Info.plist')]).strip()
    if actual != version:
        raise RuntimeError('Candidate version mismatch')


def stopped():
    if CLI.exists():
        status = controller()
        if status['state']['desiredEnabled'] or status['holding'] or status.get('forceMode'):
            raise RuntimeError('Dedicated controller must be confirmed stopped')
    else:
        # Fresh fixtures can be identified before the candidate is installed.
        processes = run(['/bin/ps', '-axo', 'comm='])
        if any('NightrApp' in item or 'nightr-native' in item for item in processes.splitlines()):
            raise RuntimeError('Existing Nightr process must be stopped before installation')


def timestamp(text):
    for fmt in ['%Y-%m-%d %H:%M:%S.%f%z', '%Y-%m-%d %H:%M:%S%z', '%Y-%m-%d %H:%M:%S %z']:
        try:
            return dt.datetime.strptime(text.strip(), fmt).timestamp()
        except ValueError:
            pass
    return None


def events(text, began, assertion_pid=None):
    result = []
    for line in text.splitlines():
        when = timestamp(line[:25])
        if when is None or when < began:
            continue
        if re.search(r'\bSleep\s+Entering Sleep state due to [\'\"]Software Sleep(?: pid=\d+)?[\'\"]', line) and 'Using Batt' in line:
            result.append({'kind': 'sleep', 'at': when})
        elif re.search(r'\bWake\s+Wake from|\bDarkWake to FullWake\b', line):
            result.append({'kind': 'wake', 'at': when})
        elif 'Released PreventUserIdleSystemSleep "Nightr coding-agent protection"' in line and '(NightrApp)' in line:
            result.append({'kind': 'release', 'at': when})
        elif assertion_pid and f'PID {assertion_pid}(caffeinate)' in line and 'Released PreventUserIdleSystemSleep' in line:
            result.append({'kind': 'competitor_released', 'at': when})
    return result


def evidence(power_log, structured_log, state):
    observed = events(power_log, state['began'], state['assertionPID'])
    low = []
    for item in structured_log:
        message = item.get('eventMessage', '')
        match = re.fullmatch(r'battery-cutoff percent=(\d+) cutoff=(\d+)', message)
        when = timestamp(item.get('timestamp', ''))
        if (match and when is not None and when >= state['began']
                and int(match[2]) == state['cutoff'] and int(match[1]) < state['cutoff']):
            low.append((when, int(match[1])))
    low_at, percent = min(low) if low else (None, None)
    release = next((x['at'] for x in observed if x['kind'] == 'release'), None)
    sleep = next((x['at'] for x in observed if x['kind'] == 'sleep' and low_at is not None
                  and release is not None and release <= x['at'] and low_at <= x['at'] + 1), None)
    wake = next((x['at'] for x in observed if x['kind'] == 'wake' and sleep is not None and x['at'] >= sleep), None)
    competing = (state.get('competingAssertionVerified', False) and sleep is not None
                 and sleep < state['began'] + 2550) and not any(
        x['kind'] == 'competitor_released' and (sleep is None or x['at'] <= sleep) for x in observed)
    return {'lowAt': low_at, 'lowPercent': percent, 'releasedAt': release, 'sleptAt': sleep, 'wokeAt': wake,
            'competitorActive': competing}


def state_directory():
    STATE_DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    metadata = STATE_DIRECTORY.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError('Fixture state directory must be private')
    return STATE_DIRECTORY / 'run.json'


def owned_state(path, args):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError('Fixture state file must be private')
    value = json.loads(path.read_text())
    if value['fixtureID'] != args.fixture_id or value['runID'] != args.run_id:
        raise RuntimeError('Fixture run ownership mismatch')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['identify', 'preflight', 'prepare', 'sample', 'observe', 'cleanup'])
    parser.add_argument('--fixture-id', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--version')
    parser.add_argument('--cdhash')
    parser.add_argument('--cutoff', type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', args.run_id):
        raise RuntimeError('Invalid run ID')
    marker, power = identify(args.fixture_id, require_ready=args.command in ['identify', 'preflight', 'prepare'])
    path = state_directory()
    result = dict(status='ok', arch=platform.machine(), **power)
    if args.command in ['identify', 'preflight']:
        stopped()
        if path.exists():
            raise RuntimeError('Prior fixture state requires cleanup')
        if args.command == 'preflight':
            if not args.version or not args.cdhash:
                raise RuntimeError('Candidate version and CDHash required')
            verify_candidate(args.version, args.cdhash)
            run([str(CLI), 'setup', '--check'])
        result['status'] = 'ready'
    elif args.command == 'prepare':
        if not args.version or not args.cdhash:
            raise RuntimeError('Candidate version and CDHash required')
        verify_candidate(args.version, args.cdhash)
        stopped()
        if path.exists():
            raise RuntimeError('Prior fixture state requires cleanup')
        cutoff = args.cutoff if args.cutoff is not None else power['batteryPercent'] - 1
        if cutoff != power['batteryPercent'] - 1:
            raise RuntimeError('Cutoff must be one point below current charge')
        state = {'fixtureID': args.fixture_id, 'runID': args.run_id, 'began': time.time(), 'cutoff': cutoff,
                 'assertionPID': None,
                 'competingAssertionVerified': False}
        atomic_json(path, state)
        settings = dict(battery_protection=True, battery_below=cutoff, forever=True, lock=False)
        config_home = STATE_DIRECTORY / args.run_id / 'config'
        config_path = config_home / 'nosleep/config.json'
        config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_json(config_path, settings)
        run(marker['wakeCommand'] + ['arm', args.run_id, '2100'])
        process = subprocess.Popen(['/usr/bin/caffeinate', '-i', '-t', '2550'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        state['assertionPID'] = process.pid
        atomic_json(path, state)
        for _ in range(30):
            assertions = run(['/usr/bin/pmset', '-g', 'assertions'])
            if re.search(r'pid\s+' + str(process.pid) + r'\(caffeinate\).*PreventUserIdleSystemSleep', assertions):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Competing assertion was not established')
        state['competingAssertionVerified'] = True
        atomic_json(path, state)
        environment = dict(os.environ, XDG_CONFIG_HOME=str(config_home))
        run([str(CLI), 'start'], environment=environment)
        for _ in range(30):
            status = controller()
            if (status['holding'] and status['settings']['battery_protection']
                    and status['settings']['battery_below'] == cutoff
                    and status['settings']['forever']):
                result.update(cutoff=cutoff, began=state['began'], holding=True, assertionPID=process.pid, competitorActive=True)
                break
            time.sleep(0.2)
        else:
            raise RuntimeError('Candidate did not acquire protection')
    elif args.command == 'sample':
        owned_state(path, args)
    elif args.command == 'observe':
        state = owned_state(path, args)
        start = dt.datetime.fromtimestamp(state['began']).strftime('%Y-%m-%d %H:%M:%S')
        structured = json.loads(run(['/usr/bin/log', 'show', '--style', 'json', '--start', start,
                                     '--predicate', 'subsystem == "ai.nightr" AND category == "battery"']))
        result.update(evidence(run(['/usr/bin/pmset', '-g', 'log']), structured, state))
        result.update(cutoff=state['cutoff'], holding=controller()['holding'])
    else:
        # Stop owned test activity even if a cable or relay has not restored AC.
        if path.exists():
            state = owned_state(path, args)
            run([str(CLI), 'stop'])
            if state['assertionPID']:
                process = subprocess.run(['/bin/ps', '-p', str(state['assertionPID']), '-o', 'command='], capture_output=True, text=True, timeout=5)
                if process.stdout.strip() == '/usr/bin/caffeinate -i -t 2550':
                    os.kill(state['assertionPID'], signal.SIGTERM)
            run(marker['wakeCommand'] + ['cancel', args.run_id])
            status = controller()
            if status['holding'] or status['state']['desiredEnabled']:
                raise RuntimeError('Controller did not confirm stopped during cleanup')
            shutil.rmtree(STATE_DIRECTORY / args.run_id, ignore_errors=True)
            path.unlink()
        result['holding'] = controller()['holding']
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(main()))
    except Exception as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}))
        raise SystemExit(1)
