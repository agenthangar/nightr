#!/Library/Developer/CommandLineTools/usr/bin/python3 -IS
"""Fixed wake timer for a provisioned Nightr battery fixture.

Install this file as root:wheel 0755 at
/Library/PrivilegedHelperTools/ai.nightr.battery-lab-wake.py. Permit only the
fixture login to run the fixed CLT interpreter and adapter through sudo.
Set marker wakeCommand to ['/usr/bin/sudo', '-n', '/Library/Developer/CommandLineTools/usr/bin/python3', '-IS',
'/Library/PrivilegedHelperTools/ai.nightr.battery-lab-wake.py'].
The marker's hardwareUUID/login/fixtureID pin this operation to one fixture.
The provisioner must verify a full wake on battery before wakeVerified=true.
"""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import time

INSTALLED = Path('/Library/PrivilegedHelperTools/ai.nightr.battery-lab-wake.py')
MARKER = Path('/Library/Application Support/NightrBatteryLab/fixture.json')
DIRECTORY = Path('/private/var/db/nightr-battery-lab')
OWNER_PREFIX = 'ai.nightr.battery-lab.'


def run(argv):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=10,
                                   env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'})


def protected(path, directory=False):
    for item in [path, *path.parents]:
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError('Wake fixture files must have protected root ownership')
    mode = path.stat().st_mode
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise RuntimeError('Unexpected fixture file type')


def authorize():
    if os.geteuid() != 0 or not sys.flags.isolated or not sys.flags.no_site or Path(__file__).absolute() != INSTALLED:
        raise RuntimeError('Use the installed isolated fixture wake adapter through sudo')
    protected(INSTALLED)
    protected(Path(sys.executable).resolve())
    protected(MARKER)
    marker = json.loads(MARKER.read_text())
    caller = os.environ.get('SUDO_UID', '')
    if not caller.isdecimal() or int(caller) == 0:
        raise RuntimeError('A designated nonroot sudo caller is required')
    uid = int(caller)
    if pwd.getpwuid(uid).pw_name != marker.get('login') or os.stat('/dev/console').st_uid != uid:
        raise RuntimeError('Caller must be the designated console login')
    hardware = run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'])
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', hardware)
    if not match or marker.get('hardwareUUID') != match[1] or not marker.get('fixtureID'):
        raise RuntimeError('Hardware fixture identity mismatch')
    return marker['fixtureID']


def validate_record(record, fixture):
    if record.get('fixtureID') != fixture or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', record.get('runID', '')):
        raise RuntimeError('Invalid wake recovery record')
    when = record.get('wakeAt')
    if not isinstance(when, int) or record.get('owner') != OWNER_PREFIX + record['runID']:
        raise RuntimeError('Invalid wake ownership record')
    date = dt.datetime.fromtimestamp(when).strftime('%m/%d/%y %H:%M:%S')
    if record.get('date') != date:
        raise RuntimeError('Invalid recorded wake date')


def scheduled(record):
    output = run(['/usr/bin/pmset', '-g', 'sched'])
    display_date = dt.datetime.fromtimestamp(record['wakeAt']).strftime('%m/%d/%Y %H:%M:%S')
    pattern = re.compile(r'\bwake\s+at\s+' + re.escape(display_date) + r'\s+by\s+[\'\"]' + re.escape(record['owner']) + r'[\'\"](?:\s|$)')
    return any(pattern.search(line) for line in output.splitlines())


def save(record):
    temporary = DIRECTORY / 'wake.tmp'
    fd = os.open(temporary, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(record, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, DIRECTORY / 'wake.json')
    fd = os.open(DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def operate(action, run_id, delay, fixture):
    path = DIRECTORY / 'wake.json'
    record = None
    if path.exists() or path.is_symlink():
        protected(path)
        record = json.loads(path.read_text())
        validate_record(record, fixture)
        if record['runID'] != run_id:
            raise RuntimeError('Another run owns the wake timer; clean up that run first')
    if action == 'arm':
        if record is None:
            when = int(time.time()) + delay
            record = {'fixtureID': fixture, 'runID': run_id, 'owner': OWNER_PREFIX + run_id,
                      'wakeAt': when, 'date': dt.datetime.fromtimestamp(when).strftime('%m/%d/%y %H:%M:%S')}
            save(record)
        if record['wakeAt'] <= time.time():
            raise RuntimeError('Wake timer expired; clean up before starting another run')
        if not scheduled(record):
            run(['/usr/bin/pmset', 'schedule', 'wake', record['date'], record['owner']])
        if not scheduled(record):
            raise RuntimeError('Scheduled wake could not be verified')
        return {'status': 'ok', 'wakeAt': record['wakeAt'], 'owner': record['owner']}
    if record is not None:
        if scheduled(record):
            try:
                run(['/usr/bin/pmset', 'schedule', 'cancel', 'wake', record['date'], record['owner']])
            except subprocess.CalledProcessError:
                # The timer may have fired between observation and cancellation.
                if scheduled(record):
                    raise
        if scheduled(record):
            raise RuntimeError('Wake cancellation could not be verified')
        path.unlink()
    return {'status': 'ok'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['arm', 'cancel'])
    parser.add_argument('run_id')
    parser.add_argument('delay', nargs='?', type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', args.run_id):
        raise RuntimeError('Invalid run ID')
    if (args.action == 'arm' and args.delay != 2100) or (args.action == 'cancel' and args.delay is not None):
        raise RuntimeError('Arm requires exactly 2100 seconds; cancel accepts only the run ID')
    fixture = authorize()
    DIRECTORY.mkdir(mode=0o700, exist_ok=True)
    protected(DIRECTORY, directory=True)
    if DIRECTORY.stat().st_mode & 0o077:
        raise RuntimeError('Wake recovery directory must be private')
    lock = os.open(DIRECTORY / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(lock)
        if metadata.st_uid != 0 or not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise RuntimeError('Unsafe wake lock')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return operate(args.action, args.run_id, args.delay, fixture)
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        print(json.dumps(main()))
    except Exception as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}))
        raise SystemExit(1)
