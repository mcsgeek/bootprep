"""Unprivileged tests of bounded capture; no mounts or installed files touched."""
import importlib.util
import io
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'bootprep-log.py'
spec = importlib.util.spec_from_file_location('bootprep_log', HELPER)
logger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logger)

class LogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)/'logs'

    def capture(self, script):
        # Treat sandbox workspace ancestors as trusted in this test only.
        # The temporary log directory itself retains all security checks.
        runner = """import runpy,sys,os
from pathlib import Path
from unittest.mock import patch
m=runpy.run_path(sys.argv[1])
original=Path.lstat
def mapped(path):
    value=original(path)
    if path in Path(sys.argv[2]).parent.parents:
        fields=list(value); fields[4]=os.geteuid(); fields[0] &= ~0o022; return os.stat_result(fields)
    return value
with patch.object(Path,'lstat',mapped):
    sys.exit(m['capture']([sys.executable,'-c',sys.argv[3]],Path(sys.argv[2])))
"""
        return subprocess.run([sys.executable,'-c',runner,str(HELPER),str(self.directory),script],capture_output=True)

    def test_failure_status_output_and_final_record(self):
        result=self.capture('import sys; print("visible stdout"); print("visible stderr",file=sys.stderr); sys.exit(7)')
        self.assertEqual(result.returncode,7,result.stderr)
        self.assertIn(b'visible stdout',result.stdout)
        self.assertIn(b'visible stderr',result.stdout)
        log=next(self.directory.glob('*.log'))
        text=log.read_text()
        self.assertIn('Command:',text); self.assertIn('FAILED (exit 7)',text)
        self.assertEqual(log.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777,0o700)

    def test_size_bounded_preserves_head_tail_and_status(self):
        result=self.capture('print("FIRST RECORD"); print("x"*2200000); print("LAST RECORD")')
        self.assertEqual(result.returncode,0,result.stderr)
        data=next(self.directory.glob('*.log')).read_bytes()
        self.assertLessEqual(len(data),logger.LIMIT)
        for item in (b'FIRST RECORD',b'LAST RECORD',b'SUCCESS (exit 0)',logger.MARKER):
            self.assertIn(item,data)

    def test_bound_applies_after_every_chunk(self):
        file=io.BytesIO(); log=logger.BoundedLog(file)
        for _ in range(160):
            log.write(b'x'*16384)
            self.assertLessEqual(len(file.getvalue()),logger.LIMIT)

    def test_retention_and_no_duplicate_nested_log(self):
        for _ in range(12):
            result=self.capture('import os; assert os.environ["BOOTPREP_LOG_ACTIVE"]=="1"; print("nested marker inherited")')
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(list(self.directory.glob('*.log'))),10)

    def test_signal_failure_reported(self):
        result=self.capture('import os,signal; os.kill(os.getpid(),signal.SIGTERM)')
        self.assertEqual(result.returncode,143)
        self.assertIn('FAILED (exit 143)',next(self.directory.glob('*.log')).read_text())

    def test_concurrent_run_cannot_prune_or_start(self):
        self.directory.mkdir(mode=0o700)
        with (self.directory/'.lock').open('w+b') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=self.capture('print("must not run")')
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'Another logged BootPrep operation',result.stderr)
        self.assertEqual(list(self.directory.glob('*.log')),[])

    def test_symlink_directory_rejected(self):
        self.directory.symlink_to(Path(self.temp.name),target_is_directory=True)
        result=self.capture('print("must not run")')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn(b'must not run\n',result.stdout)

    def test_entrypoints_wrap_once_and_installer_installs_helper(self):
        for name in ('bootprep','bootprep-btrfs','99_bootprep','bootprep-install.sh','bootprep-upgrade.sh'):
            text=(HELPER.parent/name).read_text()
            self.assertIn('"${BOOTPREP_LOG_ACTIVE:-}" != 1',text)
            self.assertIn('exec python3 "$BOOTPREP_LOG_HELPER" /bin/bash',text)
        self.assertIn('install -Dm644 "$LOG_SOURCE" "$LOG_DEST"',(HELPER.parent/'bootprep-install.sh').read_text())

if __name__=='__main__':
    unittest.main()
