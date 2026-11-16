"""VM Lab's persistent, process-safe machine reservations and batch task CLI."""
import argparse
import base64
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import time
import uuid

ROOT = Path(os.environ.get('VMLAB_CLUSTER_DIR', str(Path.home() / 'Library/Application Support/vmLab/Cluster')))
CLI = os.environ.get('VMLAB_CLI', '')
TARGET_SCRIPT = Path(__file__).with_name('cluster_target.py').read_text()
ACTIVE = ('preparing', 'running', 'collecting')


def initialize():
    ROOT.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = ROOT.lstat()
    if ROOT.is_symlink() or not ROOT.is_dir() or info.st_uid != os.getuid():
        raise RuntimeError('Cluster directory must be a directory owned by you.')
    ROOT.chmod(0o700)


def write_json(path, value):
    temporary = path.with_name(path.name + '.' + str(uuid.uuid4()) + '.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.chmod(0o600)
    os.replace(str(temporary), str(path))


@contextlib.contextmanager
def state():
    initialize()
    descriptor = os.open(str(ROOT / 'state.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        path = ROOT / 'state.json'
        data = json.loads(path.read_text()) if path.exists() else {'version': 1, 'hosts': {}, 'leases': {}, 'tasks': {}}
        if data['version'] != 1:
            raise RuntimeError('Unsupported cluster state version.')
        now = time.time()
        for token, reservation in list(data['leases'].items()):
            if reservation['expires'] <= now:
                for task in data['tasks'].values():
                    if task['reservation'] == token and task['status'] in ACTIVE:
                        task.update(status='interrupted', error='Task worker heartbeat expired. Check target logs before retrying.', finished=now)
                del data['leases'][token]
        yield data
        write_json(path, data)


def snapshot():
    with state() as data:
        return json.loads(json.dumps(data))


def output(value):
    if isinstance(value, dict) and 'command' in value and value.get('status') not in ACTIVE:
        value = dict(value)
        for stream in ('stdout', 'stderr'):
            path = Path(value[stream])
            if path.exists():
                size = path.stat().st_size
                with path.open('rb') as handle:
                    handle.seek(max(0, size - 16384))
                    value[stream + 'Text'] = handle.read().decode('utf-8', errors='replace')
                value[stream + 'Truncated'] = size > 16384
    print(json.dumps(value, indent=2), flush=True)


def command(args, timeout=15, input_file=None, output_file=None, environment=None):
    """Keep large transfers on disk and preserve the target's exit status."""
    with contextlib.ExitStack() as stack:
        source = stack.enter_context(open(input_file, 'rb')) if input_file else subprocess.DEVNULL
        destination = stack.enter_context(open(output_file, 'wb')) if output_file else subprocess.PIPE
        try:
            return subprocess.run(args, stdin=source, stdout=destination, stderr=subprocess.PIPE,
                                  timeout=timeout, env=environment)
        except subprocess.TimeoutExpired:
            raise RuntimeError('Machine command timed out after ' + str(timeout) + ' seconds.') from None


def require_success(result):
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace').strip() or
                           'Command exited with status ' + str(result.returncode))
    return result.stdout


def tart_path():
    candidates = [os.environ.get('VMLAB_TART'), '/opt/homebrew/bin/tart', '/usr/local/bin/tart',
                  str(Path.home() / 'Applications/Tart.app/Contents/MacOS/tart'),
                  '/Applications/Tart.app/Contents/MacOS/tart']
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    raise RuntimeError('Tart is unavailable.')


def transport(machine, payload):
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    remote_command = ['python3', '-c', TARGET_SCRIPT, encoded]
    if machine['kind'] == 'vm':
        return [tart_path(), 'exec', '-i', machine['name']] + remote_command
    ssh = [os.environ.get('VMLAB_SSH', '/usr/bin/ssh'), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
           '-p', str(machine['port'])]
    return ssh + [machine['ssh'], ' '.join(shlex.quote(part) for part in remote_command)]


def target(machine, mode, token=None, timeout=15, input_file=None, output_file=None, **values):
    payload = dict(values, mode=mode)
    if token:
        payload['token'] = token
    result = command(transport(machine, payload), timeout, input_file, output_file)
    raw = require_success(result)
    return None if output_file else json.loads(raw)


def local_inventory():
    tart_home = Path(os.environ.get('TART_HOME', str(Path.home() / '.tart')))
    rows = json.loads(require_success(command([tart_path(), 'list', '--format', 'json'])))
    machines = []
    for row in rows:
        if row.get('Source') != 'local':
            continue
        name = row['Name']
        config = json.loads((tart_home / 'vms' / name / 'config.json').read_text())
        machines.append({'id': 'vm:' + name, 'kind': 'vm', 'name': name,
                         'os': config.get('os', 'unknown'), 'arch': config.get('arch', 'unknown'),
                         'cpus': config.get('cpuCount', 0),
                         'memoryGB': config.get('memorySize', 0) / (1024 ** 3),
                         'running': row.get('Running', False), 'online': True})
    return machines


def inventory(probe=True):
    data = snapshot()
    machines = []
    try:
        machines.extend(local_inventory())
    except Exception as error:
        if not data['hosts']:
            raise
        print('Local inventory unavailable: ' + str(error), file=sys.stderr)
    if probe:
        for machine in machines:
            if machine['running']:
                try:
                    machine['reserved'] = target(machine, 'probe', timeout=5)['reserved']
                    machine['ready'] = True
                except Exception as error:
                    machine['ready'] = False
                    machine['detail'] = str(error)
    for host in data['hosts'].values():
        row = dict(host, running=True, online=False)
        if probe:
            try:
                row.update(target(row, 'probe', timeout=10), online=True)
            except Exception as error:
                row['detail'] = str(error)
        machines.append(row)
    for machine in machines:
        reservation = next((item for item in data['leases'].values() if item['machine']['id'] == machine['id']), None)
        machine['available'] = machine['online'] and machine.get('ready', True) and not reservation and not machine.get('reserved', False)
        if reservation:
            machine['reservation'] = reservation['token']
            machine['owner'] = reservation['owner']
            machine['expires'] = reservation['expires']
    return sorted(machines, key=lambda row: (not row['available'], not row['running'], row['kind'] != 'vm', row['id']))


def cli_call(arguments, token):
    result = command([CLI] + arguments, timeout=130,
                     environment=dict(os.environ, VMLAB_RESERVATION=token))
    require_success(result)


def prepare(reservation, task_id=None):
    machine = reservation['machine']
    if machine['kind'] == 'vm':
        running = any(item['id'] == machine['id'] and item['running'] for item in local_inventory())
        if not running:
            cli_call(['start', machine['name']], reservation['token'])
    deadline = time.monotonic() + 180
    last_error = 'Machine is not ready.'
    while time.monotonic() < deadline:
        if task_id and get_task(task_id)['cancelRequested']:
            raise RuntimeError('Task was cancelled during machine preparation.')
        try:
            target(machine, 'claim', reservation['token'], timeout=10,
                   owner=reservation['owner'], ttl=max(30, reservation['expires'] - time.time()))
            return
        except Exception as error:
            last_error = str(error)
            if machine['kind'] == 'ssh' or last_error.startswith(('Machine is reserved', 'Machine is executing')):
                break
            time.sleep(2)
    raise RuntimeError(last_error)


def selection_arguments(parser):
    parser.add_argument('--os', choices=['linux', 'darwin', 'macos', 'any'], default='any')
    parser.add_argument('--machine', help='Exact pool ID, such as vm:vmlab-ubuntu or host:studio')
    parser.add_argument('--min-cpus', type=int, default=1)
    parser.add_argument('--min-memory-gb', type=float, default=0)
    parser.add_argument('--owner', default=os.environ.get('VMLAB_AGENT', 'agent'))


def acquire(options, ttl, prepare_machine=True, exclude=()):
    failures = []
    requested_os = 'darwin' if options.os == 'macos' else options.os
    for machine in inventory():
        if machine['id'] in exclude:
            continue
        if options.machine and machine['id'] != options.machine:
            continue
        if requested_os != 'any' and machine['os'] != requested_os:
            continue
        if machine['cpus'] < options.min_cpus or machine['memoryGB'] < options.min_memory_gb:
            continue
        if not machine['available']:
            continue
        token = str(uuid.uuid4())
        reservation = {'token': token, 'machine': machine, 'owner': options.owner,
                       'created': time.time(), 'expires': time.time() + ttl + 210}
        with state() as data:
            if any(item['machine']['id'] == machine['id'] for item in data['leases'].values()):
                continue
            data['leases'][token] = reservation
        if not prepare_machine:
            return reservation
        try:
            prepare(reservation)
            target(machine, 'claim', token, owner=options.owner, ttl=ttl)
            reservation['expires'] = time.time() + ttl
            with state() as data:
                data['leases'][token] = reservation
            return reservation
        except Exception as error:
            failures.append(machine['id'] + ': ' + str(error))
            with state() as data:
                data['leases'].pop(token, None)
    raise RuntimeError('No available machine matches the request.' + ('\n' + '\n'.join(failures) if failures else ''))


def release(token):
    data = snapshot()
    reservation = data['leases'].get(token)
    if not reservation:
        raise RuntimeError('Unknown or expired reservation.')
    if any(task['reservation'] == token and task['status'] in ACTIVE for task in data['tasks'].values()):
        raise RuntimeError('Reservation has an active task. Cancel it or wait for completion.')
    target(reservation['machine'], 'release', token)
    with state() as data:
        data['leases'].pop(token, None)


def validate_paths(paths):
    for value in paths:
        path = Path(value)
        if path.is_absolute() or '..' in path.parts:
            raise RuntimeError('Artifacts must be paths relative to the task workspace.')


def task_directory(task_id):
    if str(uuid.UUID(task_id)) != task_id:
        raise RuntimeError('Invalid task ID.')
    return ROOT / 'tasks' / task_id


def task_runtime(command):
    executable = Path(command[0]).name if command else ''
    if executable == 'docker':
        return 'docker'
    if executable in ('kubectl', 'helm', 'kind', 'k3s', 'kubeadm'):
        return 'kubernetes'
    return 'process'


def submit(options):
    if options.command and options.command[0] == '--':
        options.command.pop(0)
    if not options.command:
        raise RuntimeError('Supply a command after --.')
    if not 1 <= options.timeout <= 86400:
        raise RuntimeError('Task timeout must be between 1 and 86400 seconds.')
    validate_paths(options.artifact)
    if options.input and not Path(options.input).is_dir():
        raise RuntimeError('--input must be a local directory.')
    task_id = str(uuid.uuid4())
    directory = task_directory(task_id)
    directory.mkdir(parents=True, mode=0o700)
    if options.input:
        with tarfile.open(str(directory / 'input.tar'), 'w') as archive:
            archive.add(str(Path(options.input).resolve()), arcname='.')
    managed = not options.reservation
    if managed:
        reservation = acquire(options, options.timeout + 360, prepare_machine=False)
    else:
        reservation = snapshot()['leases'].get(options.reservation)
        if not reservation:
            raise RuntimeError('Unknown or expired reservation.')
    job = {'id': task_id, 'machine': reservation['machine'], 'reservation': reservation['token'],
           'releaseAfter': managed, 'owner': reservation['owner'], 'command': options.command,
           'timeout': options.timeout, 'artifacts': options.artifact, 'status': 'preparing',
           'runtime': options.runtime if options.runtime != 'auto' else task_runtime(options.command),
           'selection': {'os': options.os, 'machine': options.machine, 'min_cpus': options.min_cpus,
                         'min_memory_gb': options.min_memory_gb, 'owner': options.owner},
           'created': time.time(), 'resultDirectory': str(directory), 'cancelRequested': False,
           'stdout': str(directory / 'stdout.log'), 'stderr': str(directory / 'stderr.log'),
           'artifactsArchive': str(directory / 'artifacts.tar') if options.artifact else None}
    try:
        with state() as data:
            if reservation['token'] not in data['leases']:
                raise RuntimeError('Reservation expired before task submission.')
            if any(item['reservation'] == reservation['token'] and item['status'] in ACTIVE
                   for item in data['tasks'].values()):
                raise RuntimeError('This reservation already has an active task.')
            data['tasks'][task_id] = job
        with (directory / 'worker.log').open('ab') as log:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '_worker', task_id],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                      start_new_session=True, close_fds=True)
    except Exception:
        with state() as data:
            data['tasks'].pop(task_id, None)
        if managed:
            release(reservation['token'])
        raise
    return job


