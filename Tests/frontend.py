"""Measure the real app's Metal presentation and main-queue latency."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def percentile(values, p):
    values = sorted(values)
    return round(values[min(len(values) - 1, int((len(values) - 1) * p))], 3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--load', type=int, default=0)
    parser.add_argument('--machines', type=int, default=0)
    parser.add_argument('--online-hosts', type=int, default=0)
    parser.add_argument('--columns', action='store_true')
    options = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='vmlab-frontend-', dir='/tmp'))
    environment = dict(os.environ, VMLAB_SOCKET_DIR=str(root),
                       VMLAB_CLUSTER_DIR=str(root / 'cluster'), VMLAB_FRONTEND_REPORT=str(root / 'report.json'))
    environment['VMLAB_FRONTEND_ONLINE_HOSTS'] = str(options.online_hosts)
    if options.machines:
        for index in range(options.machines):
            machine = root / 'tart-home/vms' / ('machine-' + str(index).zfill(4))
            machine.mkdir(parents=True)
            (machine / 'config.json').write_text(json.dumps({'os': 'linux', 'cpuCount': 4, 'memorySize': 4294967296}))
        environment['TART_HOME'] = str(root / 'tart-home')
    cluster = root / 'cluster'
    cluster.mkdir(mode=0o700)
    jobs = {}
    for index, runtime in enumerate(('docker', 'kubernetes', 'docker', 'kubernetes')):
        jobs[runtime + str(index)] = {'id': runtime + str(index), 'machine': {'id': 'preview:' + runtime, 'name': runtime + ' preview'},
                         'status': 'running', 'created': time.time(), 'resultDirectory': str(root),
                         'runtime': runtime, 'command': ['docker' if runtime == 'docker' else 'kubectl', 'get']}
    (cluster / 'state.json').write_text(json.dumps({'version': 1, 'hosts': {}, 'leases': {}, 'tasks': jobs}))
    loads = [subprocess.Popen(['/usr/bin/python3', '-c', 'while True: pass']) for _ in range(options.load)]
    process = None
    try:
        with (root / 'app.log').open('w') as log:
            process = subprocess.Popen([str(options.app.resolve() / 'Contents/MacOS/vmLab'),
                                        '-machineListColumns', 'YES' if options.columns else 'NO'],
                                       env=environment, stdout=log, stderr=log)
        deadline = time.monotonic() + 25
        while not (root / 'report.json').exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError((root / 'app.log').read_text())
            time.sleep(.1)
        report = json.loads((root / 'report.json').read_text())
        assert len(report['scrollMutationMS']) == 240, 'Scroll exercise did not complete'
        if options.columns:
            assert report.get('columnCount') == 3, 'Expected three vertical lists'
            assert report.get('columnsAligned') is True, 'Expected equal, aligned side-by-side columns'
            assert report.get('independentColumnScroll') is True, 'Expected independent vertical scrolling'
        else:
            assert report.get('columnCount') == 1, 'Expected one stacked list'
        assert report['firstMetalPresentationMS'] > 0, report
        assert len(report['wallpaperPresentationMS']) >= 40, report
        assert report.get('revealAnimationCount', 0) > 0, report
        assert report.get('runtimeIcons', {}).get('Docker.png') is True, report
        assert report.get('runtimeIcons', {}).get('Kubernetes.png') is True, report
        summary = {'evidence': str(root), 'cpuLoadWorkers': options.load, 'machineFixtureCount': options.machines, 'onlineHostFixtureCount': options.online_hosts}
        for name, value in report.items():
            if isinstance(value, list):
                summary[name] = {'count': len(value), 'p50': percentile(value, .5),
                                 'p95': percentile(value, .95), 'max': round(max(value), 3)} if value else {'count': 0}
            elif isinstance(value, dict):
                summary[name] = {key: round(item, 3) for key, item in value.items()}
            else:
                summary[name] = round(value, 3)
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        for child in ([process] if process else []) + loads:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    main()
