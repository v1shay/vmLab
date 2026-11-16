"""Exercise scheduling races, SSH dispatch, execution, cancellation and artifacts.

The fake transports invoke the actual target protocol in isolated home directories.
No SSH service, credentials, or real VM state are modified.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/cluster.py'
TART = '''#!/usr/bin/python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
if args[0] == 'list':
    print(json.dumps([{'Name':'linux-one','Source':'local','Running':True}]))
else:
    assert args[:3] == ['exec', '-i', 'linux-one'], args
    os.environ['HOME'] = os.environ['TEST_VM_HOME']
    os.execvp(args[3], args[3:])
'''
SSH = '''#!/usr/bin/python3
import os, shlex, sys
os.environ['HOME'] = os.environ['TEST_SSH_HOME']
args = shlex.split(sys.argv[-1])
os.execvp(args[0], args)
'''


def main():
    with tempfile.TemporaryDirectory(prefix='vmlab-cluster-', dir='/tmp') as temporary:
        root = Path(temporary)
        for name in ('vm-home', 'ssh-home'):
            (root / name).mkdir()
        vm = root / 'tart-home/vms/linux-one'
        vm.mkdir(parents=True)
        (vm / 'config.json').write_text(json.dumps({'os':'linux', 'arch':'arm64', 'cpuCount':4, 'memorySize':4*1024**3}))
        for name, source in [('tart', TART), ('ssh', SSH)]:
            (root / name).write_text(source)
            (root / name).chmod(0o700)
        environment = dict(os.environ, VMLAB_CLUSTER_DIR=str(root / 'controller'),
                           VMLAB_TART=str(root / 'tart'), VMLAB_SSH=str(root / 'ssh'),
                           TART_HOME=str(root / 'tart-home'), TEST_VM_HOME=str(root / 'vm-home'),
                           TEST_SSH_HOME=str(root / 'ssh-home'))

        def call(*arguments, expected=0):
            result = subprocess.run([sys.executable, str(SOURCE), *arguments], env=environment,
                                    text=True, capture_output=True, timeout=30)
            assert result.returncode == expected, (arguments, result.stdout, result.stderr)
            return json.loads(result.stdout) if result.stdout.strip() else None

        first = call('task', 'run', '--os', 'linux', '--', '/usr/bin/true')
        assert first['status'] == 'succeeded' and Path(first['resultDirectory'], 'result.json').exists()
        runtime_job = call('task', 'run', '--runtime', 'docker', '--', '/usr/bin/true')
        assert runtime_job['runtime'] == 'docker'
        pool = call('pool')
        assert pool[0]['id'] == 'vm:linux-one' and pool[0]['available']
        processes = [subprocess.Popen([sys.executable, str(SOURCE), 'reserve', '--os', 'linux', '--owner', str(i)],
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for i in range(2)]
        results = [(process.communicate(timeout=30), process.returncode) for process in processes]
        assert sorted(code for _, code in results) == [0, 1], results
        lease = json.loads(next(streams[0] for streams, code in results if code == 0))
        call('reserve', '--machine', 'vm:linux-one', expected=1)
        call('_guard', 'stop', 'linux-one', expected=1)
        other = dict(environment, VMLAB_CLUSTER_DIR=str(root / 'other-controller'))
        conflict = subprocess.run([sys.executable, str(SOURCE), 'reserve', '--os', 'linux'],
                                  env=other, capture_output=True, text=True, timeout=20)
        assert conflict.returncode == 1 and 'No available machine' in conflict.stderr, conflict.stderr
        call('renew', lease['token'], '--ttl', '60')
        call('release', lease['token'])
        assert call('pool')[0]['available']
        print('PASS: atomic competing reservations, exclusion, renew, release, and legacy command guard')

        inputs = root / 'input'
        inputs.mkdir()
        (inputs / 'message.txt').write_text('uploaded content')
        job = call('task', 'run', '--os', 'linux', '--input', str(inputs), '--artifact', 'answer.txt',
                   '--', '/bin/sh', '-c', 'cat message.txt > answer.txt; echo task-output; echo task-error >&2')
        assert job['status'] == 'succeeded'
        assert Path(job['stdout']).read_text().strip() == 'task-output'
        assert Path(job['stderr']).read_text().strip() == 'task-error'
        with tarfile.open(job['artifactsArchive']) as archive:
            assert archive.extractfile('answer.txt').read() == b'uploaded content'
        assert call('pool')[0]['available']
        print('PASS: input staging, task execution, stdout/stderr, artifact download, and automatic release')

        failed = call('task', 'run', '--', '/bin/sh', '-c', 'echo failed; exit 7', expected=7)
        assert failed['status'] == 'failed' and failed['exitCode'] == 7
        timed_out = call('task', 'run', '--timeout', '1', '--', '/bin/sleep', '30', expected=1)
        assert timed_out['status'] == 'timed_out'
        job = call('task', 'submit', '--', '/bin/sleep', '30')
        call('task', 'cancel', job['id'])
        cancelled = call('task', 'wait', job['id'], expected=1)
        assert cancelled['status'] == 'cancelled'
        assert call('pool')[0]['available']
        print('PASS: exit status, timeout, background task persistence, cancellation, and release')

        host = call('host', 'add', 'remote', '--ssh', 'tester@remote')
        assert host['id'] == 'host:remote'
        job = call('task', 'run', '--machine', 'host:remote', '--', '/bin/sh', '-c', 'echo remote-result')
        assert job['status'] == 'succeeded'
        assert Path(job['stdout']).read_text().strip() == 'remote-result'
        local_job = call('task', 'submit', '--os', 'linux', '--', '/bin/sleep', '2')
        remote_job = call('task', 'submit', '--', '/bin/sleep', '2')
        assert local_job['machine']['id'] != remote_job['machine']['id']
        assert call('task', 'wait', local_job['id'])['status'] == 'succeeded'
        assert call('task', 'wait', remote_job['id'])['status'] == 'succeeded'
        call('host', 'remove', 'remote')
        print('PASS: SSH registration, remote selection, dispatch, and result collection through the transport fixture')

        call('task', 'run', '--artifact', '../outside', '--', '/usr/bin/true', expected=1)
        job = call('task', 'run', '--artifact', 'missing', '--', '/usr/bin/true', expected=1)
        assert job['status'] == 'failed' and 'artifact' in job['error'], job
        print('PASS: artifact traversal rejection and missing artifact failure')


if __name__ == '__main__':
    main()
