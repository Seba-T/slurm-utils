# slurm-utils

One Bash executable for reserving a Slurm node, opening a shell, and running
Jupyter. It tracks one current allocation per state directory.

## Requirements and installation

Use Linux x86-64 with Bash 4+, standard Linux utilities (including `flock` from
util-linux), and working `sbatch`, `squeue`, `srun`, and `scancel` commands.
No compilation, root access, package manager, or Python runtime is needed by
this utility. Jupyter Notebook must be available on the compute node for the
`jupyter` command; `set-up` can optionally install it in your project environment.
Optional Kerberos renewal uses `k5start` and a keytab.
The optional `set-up` command needs Python 3 with `venv` support, zsh, curl,
and network access from the compute node to download direnv.

Your home directory and state directory **must be shared between login and
compute nodes**, at the same absolute paths. Use one Slurm cluster per state
directory. The Slurm controller must permit overlapping job steps.

Install on the cluster's login node with `curl` and Bash:

```bash
curl -sfL https://raw.githubusercontent.com/Seba-T/slurm-utils/main/install.sh | bash
```

This installs `~/.local/bin/slurm-utils` and creates the example configuration
at `~/.config/slurm-utils/config.sh` if it does not exist. Run the same command
to upgrade; your configuration is preserved.

Or, from a downloaded copy of this directory:

```bash
mkdir -p ~/.local/bin ~/.config/slurm-utils
install -m 755 slurm-utils ~/.local/bin/slurm-utils
install -m 600 config.example.sh ~/.config/slurm-utils/config.sh
```

Add this to your shell startup file if needed, then open a new shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Edit `~/.config/slurm-utils/config.sh` for your cluster before scheduling.
The example contains sample resource settings, **not built-in defaults**.
Configuration is trusted Bash code, sourced with your privileges. Review any
configuration before using it. `--config PATH` selects a different file; it does
not select a separate allocation or state directory.

## Configuration

All resource variables must be explicitly set: `JOB_NAME`, `PARTITION`, `GRES`,
`CPUS_PER_TASK`, `MEMORY`, and `TIME_LIMIT`. Empty `PARTITION` or `GRES` omits
that option, allowing the cluster's policy to apply. Slurm validates cluster
specific resource names and time limits. `MEMORY` accepts an integer with an
optional K/M/G/T suffix; `TIME_LIMIT` accepts Slurm numeric time forms such as
`08:00:00` or `2-00:00:00`.

Also set `LOG_DIR` (absolute, no `%` characters) and `SCRATCH_ROOTS` (a nonempty
Bash array of absolute paths). `JUPYTER_PORT` is optional and defaults to 1234;
an explicit value must be 1–65535. Existing configurations and allocation
snapshots keep their saved port; change your configuration and schedule a new
allocation to use a different port. Paths containing spaces are supported
when quoted in the configuration.

`KEYTAB` and `ENV_SETUP` are optional and may be empty. If `k5start` is on the
compute node's PATH and the keytab exists, the reservation starts ticket
renewal. Startup failure is reported in the batch error log but does not end
the reservation. `ENV_SETUP` must be an absolute readable shell setup file,
available on the compute node. For example:

```bash
# In config.sh:
ENV_SETUP="$HOME/jupyter-environment.sh"
# In ~/jupyter-environment.sh:
source "$HOME/venvs/notebooks/bin/activate"
```

The utility sources that file before launching Jupyter. Otherwise it uses
`.venv/bin/jupyter` in the current project directory when present, or the
available `jupyter` command. The `jupyter` command does not install environments.
Connected shells use normal login startup files; `ENV_SETUP` applies only to Jupyter.
To create a project environment interactively, use `set-up` below.

## Workflow

Run these commands on the login node:

```bash
slurm-utils schedule
slurm-utils status
# Wait for RUNNING and scratch initialization.
slurm-utils connect
# Inside the allocation:
printf '%s\n' "$SCRATCH_DIR"
exit
# Back on the login node:
slurm-utils jupyter
# Or override the port for this launch only:
slurm-utils jupyter 1235
# Ctrl-C stops the Jupyter step; the reservation remains available.
slurm-utils cancel
```

`schedule` submits a single-node, single-task allocation with `sbatch
--parsable`. The batch process prepares scratch, starts optional renewal, and
sleeps until cancellation or the time limit. Scheduling again while the current
job is active fails with its ID and state. A successful queue query confirming
that the job has finished permits replacement. Query failures preserve state.

`status` reports the ID, queue state, assigned node, scratch path when known,
and stdout/stderr paths. `FINISHED` means the job is no longer in the queue;
it does not assert successful completion. Consult logs or your cluster's
`sacct` command for the final outcome. For pending jobs, Slurm may display a
node placeholder. Before scratch metadata arrives, attachment reports
“initializing; retry shortly.” Check the batch logs if initialization fails.