def update_task(task_id, **values):
    with state() as data:
        data['tasks'][task_id].update(values)


def get_task(task_id):
    job = snapshot()['tasks'].get(task_id)
    if not job:
        raise RuntimeError('Unknown task ID.')
    return job


def worker(task_id):
    update_task(task_id, workerPID=os.getpid())
    job = get_task(task_id)
    machine = job['machine']
    token = job['reservation']
    directory = task_directory(task_id)
    failure = None
    result = {}
    cancelled_sent = False
    try:
        rejected = []
        while True:
            try:
                prepare(snapshot()['leases'][token], task_id)
                break
            except Exception as error:
                if not job['releaseAfter'] or job['selection']['machine'] or get_task(task_id)['cancelRequested']:
                    raise
                rejected.append(machine['id'])
                try:
                    target(machine, 'release', token)
                except Exception:
                    pass
                with state() as data:
                    data['leases'].pop(token, None)
                try:
                    reservation = acquire(argparse.Namespace(**job['selection']), job['timeout'] + 360,
                                          prepare_machine=False, exclude=rejected)
                except Exception as next_error:
                    raise RuntimeError(machine['id'] + ': ' + str(error) + '\n' + str(next_error)) from None
                machine = reservation['machine']
                token = reservation['token']
                update_task(task_id, machine=machine, reservation=token)
        with state() as data:
            data['leases'][token]['expires'] = max(data['leases'][token]['expires'], time.time() + 300)
            remaining = data['leases'][token]['expires'] - time.time()
        target(machine, 'claim', token, owner=job['owner'], ttl=remaining)
        if (directory / 'input.tar').exists():
            target(machine, 'input', token, job=task_id, input_file=directory / 'input.tar', timeout=120)
        if get_task(task_id)['cancelRequested']:
            update_task(task_id, status='cancelled', finished=time.time())
            return
        update_task(task_id, status='running', started=time.time())
        payload = {'mode': 'run', 'token': token, 'job': task_id,
                   'command': job['command'], 'timeout': job['timeout']}
        with (directory / 'transport.json').open('wb') as response, (directory / 'transport.log').open('wb') as errors:
            process = subprocess.Popen(transport(machine, payload), stdin=subprocess.DEVNULL,
                                       stdout=response, stderr=errors, start_new_session=True)
            deadline = time.monotonic() + job['timeout'] + 45
            try:
                while process.poll() is None:
                    with state() as data:
                        current = data['tasks'][task_id]
                        cancel = current['cancelRequested']
                        if token in data['leases']:
                            data['leases'][token]['expires'] = (time.time() + 180 if job['releaseAfter']
                                else max(data['leases'][token]['expires'], time.time() + 180))
                    if cancel and not cancelled_sent:
                        target(machine, 'cancel', token, job=task_id, timeout=10)
                        cancelled_sent = True
                    if time.monotonic() > deadline:
                        raise RuntimeError('Task transport timed out. Target execution is bounded by its task timeout.')
                    time.sleep(0.5)
                if process.returncode:
                    raise RuntimeError((directory / 'transport.log').read_text(errors='replace').strip() or 'Target task runner failed.')
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        result = json.loads((directory / 'transport.json').read_text())
        with state() as data:
            data['tasks'][task_id].update(status='collecting', **result)
            if token in data['leases']:
                data['leases'][token]['expires'] = max(data['leases'][token]['expires'], time.time() + 300)
    except Exception as error:
        failure = str(error)
    finally:
        # Preserve logs even for commands that fail or time out.
        for name in ('stdout.log', 'stderr.log'):
            try:
                target(machine, 'read', token, job=task_id, file=name,
                       output_file=directory / name, timeout=30)
            except Exception as error:
                if not failure and result:
                    failure = 'Could not collect ' + name + ': ' + str(error)
        if job['artifacts'] and result:
            try:
                target(machine, 'artifacts', token, job=task_id, artifacts=job['artifacts'],
                       output_file=directory / 'artifacts.tar', timeout=120)
            except Exception as error:
                failure = 'Could not collect artifacts: ' + str(error)
        latest = get_task(task_id)
        status = 'succeeded'
        if latest['cancelRequested'] or result.get('cancelled'):
            status = 'cancelled'
        elif result.get('timedOut'):
            status = 'timed_out'
        elif failure or result.get('exitCode', 1) != 0:
            status = 'failed'
        final = dict(latest, **result)
        final.update(status=status, finished=time.time(), error=failure)
        released = False
        if job['releaseAfter']:
            try:
                target(machine, 'release', token)
                released = True
            except Exception as error:
                final['releaseError'] = str(error)
        with state() as data:
            if released:
                data['leases'].pop(token, None)
            # Publish completion only after logs, results, and lease cleanup exist.
            write_json(directory / 'result.json', final)
            data['tasks'][task_id] = final


