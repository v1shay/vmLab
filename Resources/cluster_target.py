"""Task protocol executed through existing SSH or Tart guest-agent access."""
import base64
import contextlib
import fcntl
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tarfile
import time
import uuid

stopping = False


def request_stop(signum, frame):
    global stopping
    stopping = True


signal.signal(signal.SIGHUP, request_stop)
signal.signal(signal.SIGTERM, request_stop)
request = json.loads(base64.b64decode(sys.argv[1]))
root = Path.home() / '.vmlab'
root.mkdir(mode=0o700, exist_ok=True)


def write_json(path, value):
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    os.replace(str(temporary), str(path))


@contextlib.contextmanager
def state_lock():
    with (root / 'reservation.lock').open('a+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def execution_lock():
    handle = (root / 'execution.lock').open('a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError('Machine is executing another task.')
    return handle


def lease():
    path = root / 'reservation.json'
    return json.loads(path.read_text()) if path.exists() else None


def authorized():
    current = lease()
    if not current or current['token'] != request['token'] or current['expires'] <= time.time():
        raise RuntimeError('Reservation is missing, expired, or belongs to another agent.')
    return current


def job_directory():
    job_id = request['job']
    if str(uuid.UUID(job_id)) != job_id:
        raise RuntimeError('Invalid task ID.')
    return root / 'tasks' / job_id


def work_path(work, relative):
    path = Path(relative)
    if path.is_absolute() or '..' in path.parts:
        raise RuntimeError('Task paths must be relative to the task workspace.')
    resolved = (work / path).resolve()
    if resolved != work.resolve() and work.resolve() not in resolved.parents:
        raise RuntimeError('Task path escapes its workspace.')
    return work / path


def terminate_group(pid):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass


def main():
    mode = request['mode']
    if mode == 'probe':
        cpus = os.cpu_count() or 1
        if sys.platform == 'darwin':
            memory = int(subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.memsize']))
        else:
            memory = os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')
        with state_lock():
            current = lease()
        print(json.dumps({'os': platform.system().lower(), 'arch': platform.machine(),
                          'cpus': cpus, 'memoryGB': memory / (1024 ** 3),
                          'reserved': bool(current and current['expires'] > time.time())}))
        return
    if mode == 'claim':
        with state_lock():
            current = lease()
            if current and current['token'] != request['token'] and current['expires'] > time.time():
                raise RuntimeError('Machine is reserved by another agent.')
            with execution_lock():
                write_json(root / 'reservation.json', {
                    'token': request['token'], 'owner': request['owner'],
                    'expires': time.time() + request['ttl']})
        print('{}')
        return
    if mode == 'release':
        with state_lock():
            current = lease()
            if current and current['token'] == request['token']:
                with execution_lock():
                    write_json(root / 'reservation.json', {'token': '', 'owner': '', 'expires': 0})
        print('{}')
        return
    directory = job_directory()
    work = directory / 'work'
    if mode == 'cancel':
        with state_lock():
            authorized()
            path = directory / 'process.json'
            if path.exists():
                info = json.loads(path.read_text())
                if info.get('active') and info['token'] == request['token']:
                    (directory / 'cancelled').touch()
                    terminate_group(info['pid'])
        print('{}')
        return
    with state_lock():
        authorized()
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    work.mkdir(mode=0o700, exist_ok=True)
    if mode == 'input':
        with tarfile.open(fileobj=sys.stdin.buffer, mode='r|*') as archive:
            for member in archive:
                work_path(work, member.name)
                if not (member.isfile() or member.isdir()):
                    raise RuntimeError('Input archives support regular files and directories only.')
                archive.extract(member, str(work))
        print('{}')
    elif mode == 'read':
        if request['file'] not in ('stdout.log', 'stderr.log', 'result.json'):
            raise RuntimeError('Invalid result file.')
        with (directory / request['file']).open('rb') as source:
            import shutil
            shutil.copyfileobj(source, sys.stdout.buffer)
    elif mode == 'artifacts':
        paths = [(relative, work_path(work, relative)) for relative in request['artifacts']]
        for relative, path in paths:
            if not path.exists():
                raise RuntimeError('Requested artifact is missing: ' + relative)
            for entry in [path] + (list(path.rglob('*')) if path.is_dir() else []):
                work_path(work, str(entry.relative_to(work)))
        with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
            for relative, path in paths:
                archive.add(str(path), arcname=relative)
    elif mode == 'run':
        with execution_lock():
            with state_lock():
                current = authorized()
                current['expires'] = max(current['expires'], time.time() + request['timeout'] + 120)
                write_json(root / 'reservation.json', current)
            started = time.time()
            timed_out = False
            with (directory / 'stdout.log').open('wb') as output, (directory / 'stderr.log').open('wb') as error:
                environment = dict(os.environ, VMLAB_TASK_ID=request['job'])
                process = subprocess.Popen(request['command'], cwd=str(work), env=environment,
                                           stdin=subprocess.DEVNULL, stdout=output, stderr=error,
                                           start_new_session=True)
                write_json(directory / 'process.json', {
                    'pid': process.pid, 'token': request['token'], 'active': True})
                try:
                    while process.poll() is None:
                        if time.time() - started >= request['timeout'] or stopping or (directory / 'cancelled').exists():
                            timed_out = not stopping and not (directory / 'cancelled').exists()
                            terminate_group(process.pid)
                            try:
                                process.wait(timeout=2)
                            except subprocess.TimeoutExpired:
                                os.killpg(process.pid, signal.SIGKILL)
                            break
                        time.sleep(0.2)
                    process.wait()
                finally:
                    # A batch task's background children must finish with the task.
                    terminate_group(process.pid)
                    time.sleep(0.1)
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    write_json(directory / 'process.json', {
                        'pid': process.pid, 'token': request['token'], 'active': False})
            result = {'exitCode': process.returncode, 'timedOut': timed_out,
                      'cancelled': stopping or (directory / 'cancelled').exists(),
                      'started': started, 'finished': time.time()}
            write_json(directory / 'result.json', result)
            print(json.dumps(result))
    else:
        raise RuntimeError('Unknown target operation.')


try:
    main()
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
