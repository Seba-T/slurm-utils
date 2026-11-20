# slurm-utils

A single Bash script that reserves a Slurm node, opens a shell on it, and runs Jupyter there. It tracks one current allocation at a time.

```bash
slurm-utils schedule     # request a node
slurm-utils status       # wait until RUNNING
slurm-utils connect      # shell on the node
slurm-utils jupyter      # Jupyter on the node
slurm-utils cancel       # release the node
```

Shells and Jupyter run as `srun --overlap` steps inside the reservation, so closing either one leaves the node yours until you `cancel` or the time limit hits.

## Requirements

- Linux x86-64, Bash 4+, Git on the login node, `flock` (util-linux), and working `sbatch`, `squeue`, `srun`, `scancel`.
- Your home directory and the state directory must be **shared between login and compute nodes, at the same absolute paths**.
- The Slurm controller must allow overlapping job steps.
- Jupyter Notebook on the compute node (for `jupyter`). `set-up` can install it for you.
- Optional: `tmux` on the login node; `k5start` plus a keytab for Kerberos renewal.
- Only for `set-up`: Python 3 with `venv`, zsh, curl, and compute-node network access (to download direnv).

No compilation, root access, or package manager needed.

## Install

On the cluster's login node:

```bash
curl -sfL https://raw.githubusercontent.com/Seba-T/slurm-utils/main/install.sh | bash
```

This installs `~/.local/bin/slurm-utils` and creates `~/.config/slurm-utils/config.sh` from the example if it doesn't exist. Rerun the same command to upgrade; your config is kept (compare it against the new example rather than overwriting it).

Manual install from a clone:

```bash
mkdir -p ~/.local/bin ~/.config/slurm-utils
install -m 755 slurm-utils ~/.local/bin/slurm-utils
install -m 600 config.example.sh ~/.config/slurm-utils/config.sh
```

Make sure `~/.local/bin` is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Configure

Edit `~/.config/slurm-utils/config.sh`. The values in the example are samples, **not defaults**. The file is sourced as Bash with your privileges, so only use configs you trust. `--config PATH` selects a different file; it does not create a separate allocation or state directory.

| Variable | Required | Notes |
|---|---|---|
| `JOB_NAME` | yes | |
| `PARTITION` | yes | Empty omits the option (cluster default applies). |
| `GRES` | yes | Empty omits the option. Must be empty or a single `gpu[:type]:count`. |
| `CPUS_PER_TASK` | yes | |
| `MEMORY` | yes | Integer with optional `K`/`M`/`G`/`T` suffix. |
| `TIME_LIMIT` | yes | Slurm time format, e.g. `08:00:00` or `2-00:00:00`. |
| `LOG_DIR` | yes | Absolute path, no `%` characters. |
| `SCRATCH_ROOTS` | yes | Non-empty Bash array of absolute paths. |
| `JUPYTER_PORT` | no | 1–65535, default 1234. |
| `KEYTAB` | no | If set and `k5start` is on the compute node, ticket renewal starts with the job. A renewal failure is logged but doesn't end the job. |
| `ENV_SETUP` | no | Absolute path to a shell file sourced before Jupyter. Must be readable on the compute node. |
| `PROJECT_ENVS` | no | Per-checkout activation scripts (see below). |

Slurm itself validates partition, GRES, and time-limit values. Paths with spaces work if quoted.

A saved allocation keeps the port it was scheduled with. To change the port, edit the config and schedule a new allocation.

### Jupyter environment

Jupyter picks its environment in this order:

1. The `PROJECT_ENVS` script matching your Git checkout, if any.
2. `.venv/bin/jupyter` in the directory you ran the command from, then in the checkout root.
3. `ENV_SETUP`, if set.
4. `jupyter` from `PATH`.

Register an environment-only script (e.g. to load CUDA modules) per checkout:

```bash
declare -A PROJECT_ENVS=(
  ["$HOME/project-a"]="$HOME/project-a/config-env.sh"
  ["$HOME/project-b"]="$HOME/project-b/activate.sh"
)
```

An `ENV_SETUP` file that lives inside a Git checkout is ignored, even for running allocations. Move what you need into `PROJECT_ENVS` before scheduling your next one.

