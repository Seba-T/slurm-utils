# slurm-utils

One Bash executable for reserving a Slurm node, opening a shell, and running
Jupyter. It tracks one current allocation per state directory.

## Requirements and installation

Use Linux x86-64 with Bash 4+, standard Linux utilities (including `flock` from
util-linux), and working `sbatch`, `squeue`, `srun`, and `scancel` commands.
No compilation, root access, package manager, or Python runtime is needed by
this utility. Jupyter Notebook must already be available on the compute node
for the `jupyter` command; optional Kerberos renewal uses `k5start` and a keytab.

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

Also set `LOG_DIR` (absolute, no `%` characters), `SCRATCH_ROOTS` (a nonempty
Bash array of absolute paths), and `JUPYTER_PORT` (1–65535). Paths containing
spaces are supported when quoted in the configuration.

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

The utility sources that file before launching Jupyter. Otherwise it uses the
available environment. It does not install or manage environments. Connected
shells use normal Bash login startup files; `ENV_SETUP` applies only to Jupyter.

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

`connect` opens `bash --login` in an interactive `srun` step. `jupyter` opens a
foreground step and runs `jupyter notebook --no-browser --ip=0.0.0.0` with the
configured port and zero port retries. Both export `SCRATCH_DIR` and use
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
bash -n slurm-utils install.sh config.example.sh tests/test.sh
shellcheck slurm-utils install.sh config.example.sh tests/test.sh
bash tests/test.sh
```

Tests use temporary directories and fake Slurm/Jupyter commands. They cover
missing/invalid configuration, quoted paths, duplicate submission, pending,
running and finished jobs, scheduler failures, scratch selection/failure,
cancellation failure, settings persistence, environment setup, step options,
and Jupyter arguments and fresh tokens. No cluster or Jupyter installation is
needed. ShellCheck is a development-only dependency.

Before relying on a real cluster:

1. Configure a small allocation with a GPU and run `schedule`, then `status`
   until running and initialized. Check both log paths.
2. Run `connect`, verify `hostname`, `nvidia-smi`, and write a test file in
   `$SCRATCH_DIR`. Exit and confirm the reservation remains running.
3. Run `jupyter`, connect VS Code Remote SSH using the printed URL, and execute
   a notebook cell checking the hostname and GPU visibility in the intended
   environment. Confirm a second launch on the same port fails.
4. Stop Jupyter with Ctrl-C, confirm `status` is still running, and reconnect
   to the shell. Launch Jupyter again and confirm the token changes.
5. Run `cancel` from another login terminal. Confirm the reservation and all
   steps disappear from Slurm, the current pointer is cleared, and scratch
   was not deleted by the utility.

Mocks cannot establish cluster compatibility, network reachability, Kerberos
behavior, GPU visibility, or site-specific Slurm policy.
