# vmLab

vmLab is an Apple Silicon macOS app for viewing local macOS and Linux Tart VMs. Open it and choose
**vmLab > Copy Path** to give an agent the executable path. The same CLI works from a
shell or automation script. It opens vmLab if needed.

```sh
cli="$HOME/Applications/vmLab.app/Contents/Helpers/vmlab"
"$cli" help
"$cli" tart list
"$cli" tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest sonoma
"$cli" start sonoma
"$cli" list
"$cli" screenshot sonoma --out /tmp/sonoma.png
"$cli" exec sonoma -- sw_vers
"$cli" stop sonoma
```

Start each local VM by name to add a pane. Wait for `list` to report `running`
before sending input. Click and drag coordinates are in guest pixels, measured
from the top left. Guest commands need the Tart guest agent. Use
`exec -i NAME -- COMMAND` to send a local file over stdin.

VMs keep running if you close the window. Quit hides the viewer while it owns
running guests. Stop guests from the CLI before quitting the process.

## Display

The default display uses Tart’s experimental Virtualization.framework VNC
server. vmLab connects over loopback, though Tart may listen on other host
interfaces. vmLab disables Tart’s host-to-guest clipboard bridge. With guest Screen Sharing and standard VNC password authentication
configured, use `VMLAB_VNC_PASSWORD=… "$cli" start NAME --sharing` for guest
VNC instead. vmLab reads the password from the CLI environment.

## Build and test

Requires macOS 14 or later, Apple Silicon, Xcode command-line tools, and Tart.
Run `./build.sh` to build and sign `build/vmLab.app` locally. Run
`python3 Tests/smoke.py build/vmLab.app` to exercise two display connections
and independent input using the included RFB test server.

## Linux and automation

The installed Ubuntu 24.04 VM is named `vmlab-ubuntu`. Select it from Offline
just like a Mac VM. Local VM rows use the OS in Tart's `config.json`: Apple for
macOS, Tux for Linux. Inventory refreshes every three seconds, including stopped
VMs created by agents; running VMs automatically appear under Online.

```sh
"$cli" tart clone ghcr.io/cirruslabs/ubuntu:24.04 my-linux
"$cli" start my-linux
"$cli" list
"$cli" exec my-linux -- uname -s
printf 'echo hello\n' | "$cli" exec -i my-linux -- /bin/sh
"$cli" screenshot my-linux --out /tmp/linux.png
"$cli" stop my-linux
```

The same CLI works for Linux and macOS in scripts and local CI jobs, including
exit statuses and stdin. `list` includes `os` (`linux`, `darwin`, or `unknown`).
Guest commands require Tart Guest Agent inside the image. The upstream Ubuntu base image
opens a console. The local `vmlab-ubuntu` VM has Ubuntu Desktop installed. A running display does
not guarantee guest commands are ready: wait for `exec NAME -- /usr/bin/true` to
succeed before running jobs. Use Linux commands and dependencies for Linux jobs.
There is no hosted CI workflow in this checkout; the smoke test runs locally on
an Apple Silicon Mac and tests both OS types using synthetic displays.

To add the Ubuntu desktop to a newly cloned base image, run these after its
guest agent is ready:

```sh
"$cli" exec my-linux -- sudo -n apt-get update
"$cli" exec my-linux -- sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal
"$cli" exec my-linux -- sudo -n systemctl enable gdm3
"$cli" exec my-linux -- sudo -n systemctl set-default graphical.target
"$cli" exec my-linux -- sudo -n systemctl start gdm3
```

Log into the graphical session as `admin` with password `admin`.

## Agent task scheduling

The bundled CLI discovers local Tart VMs and registered SSH hosts, reserves one
matching the requested OS and configured CPU/memory capacity, and runs a batch
task in a separate workspace. Running machines are preferred, followed by local
machines when otherwise equal. Each machine accepts one scheduled task at a time.

```sh
cli="$HOME/Applications/vmLab.app/Contents/Helpers/vmlab"
"$cli" pool
"$cli" task run --os linux --owner codex --artifact result.txt -- /bin/sh -c 'uname -a > result.txt'
"$cli" task submit --os macos --owner build-agent --input /path/to/project --artifact results -- /bin/sh -c 'mkdir results; ./test.sh > results/test.log 2>&1'
"$cli" task list
"$cli" task show TASK_ID
"$cli" task wait TASK_ID
"$cli" task cancel TASK_ID
```

`task submit` returns a task ID while its worker prepares and runs the machine.
Stopped local VMs start through the viewer. Each VM needs Tart Guest Agent and
Python 3. Task results include the command's exit code, stdout/stderr file paths,
a result directory with `result.json`, and an `artifacts.tar` archive when
`--artifact` was requested. Logs and artifacts are collected at completion,
including command failures and timeouts. A missing requested artifact fails the
task. Input directories support regular files and directories. Artifact paths
must be relative to the task workspace. The default command timeout is 600 seconds.
Batch task subprocesses are terminated when the task completes or is cancelled.
Workers continue independently of the caller and viewer window.

Use `--machine vm:NAME` or `--machine host:NAME` to choose a particular machine.
`--min-cpus N` and `--min-memory-gb N` filter configured capacity. `--os` accepts
`linux`, `macos`/`darwin`, or `any`. An unavailable machine fails the request.
Automatic selection can try another matching machine if preparation fails.

### Remote task hosts

Register an existing SSH connection once. Enrollment probes the host's OS and
resources, and subsequent tasks automatically include it in selection.

```sh
"$cli" host add studio --ssh myaccount@my-studio
"$cli" host list
"$cli" task run --machine host:studio -- /usr/bin/uname -a
"$cli" host remove studio
```

Remote hosts need macOS or Linux, Python 3, and working noninteractive SSH with
an already trusted host key. SSH aliases and `--port` are supported. The task
protocol runs through SSH and keeps its work under `~/.vmlab` on the target.
Registration stores the destination and resource metadata. Network discovery
for remote desktops continues independently of SSH task-host enrollment.

### Explicit reservations

```sh
"$cli" reserve --os linux --owner codex --ttl 900
"$cli" task run --reservation TOKEN -- /usr/bin/uname -a
"$cli" renew TOKEN --ttl 900
"$cli" release TOKEN
```

An explicit reservation remains held across multiple sequential tasks until
released or expired. Active tasks extend their leases while preparing, running,
and collecting results. Tasks that select their own machine release it automatically.
Reservations are coordinated by file locks locally and on each target account,
including competing controllers using that same account. VM Lab's CLI and viewer
reject stopping reserved VMs, and direct guest `exec` requires the matching
`VMLAB_RESERVATION=TOKEN` environment variable. External Tart, SSH, and other
accounts remain outside this scheduler's coordination.

Task metadata and results live in
`~/Library/Application Support/vmLab/Cluster`. The home view shows reservations
and recent tasks. Clicking a task opens its local result directory.

Run `python3 Tests/cluster.py` for reservation races, cross-controller exclusion,
input/output transfers, concurrent local/SSH dispatch, timeout/cancellation,
exit status, and artifact validation through isolated transport fixtures.

Tasks identify their runtime automatically for direct `docker`, `kubectl`,
`helm`, `kind`, `k3s`, and `kubeadm` commands. Use `task run --runtime docker`
or `--runtime kubernetes` for shell scripts that invoke those tools. Active
runtime tasks display the corresponding logo beside their machine and task.
Machine names and symbols reveal once per session with a short compositor
animation. Reduce Motion shows the resolved label directly.
