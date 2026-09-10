#!/usr/bin/env python3
# Version: 2.1.0
"""Bounded, root-local capture for BootPrep entry points (Python 3.9+)."""
# SPDX-License-Identifier: GPL-3.0-or-later
import datetime
import fcntl
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile

LOG_DIR = Path('/var/lib/bootprep/logs')
KEEP = 10
LIMIT = 1024 * 1024
HEAD = 64 * 1024
MARKER = b'\n[... older middle output omitted: log size limit reached ...]\n'


class BoundedLog:
    def __init__(self, file):
        self.file = file
        self.data = b''
        self.truncated = False

    def write(self, data):
        if not self.truncated and len(self.data) + len(data) <= LIMIT:
            self.data += data
            self.file.write(data)
        else:
            tail_size = LIMIT - HEAD - len(MARKER)
            prefix = self.data[:HEAD]
            tail = (self.data + data)[-tail_size:]
            self.data = prefix + MARKER + tail
            self.truncated = True
            self.file.seek(0)
            self.file.write(self.data)
            self.file.truncate()
        self.file.flush()


def secure_directory(directory):
    for part in reversed((directory, *directory.parents)):
        if part == Path('/'):
            continue
        try:
            info = part.lstat()
        except FileNotFoundError:
            part.mkdir(mode=0o700)
            info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()) or info.st_mode & 0o022:
            raise RuntimeError('Unsafe logging directory: ' + str(part))
    directory.chmod(0o700)


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def capture(command, directory=LOG_DIR):
    secure_directory(directory)
    lockfd = os.open(directory / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lockfd, 'r+b') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise RuntimeError('Unsafe BootPrep log lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another logged BootPrep operation is running') from None
        logs = [p for p in directory.glob('bootprep-*.log') if stat.S_ISREG(p.lstat().st_mode)]
        logs.sort(key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
        for old in logs[KEEP - 1:]:
            old.unlink()
        prefix = 'bootprep-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-')
        fd, filename = tempfile.mkstemp(prefix=prefix, suffix='.log', dir=directory)
        print('[INFO] Run log: ' + filename, flush=True)
        with os.fdopen(fd, 'w+b') as file:
            log = BoundedLog(file)
            log.write(('Started: ' + timestamp() + '\nCommand: ' + shlex.join(command) + '\n').encode())
            env = dict(os.environ, BOOTPREP_LOG_ACTIVE='1', BOOTPREP_LOG_FILE=filename)
            child = None
            handlers = {}
            try:
                child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         env=env, start_new_session=True)
                def forward(signum, _frame):
                    try:
                        os.killpg(child.pid, signum)
                    except ProcessLookupError:
                        pass
                for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    handlers[sig] = signal.signal(sig, forward)
                visible = True
                while True:
                    chunk = child.stdout.read1(16384)
                    if not chunk:
                        break
                    log.write(chunk)
                    if visible:
                        try:
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()
                        except BrokenPipeError:
                            visible = False
                child.stdout.close()
                code = child.wait()
                if code < 0:
                    code = 128 - code
            except OSError as error:
                log.write(('Logging/execution error: ' + str(error) + '\n').encode())
                if child is not None and child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    child.wait()
                code = 1
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
            log.write(('\nFinished: ' + timestamp() + '\nResult: ' + ('SUCCESS' if code == 0 else 'FAILED')
                       + ' (exit ' + str(code) + ')\n').encode())
            os.fsync(file.fileno())
        if code:
            print('[ERROR] BootPrep operation failed. Run log: ' + filename, file=sys.stderr)
        return code


def main():
    if os.geteuid() != 0:
        print('BootPrep logging requires root.', file=sys.stderr)
        return 1
    if len(sys.argv) < 2:
        print('Missing command to log.', file=sys.stderr)
        return 1
    try:
        return capture(sys.argv[1:])
    except (OSError, RuntimeError) as error:
        print('[ERROR] Cannot maintain BootPrep run log: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