def wait_for_task(task_id, limit=None):
    deadline = time.monotonic() + limit if limit else None
    while True:
        job = get_task(task_id)
        if job['status'] not in ACTIVE:
            return job
        if deadline and time.monotonic() >= deadline:
            raise RuntimeError('Wait timed out. The task continues running. Use task show ' + task_id)
        time.sleep(0.5)


def exit_status(job):
    if job['status'] == 'succeeded':
        return 0
    code = job.get('exitCode')
    return code if isinstance(code, int) and 1 <= code <= 125 else 1


def guard(arguments):
    if not arguments:
        return
    data = snapshot()
    token = os.environ.get('VMLAB_RESERVATION')
    if arguments[0] == 'quit' and any(item['machine']['kind'] == 'vm' for item in data['leases'].values()):
        raise RuntimeError('Machines are reserved. Release reservations before quitting VM Lab.')
    name_index = 2 if arguments[0] == 'exec' and len(arguments) > 1 and arguments[1] == '-i' else 1
    if arguments[0] in ('exec', 'start', 'stop', 'shutdown') and len(arguments) > name_index:
        machine_id = 'vm:' + arguments[name_index]
        for reservation in data['leases'].values():
            if reservation['machine']['id'] == machine_id and reservation['token'] != token:
                raise RuntimeError('Machine is reserved by ' + reservation['owner'] + '. Use VMLAB_RESERVATION or release it first.')
    if arguments[:2] == ['tart', 'set'] and len(arguments) > 2:
        guard(['stop', arguments[2]])