Shells you open with `connect` use your normal login and direnv startup, and that code runs every time a shell opens. Keep data transfers out of `.envrc` and login files; use [`--migrate-scratch`](#stage-project-data-on-the-compute-node) instead.

## Commands

### `schedule`

Submits a single-node, single-task job with `sbatch --parsable`. The batch process prepares scratch, starts Kerberos renewal if configured, and sleeps until cancelled or out of time.

Scheduling again while the current job is active fails and prints its ID and state. If a queue query confirms the job has finished, the new one replaces it. If the query itself fails, nothing changes.

Options: [`--vmem`](#pick-a-gpu-by-vram), [`--migrate-scratch`](#stage-project-data-on-the-compute-node).

### `status`

Prints the job ID, queue state, assigned node, scratch path (when known), and stdout/stderr log paths.

- `FINISHED` only means the job left the queue, not that it succeeded. Check the logs or `sacct`.
- For a pending job, Slurm may show a placeholder node.
- Before scratch metadata arrives, `connect` says "initializing; retry shortly." If that persists, check the batch logs.

### `connect`

Opens `zsh --login` in an interactive `srun` step (falling back to `bash --login` with a message if zsh is missing). It starts in the directory you ran it from, which must exist on the compute node; otherwise it fails rather than starting somewhere else. `SCRATCH_DIR` is exported.

With `tmux` on the login node, `connect` creates (or reattaches to) one session per checkout per allocation:

- Every new window (`Ctrl-b c`) and split (`Ctrl-b %`, `Ctrl-b "`) starts its own `srun` step on the compute node, in the directory of the first `connect`.
- Detach with `Ctrl-b d`; rerun `slurm-utils connect` from the same checkout on the same login node to reattach.
- From inside an existing tmux client, it switches to the allocation's session. Other sessions are untouched.
- A new terminal tab or VS Code terminal still opens on its own host. Run `slurm-utils connect` there.

Without tmux, you just get the compute-node shell.

### `jupyter [PORT]`

Runs `jupyter notebook --no-browser --ip=0.0.0.0` as a foreground step, in the directory you ran it from. `PORT` (1–65535) overrides the configured port for this launch only. Ctrl-C stops Jupyter; the reservation stays.

Each launch generates a fresh 256-bit token and prints a compute-node URL. In VS Code over Remote SSH, choose "existing Jupyter server" and paste it once Jupyter reports ready. Things to know:

- **Treat the URL as a credential.** The server listens on all compute-node interfaces over plain HTTP, so only use it on a trusted cluster network.
- The login node must be able to resolve the compute hostname and reach the port. No SSH tunnel is created.
- A port conflict is an error; it never picks another port.
- See Jupyter's [remote server docs](https://jupyter-server.readthedocs.io/en/latest/operators/public-server.html).

### `cancel`

Calls `scancel`, and clears the current-allocation pointer only after Slurm accepts it. If it fails, the pointer stays so you can retry. Slurm may take a moment to finish tearing the job down.

### `set-up`

Interactive project bootstrap. See [Project setup](#project-setup).

## Pick a GPU by VRAM

```bash
slurm-utils schedule --vmem 30    # also accepts 30G or 30GB
```

Requests a GPU with at least 30 GB of memory per GPU, whichever type starts soonest:

1. Lists the GPU types in your `PARTITION` (or Slurm's default view) with at least that much VRAM.
2. Runs [`sbatch --test-only`](https://slurm.schedmd.com/sbatch.html#OPT_test-only) for each type, with the same CPU, RAM, partition, and time as the real request.
3. Submits **one** job for the type with the earliest estimated start (ties go to alphabetical order). It keeps that type while queued and doesn't switch if the queue changes.

```text
Considering GPUs with at least 30 GB VRAM per GPU (count 1):
  gpu:a40:1 (48 GB per GPU)
  gpu:h200_3g.71gb:1 (71 GB per GPU)
  gpu:a40:1: estimated start 2026-11-07T18:34:45 UTC
  gpu:h200_3g.71gb:1: estimated start 2026-11-07T14:08:46 UTC
Chosen GPU: gpu:h200_3g.71gb:1 (71 GB per GPU); expected start 2026-11-07T14:08:46 UTC.
Start time is an estimate; the submitted GPU type remains fixed while queued.
Scheduled allocation 123
```

Details:

- `--vmem` only works with `schedule`. It overrides the GPU type in `GRES` and keeps the count. `GRES` must be empty (one GPU) or a single `gpu[:type]:count`.
- Slurm has no portable VRAM field, so capacity comes from the type name (`a100_80gb`, MIG `h200_3g.71gb`) or a built-in table: A40, L40, L40S, RTX A6000, RTX 6000 Ada (48 GB); H200 (141 GB); RTX PRO 6000 Blackwell (96 GB). These are nominal capacities, not free memory. Unknown types are skipped with a message.
- Add site-specific types in your config:

  ```bash
  declare -A GPU_MEMORY_GB=(
    [site_specific_gpu]=48
    [site_mig_profile]=40
  )
  ```

- If no type qualifies, the inventory query fails, or no estimate is usable, nothing is submitted and your current allocation is untouched.
- The chosen typed `GRES` is saved with the allocation settings. `--mem` and `--mem-per-gpu` are about host RAM and don't affect this.

## Stage project data on the compute node

```bash
slurm-utils schedule --migrate-scratch
```

Run it from a Git checkout (or a subdirectory). Outside Git, the current directory is the root. The checkout must contain two executable scripts:

- `bin/stage-scratch`: copies your data into `$SCRATCH_DIR` at job start.
- `bin/sync-scratch`: copies results back out.

Both run on the compute node with the root as working directory, plus `PROJECT_DIR` (the root) and `SCRATCH_DIR` (the job's private scratch) set. Keep them on shared storage for the life of the allocation. Plain `schedule` creates empty scratch and runs neither.

Example for a project that reads and writes `$SCRATCH_DIR/data` (the shared `data/` directory must exist before scheduling):

```bash
#!/usr/bin/env bash
# bin/stage-scratch
set -eu
mkdir -p -- "$SCRATCH_DIR/data"
rsync -a -- "$PROJECT_DIR/data/" "$SCRATCH_DIR/data/"
```

```bash
#!/usr/bin/env bash
# bin/sync-scratch
set -eu
rsync -a -- "$SCRATCH_DIR/data/" "$PROJECT_DIR/data/"
```

Then `chmod +x bin/stage-scratch bin/sync-scratch`.

### Lifecycle

- **Stage-in** runs once at batch start. `connect` and `jupyter` become available only after it succeeds. You can connect from other checkouts on the same allocation, but only the checkout that requested migration is copied.
- **Warning:** migrated jobs use `--signal=B:USR1@300` and are never requeued onto another node. About five minutes before the time limit, or on `slurm-utils cancel`, the allocation starts draining: no new shells, Jupyter servers, setup steps or tmux panes; running workload steps (including those from other checkouts) get SIGTERM.
- **Copy-back:** once those steps exit, `bin/sync-scratch` runs on the node. A `cancel` during the warning waits for the same transfer. The hook sees `SCRATCH_SYNC_REASON` (`warning`, `exit` or `cancel`) and can read any metadata your stage-in saved in scratch.
- **Failures:** if the step query fails, a step is still alive after 60 s, or the transfer fails, copy-back stays pending and the job stays tracked. Retry with `slurm-utils cancel` (the batch shell also retries on TERM). Cancelling a *pending* job skips the transfer.

Caveats:

- Draining only covers processes supervised by Slurm steps. Keep writers inside those steps and avoid raw `srun` or SSH workloads during the drain.
- `SLURM_UTILS_DRAIN_FILE` is exported to stage-in and managed steps. If that file exists, cooperating processes should stop launching work.
- A hard deadline or node loss can still interrupt a transfer. Size your checkpoint flushes for the time you have.

## Project setup

From your project directory on the login node, with a running and initialized allocation:

```bash
slurm-utils set-up
slurm-utils connect
```

`set-up` connects to the allocation in your current directory and prints every command before running it. Each step needs an explicit `y` or `yes`; empty input, EOF, or anything else declines. Declining a required step stops setup. Completed steps are kept, so you can rerun it. It asks before:

1. **Creating `.venv`** with `python3 -m venv --without-pip`, then separately bootstrapping pip with `ensurepip`. A working existing environment is reused, and nothing is ever deleted. An interrupted venv with a valid `pyvenv.cfg` and working Python is offered a repair. Other broken `.venv` directories stop setup for manual repair.
2. **Installing direnv** from the [official installer](https://direnv.net/docs/installation.html) into the directory containing `slurm-utils` (must be writable and shared). An existing working direnv there is reused. No sudo or system packages.
3. **Changing your login shell** to zsh with `chsh`. If that's unavailable or rejected, it offers to add `export SHELL=/path/to/zsh` to `.envrc` instead. `connect` launches zsh directly either way.
4. **Editing config files:** appends `.venv` activation and a `PATH` entry to `.envrc`, and the [direnv hooks](https://direnv.net/docs/hook.html) to `${ZDOTDIR:-$HOME}/.zshrc` and `~/.bashrc`. Existing contents are preserved and lines aren't duplicated.
5. **Running `direnv allow .`** after showing you the whole `.envrc`, since allowing it also trusts any commands already in it.
6. **Installing Jupyter** (`notebook` and `ipykernel`) into `.venv`, then optionally **registering a kernel** named `Python (.venv: /path/to/project)` for Jupyter and the [VS Code Jupyter extension](https://code.visualstudio.com/docs/datascience/jupyter-notebooks). Declining either still completes setup. Reruns update the same kernel; different projects get different names.

Temporary files go to the allocation's `SCRATCH_DIR` (as `TMPDIR`), so a full `/tmp` doesn't break installs. If Python, `venv` support, or zsh is missing, load the right cluster module or ask your admin, then retry. If pip bootstrapping or package installs fail, check the error shown, free space in the printed temp directory, and package-index access.

After setup, the next `connect` starts a fresh shell that loads the project environment. For Bash login sessions outside `connect`, make sure your login file sources `~/.bashrc`.

## State, logs, and scratch

- **State** lives in `${XDG_STATE_HOME:-$HOME/.local/state}/slurm-utils` with private permissions. Set `XDG_STATE_HOME` to an absolute shared path if the default doesn't suit you. Don't edit state files while the tool is running. Use one Slurm cluster per state directory.
- **Settings snapshot:** each `schedule` saves its settings and batch script in its own launch directory, and later commands use that snapshot even if you change or delete the config. The exception is the contents of an external `ENV_SETUP` file, so keep it in place.
- **Logs** go to `LOG_DIR/slurm-utils-JOBID.out` and `.err`. Launch directories and logs are kept after cancellation; delete them yourself when no longer needed. A rejected submission keeps its launch directory for inspection.
- **Malformed `sbatch` output:** check `squeue` before retrying. The job may have been submitted even though the tool couldn't record its ID.
- **Scratch:** on the compute node, the first usable root in `SCRATCH_ROOTS` gets a private `<root>/<user>/<job-id>` directory. If none is usable, the batch job fails with a clear error. Scratch is usually local to the compute node, not visible from the login node. **slurm-utils never deletes scratch data**, but your cluster's cleanup policy might, so copy anything valuable out (or use `--migrate-scratch`) before the allocation ends.

## Uninstall

Cancel the allocation first (`slurm-utils cancel`, or `scancel JOBID`). Then remove `~/.local/bin/slurm-utils` and, if you no longer need them, `~/.config/slurm-utils` and the state directory. Logs and scratch data stay behind and need manual cleanup.

## Scope

slurm-utils does not do multi-cluster management, adopting arbitrary jobs, named allocations, automatic SSH tunnels, background Jupyter supervision, or general job submission.

## Tests

Tests use temporary directories and fake Slurm and Jupyter commands, so no cluster is needed. [ShellCheck](https://www.shellcheck.net/) is a dev-only dependency.

```bash
shellcheck slurm-utils install.sh config.example.sh tests/*.sh
bash tests/test.sh
bash tests/vmem.sh
bash tests/migration.sh
bash tests/tmux.sh    # needs tmux; uses an isolated temporary server
```

Mocks can't prove cluster compatibility, network reachability, Kerberos behavior, GPU visibility, or site-specific Slurm policy. Before relying on it, try it end to end on your cluster with a small GPU allocation:

1. `schedule`, then `status` until running; check both log files.
2. `connect`; verify `hostname`, `nvidia-smi`, and that you can write to `$SCRATCH_DIR`. With tmux, check that new windows and panes also land on the compute node and that detach/reattach works.
3. `jupyter`; connect VS Code with the printed URL and run a cell that checks hostname and GPU visibility. Confirm a second launch on the same port fails, and that the token changes between launches.
4. Ctrl-C Jupyter and confirm `status` still shows the job running.
5. `cancel` from another terminal; confirm the job and all steps are gone from the queue and scratch wasn't deleted.
6. In a disposable shared directory, run `set-up` and review each command it shows.
