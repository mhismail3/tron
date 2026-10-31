#!/usr/bin/env python3
"""CLI, process bridge and inherited exclusion; never invokes native Mac lifecycle."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

from tron_mac_replace_platform import run
from tron_profile_cutover import run_controller
from tron_rebuild_lock import RebuildLock, RebuildBusy

ROOT = Path(__file__).resolve().parents[1]


class ProfileCutoverCommand(unittest.TestCase):
    def test_supported_entrypoint(self):
        result = subprocess.run([ROOT / 'scripts/tron', 'profile', 'cutover', '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('--rollback', result.stdout)
        self.assertIn('--apply', result.stdout)

    def test_controller_process_and_real_log_path_contract(self):
        class FixtureLifecycle:
            quit_timeout = start_timeout = 2
            offline = False

            def gateway_pid(self):
                return None

            def app_running(self):
                return True

            def quit_app(self, log):
                # Actual existing MacPlatform subprocess/log boundary, not a type-only mock.
                run([sys.executable, '-c', 'print("fixture quit")'], log, timeout=2)
                self.offline = True

            def launch_app(self, log):
                run([sys.executable, '-c', 'print("fixture start")'], log, timeout=2)
                self.offline = False

            def quit_progress(self):
                return None

            def offline_blocker(self):
                return None if self.offline else 'fixture process online'

            def clear_quit_request(self):
                pass

            def system_info(self):
                if self.offline:
                    raise RuntimeError('offline')
                return {'fixture': True}

            def rpc(self, method, params):
                return {'method': method, 'params': params}

        child = '''import json,sys,os
for number,method in enumerate(['stop','start','rpc'],1):
 print(json.dumps({'id':number,'call':method,'params':{'method':'home.profileList','params':{}}}),flush=True)
 reply=json.loads(sys.stdin.readline())
 assert reply['id']==number and 'error' not in reply,reply
assert reply['result']['method']=='home.profileList'
'''
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'controller.log'
            self.assertEqual(run_controller([sys.executable, '-c', child], FixtureLifecycle(), log, (), dict(os.environ)), 0)
            self.assertIn('fixture quit', log.read_text())
            self.assertIn('fixture start', log.read_text())

    def test_child_keeps_both_leases_after_controller_death(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            read_fd, write_fd = os.pipe()
            parent = None
            try:
                # This disposable controller deliberately dies without cleanup.
                # Its child uses the same production spawn function and blocks on
                # our pipe; only inherited descriptors can retain both flocks.
                controller = '''import os,sys
from pathlib import Path
from tron_profile_cutover import controller_process,private_log
from tron_rebuild_lock import RebuildLock
root=Path(sys.argv[1]);pipe=int(sys.argv[2])
with RebuildLock(root/'rebuild.lock') as a, RebuildLock(root/'lock') as b:
 with private_log(root/'log') as log:
  child=controller_process([sys.executable,'-c','import os,sys;print("ready",flush=True);os.read(int(sys.argv[1]),1)',str(pipe)],log,(a,b,pipe),dict(os.environ))
  assert child.stdout.readline().strip()=='ready'
  print(child.pid,flush=True)
  os._exit(0)
'''
                parent = subprocess.Popen([sys.executable, '-c', controller, str(root), str(read_fd)], cwd=ROOT / 'scripts', stdout=subprocess.PIPE, text=True, pass_fds=(read_fd,))
                self.assertGreater(int(parent.stdout.readline()), 0)
                self.assertEqual(parent.wait(timeout=5), 0)
                for name in ['rebuild.lock', 'lock']:
                    with self.assertRaises(RebuildBusy):
                        with RebuildLock(root / name):
                            pass
                os.write(write_fd, b'x')
                # Blocking kernel lock acquisition is the child's exit signal,
                # not a timing assertion or a poll/retry-to-green.
                waiter = 'import fcntl,sys; f=[open(p,"r+") for p in sys.argv[1:]]; [fcntl.flock(x,fcntl.LOCK_EX) for x in f]'
                subprocess.run([sys.executable, '-c', waiter, str(root / 'rebuild.lock'), str(root / 'lock')], check=True, timeout=5)
            finally:
                os.close(read_fd)
                os.close(write_fd)  # also releases the child on any assertion failure
                if parent is not None:
                    if parent.poll() is None:
                        parent.terminate()
                    parent.wait(timeout=5)
                    parent.stdout.close()


if __name__ == '__main__':
    unittest.main()