def main():
    initialize()
    if len(sys.argv) > 1 and sys.argv[1] == '_worker':
        worker(sys.argv[2])
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == '_guard':
        guard(sys.argv[2:])
        return 0
    parser = argparse.ArgumentParser(description='Reserve machines and run distributed VM Lab tasks.')
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('pool', help='Discover local VMs and probe configured SSH hosts')
    reserve = commands.add_parser('reserve', help='Pick, prepare, and exclusively reserve a machine')
    selection_arguments(reserve)
    reserve.add_argument('--ttl', type=int, default=900)
    renew = commands.add_parser('renew')
    renew.add_argument('reservation')
    renew.add_argument('--ttl', type=int, default=900)
    unreserve = commands.add_parser('release')
    unreserve.add_argument('reservation')
    host = commands.add_parser('host')
    hosts = host.add_subparsers(dest='operation', required=True)
    add = hosts.add_parser('add')
    add.add_argument('name')
    add.add_argument('--ssh', required=True, help='An existing SSH alias or user@host')
    add.add_argument('--port', type=int, default=22)
    hosts.add_parser('list')
    remove = hosts.add_parser('remove')
    remove.add_argument('name')
    task = commands.add_parser('task')
    tasks = task.add_subparsers(dest='operation', required=True)
    for operation in ('submit', 'run'):
        submit_parser = tasks.add_parser(operation)
        selection_arguments(submit_parser)
        submit_parser.add_argument('--reservation')
        submit_parser.add_argument('--runtime', choices=['auto', 'process', 'docker', 'kubernetes'], default='auto')
        submit_parser.add_argument('--timeout', type=int, default=600)
        submit_parser.add_argument('--input')
        submit_parser.add_argument('--artifact', action='append', default=[])
        submit_parser.add_argument('command', nargs=argparse.REMAINDER)
    tasks.add_parser('list')
    for operation in ('show', 'wait', 'cancel'):
        item = tasks.add_parser(operation)
        item.add_argument('id')
        if operation == 'wait':
            item.add_argument('--timeout', type=int)
    options = parser.parse_args()
    if options.action == 'pool':
        output(inventory())
    elif options.action == 'reserve':
        if not 30 <= options.ttl <= 86400:
            raise RuntimeError('Reservation TTL must be between 30 and 86400 seconds.')
        output(acquire(options, options.ttl))
    elif options.action == 'renew':
        if not 30 <= options.ttl <= 86400:
            raise RuntimeError('Reservation TTL must be between 30 and 86400 seconds.')
        reservation = snapshot()['leases'].get(options.reservation)
        if not reservation:
            raise RuntimeError('Unknown or expired reservation.')
        target(reservation['machine'], 'claim', options.reservation,
               owner=reservation['owner'], ttl=options.ttl)
        with state() as data:
            data['leases'][options.reservation]['expires'] = time.time() + options.ttl
            output(data['leases'][options.reservation])
    elif options.action == 'release':
        release(options.reservation)
        output({'released': options.reservation})
    elif options.action == 'host':
        if options.operation == 'list':
            output(list(snapshot()['hosts'].values()))
        elif options.operation == 'add':
            if not options.name or options.name.startswith('-') or not options.ssh or options.ssh.startswith('-') or any(c.isspace() for c in options.ssh):
                raise RuntimeError('Use a host name and a single SSH destination.')
            if not 1 <= options.port <= 65535:
                raise RuntimeError('Invalid SSH port.')
            machine = {'id': 'host:' + options.name, 'name': options.name, 'kind': 'ssh',
                       'ssh': options.ssh, 'port': options.port}
            machine.update(target(machine, 'probe', timeout=15))
            if machine['os'] not in ('linux', 'darwin'):
                raise RuntimeError('Remote task hosts must run macOS or Linux.')
            with state() as data:
                if any(item['machine']['id'] == machine['id'] for item in data['leases'].values()):
                    raise RuntimeError('Cannot change a reserved host.')
                data['hosts'][options.name] = machine
            output(machine)
        else:
            with state() as data:
                if any(item['machine']['id'] == 'host:' + options.name for item in data['leases'].values()):
                    raise RuntimeError('Cannot remove a reserved host.')
                data['hosts'].pop(options.name, None)
            output({'removed': options.name})
    elif options.operation in ('submit', 'run'):
        job = submit(options)
        if options.operation == 'run':
            job = wait_for_task(job['id'])
            output(job)
            return exit_status(job)
        output(job)
    elif options.operation == 'list':
        output(sorted(snapshot()['tasks'].values(), key=lambda job: job['created'], reverse=True))
    elif options.operation == 'show':
        output(get_task(options.id))
    elif options.operation == 'wait':
        job = wait_for_task(options.id, options.timeout)
        output(job)
        return exit_status(job)
    elif options.operation == 'cancel':
        with state() as data:
            if options.id not in data['tasks']:
                raise RuntimeError('Unknown task ID.')
            job = data['tasks'][options.id]
            if job['status'] in ACTIVE:
                job['cancelRequested'] = True
            output(job)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Detached tasks continue running. Use task list, task wait, or task cancel.', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('vmLab: ' + str(error), file=sys.stderr)
        sys.exit(1)