`connect` opens `zsh --login` in an interactive `srun` step, falling back to
`bash --login` with a message if zsh is unavailable. It starts in the same
directory from which you ran `connect`; that path must exist on the compute
node. An unavailable directory fails rather than silently starting elsewhere.

If `tmux` is installed on the login node, `connect` creates a session there
for the allocation and attaches to it. The first window and every new tmux
window (`Ctrl-b c`) or split pane (`Ctrl-b %` or `Ctrl-b "`) start a separate
interactive `srun` step on the compute node. New shells use the directory from
the first `connect`. Detach with `Ctrl-b d`; run `slurm-utils connect` on the
same login node to reattach. From an existing login-node tmux client, `connect`
switches to the allocation session. Other tmux sessions keep their settings.
Without tmux, `connect` opens the compute shell directly.

These shortcuts create tmux windows/panes. A new tab in your terminal app or
VS Code still starts on its configured host; run `slurm-utils connect` there
to attach. Keeping tmux on the login node does not extend the Slurm time limit.

`jupyter` opens a
foreground step and runs `jupyter notebook --no-browser --ip=0.0.0.0` with the
configured port (or the optional `jupyter PORT` argument) and zero port retries.
Port arguments must be integers from 1 to 65535 and do not change saved settings.
Jupyter starts in the directory from which you ran the command.
Both export `SCRATCH_DIR` and use
[`srun --overlap`](https://slurm.schedmd.com/srun.html) to share the reservation's
resources. Exiting a shell or stopping Jupyter leaves the allocation running.

Each Jupyter launch generates a fresh 256-bit random token, passes it through
`JUPYTER_TOKEN`, and prints a compute-node URL. In VS Code connected to the
login node through Remote SSH, select an existing Jupyter server and paste
that URL once Jupyter reports that it is ready. Treat the URL as a credential.
Direct access assumes that the login node can resolve the compute hostname
and reach its port. The server listens on all compute-node interfaces and
uses HTTP; use it only within an appropriate trusted cluster network. See
[Jupyter's remote-server documentation](https://jupyter-server.readthedocs.io/en/latest/operators/public-server.html).
No SSH tunnel is created. A port conflict fails instead of silently selecting
a different port. Normal Jupyter output and errors remain in your terminal.

`cancel` calls `scancel` and clears the current pointer only after Slurm accepts
cancellation. Failure preserves the pointer so you can retry. Cancellation
ends the allocation and its steps; it may take Slurm a short time to finish.

## Interactive project setup

From your project directory on the login node, with a running, initialized
allocation:

```bash
slurm-utils set-up
slurm-utils connect
```

`set-up` connects to that allocation in the current directory, prints each
command, and requires an explicit `y` or `yes` before running it. Empty input,
EOF, and other answers decline. It asks before connecting, creating `.venv`,
installing direnv, changing your login shell, appending each configuration
line, and trusting `.envrc`. Declining a required step stops setup; declining
`chsh` offers the same fallback as a failed shell change. Earlier completed
steps are retained, so you can rerun setup.

Setup creates `.venv` with `python3 -m venv .venv`, or reuses a working existing
environment. It stops on an incomplete `.venv` without deleting it. If Python,
its venv support, or zsh is unavailable, load the appropriate cluster module
or ask your administrator, then retry.

At the end, setup asks whether to install Jupyter Notebook and ipykernel with
`.venv/bin/python -m pip install notebook ipykernel`. These provide the notebook
server and Python kernel for the [VS Code Jupyter extension](https://code.visualstudio.com/docs/datascience/jupyter-notebooks).
Declining skips installation and registration and still completes setup. If
pip is missing from an existing environment, setup asks before bootstrapping
it with `.venv/bin/python -m ensurepip --upgrade`. Installation errors stop
setup with a message; rerun it after fixing the environment or package-index
access.

After installation, a separate confirmation asks to register the environment
using its absolute Python path and `-m ipykernel install --user`. The
[registered kernel](https://ipython.readthedocs.io/en/stable/install/kernel_install.html)
appears as `Python (.venv: /path/to/project)` in Jupyter and VS Code. Its internal
name is derived from the project's absolute path, so reruns update the same
kernel and different projects have different names. Declining registration
leaves installed packages in place. Run `slurm-utils jupyter` from the project
directory to launch its server, then select this kernel in VS Code.

It downloads the [official direnv installer](https://direnv.net/docs/installation.html)
and runs it with `bin_path` set to the directory containing the resolved
`slurm-utils` executable. That directory must be writable and shared. A
working direnv already in that directory is reused. Failed or empty downloads
stop setup before the installer runs; installation failures are reported and
can be retried. There is no sudo or system package installation.

Setup tries `chsh -s /path/to/zsh`. When unavailable, declined, or rejected by
cluster policy, it offers to append `export SHELL=/path/to/zsh` to `.envrc`.
This sets the project's preferred shell; `connect` launches zsh directly even
when the account's login shell could not be changed. Direnv evaluates `.envrc`
in a subprocess, so this fallback does not replace an already running shell.

Setup appends activation of `.venv` and adds the binary directory to `PATH`
in `.envrc`. It adds the [direnv shell hooks](https://direnv.net/docs/hook.html)
to `${ZDOTDIR:-$HOME}/.zshrc` and `~/.bashrc`, using the installed binary's
absolute path. Existing file contents are preserved and matching lines are
not appended twice. The entire `.envrc` is displayed before asking to run
`direnv allow .`, because allowing it trusts any existing commands too.
Setup then returns to the login node; the next `connect` starts a fresh shell
and loads the project environment. For Bash login sessions outside `connect`,
ensure your login startup file sources `~/.bashrc` to activate its hook.

## State, logs, and scratch lifetime

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/slurm-utils` with private
permissions. Schedule/cancel operations use `flock`; state and scratch metadata
are replaced atomically. Set `XDG_STATE_HOME` to an absolute shared path if the
default is unsuitable. Do not edit state files while the utility is running.

Each submission saves the launch settings and batch script in its own launch
directory. Later commands use this snapshot, even if configuration changes or
is removed. The contents of an external `ENV_SETUP` file are not snapshotted;
keep that file available. Logs go to `LOG_DIR/slurm-utils-JOBID.out` and `.err`.
A rejected submission retains its launch directory for inspection. If `sbatch`
returns malformed output, inspect `squeue` before retrying: submission may
have succeeded even though the utility could not record its ID.

On the compute node, the first usable configured scratch root gets a private
`<root>/<user>/<job-id>` directory. No usable root causes a clear batch error.
Scratch metadata is job-specific and written to shared state. Scratch is
usually local to that compute node, not the login node. The utility **never
deletes scratch data**. Copy valuable output elsewhere before ending the
allocation; cluster cleanup policy may remove scratch independently.

Launch directories and logs are retained after cancellation for inspection.
Remove obsolete files manually when no job needs them. The scope excludes
multi-cluster management, arbitrary job adoption, named allocations, automatic
tunnels, background Jupyter supervision, and general workload submission.

## Upgrade and uninstall

To upgrade, rerun the curl command above or repeat the executable installation
command. Keep your edited configuration; compare it with the new example
rather than overwriting it.
Existing reservations run their saved batch scripts.

Before uninstalling, cancel the allocation (or use `scancel JOBID` if needed).
Remove `~/.local/bin/slurm-utils` and, if no longer needed,
`~/.config/slurm-utils` and the state directory. Logs and scratch data remain
and must be handled separately.

## Validation

```bash
bash -n slurm-utils install.sh config.example.sh tests/test.sh tests/tmux.sh
shellcheck slurm-utils install.sh config.example.sh tests/test.sh tests/tmux.sh
bash tests/test.sh
# With tmux installed (uses an isolated temporary tmux server):
bash tests/tmux.sh
```

Tests use temporary directories and fake Slurm/Jupyter commands. They cover
missing/invalid configuration, quoted paths, duplicate submission, pending,
running and finished jobs, scheduler failures, scratch selection/failure,
cancellation failure, settings persistence, environment setup, step options,
Jupyter arguments and fresh tokens, connection directories and shell fallback,
and setup confirmations, reruns, preservation of existing files, and failure
paths for venv, direnv, and login-shell changes. No cluster or Jupyter installation is
needed. Tests also cover optional package installation and registration,
missing pip, package/kernel failures, project environment selection, and port
overrides and validation. ShellCheck is a development-only dependency.
The tmux integration test checks new windows and split panes, reattachment,
session recreation, quoted paths, and preservation of unrelated sessions.

Before relying on a real cluster:

1. Configure a small allocation with a GPU and run `schedule`, then `status`
   until running and initialized. Check both log paths.
2. Run `connect`, verify `hostname`, `nvidia-smi`, and write a test file in
   `$SCRATCH_DIR`. If tmux is available, create a window and split pane and
   verify they also run on the compute node. Detach and run `connect` again
   to verify reattachment. Exit and confirm the reservation remains running.
3. Run `jupyter`, connect VS Code Remote SSH using the printed URL, and execute
   a notebook cell checking the hostname and GPU visibility in the intended
   environment. Confirm a second launch on the same port fails.
4. Stop Jupyter with Ctrl-C, confirm `status` is still running, and reconnect
   to the shell. Launch Jupyter again and confirm the token changes.
5. Run `cancel` from another login terminal. Confirm the reservation and all
   steps disappear from Slurm, the current pointer is cleared, and scratch
   was not deleted by the utility.
6. In a disposable shared project directory with a new allocation, run
   `set-up`. Review each displayed command. Check the resulting `.venv`,
   `.envrc`, shell hooks, and direnv next to `slurm-utils`. Connect and verify
   `pwd`, `echo "$SHELL"`, and `python -c 'import sys; print(sys.prefix)'`.
   If `chsh` is denied, verify the project-local fallback still selects zsh.

Mocks cannot establish cluster compatibility, network reachability, Kerberos
behavior, GPU visibility, or site-specific Slurm policy.
