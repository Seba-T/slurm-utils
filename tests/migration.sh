#!/usr/bin/env bash
# Exercise the submitted batch shell, signal traps, and a separate cancel client.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
batch_pid='' cancel_pid='' writer_pid=''
cleanup() {
    rm -f -- "$work/block-stage" "$work/block-sync"
    if [[ -n $batch_pid ]]; then kill -TERM "$batch_pid" 2>/dev/null || true; fi
    if [[ -n $cancel_pid ]]; then kill "$cancel_pid" 2>/dev/null || true; fi
    if [[ -n $writer_pid ]]; then kill -KILL "$writer_pid" 2>/dev/null || true; fi
    wait || true
    rm -rf -- "$work"
}
trap cleanup EXIT
export MOCK="$work" HOME="$work/home" XDG_STATE_HOME="$work/state"
export PATH="$work/bin:$PATH"
# Exercise the direct shell entry point; tests/tmux.sh covers real tmux.
export BASH_ENV="$work/bash-env"
cat > "$BASH_ENV" <<'MOCK'
command() {
    [[ $* != '-v tmux' ]] || return 1
    builtin command "$@"
}
MOCK
a="$work/first/model space" b="$work/second/model space"
git init -q "$a"
git init -q "$b"
mkdir -p "$a/nested" "$b/nested" "$a/bin" "$work/bin" "$HOME" "$work/disk"
for project in "$a" "$b"; do
    mkdir -p "$project/.venv/bin"
    cat > "$project/.venv/bin/jupyter" <<'MOCK'
#!/bin/bash
printf '%s\n' "$VIRTUAL_ENV" "$PWD" "${REPO_ENV:-none}" > "$MOCK/jupyter"
MOCK
    chmod +x "$project/.venv/bin/jupyter"
done
cat > "$work/bin/sbatch" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$MOCK/submission"
echo 42
MOCK
cat > "$work/bin/squeue" <<'MOCK'
#!/bin/bash
if [[ $1 = --steps ]]; then
    [[ $2 = --jobs=42 && ! -e $MOCK/step-query-fail ]] || exit 1
    printf '%s\n' 42.batch 42.extern 99.1
    if [[ -n ${SLURM_STEP_ID:-} ]]; then echo "42.$SLURM_STEP_ID"; fi
    if [[ -e $MOCK/step ]]; then echo 42.3; fi
else
    [[ -e $MOCK/finished ]] || echo '42|RUNNING|node'
fi
MOCK
cat > "$work/bin/scancel" <<'MOCK'
#!/bin/bash
if [[ $1 = --signal=TERM ]]; then
    echo "term $2" >> "$MOCK/events"
    [[ $2 = 42.3 ]] || exit 2
    kill -TERM "$(cat "$MOCK/step")"
    exit
fi
[[ $* = 42 ]] || exit 2
echo cancel >> "$MOCK/events"
[[ ! -e $MOCK/fail-cancel ]]
MOCK
cat > "$work/bin/srun" <<'MOCK'
#!/bin/bash
set -eu
while [[ $1 != bash && $1 != env ]]; do
    case $1 in --chdir=*) cd -- "${1#--chdir=}" ;; esac
    shift
done
export SLURM_JOB_ID=42 SLURM_STEP_ID=12
exec "$@"
MOCK
cat > "$work/bin/zsh" <<'MOCK'
#!/bin/bash
printf '%s\n' "$PWD" > "$MOCK/connected"
MOCK
chmod +x "$work/bin/"*
cat > "$a/bin/stage-scratch" <<'HOOK'
#!/bin/bash
set -eu
[[ $PWD = "$PROJECT_DIR" ]]
echo stage >> "$MOCK/events"
while [[ -e $MOCK/block-stage ]]; do sleep 0.03; done
[[ ! -e $MOCK/fail-stage ]]
cp input "$SCRATCH_DIR/data"
HOOK
cat > "$a/bin/sync-scratch" <<'HOOK'
#!/bin/bash
set -eu
[[ $PWD = "$PROJECT_DIR" ]]
printf '%s\n' "$SCRATCH_SYNC_REASON" >> "$MOCK/reasons"
[[ ! -e $MOCK/step ]] || { echo 'Copy started before writer exited' >&2; exit 1; }
echo sync >> "$MOCK/events"
while [[ -e $MOCK/block-sync ]]; do sleep 0.03; done
[[ ! -e $MOCK/fail-sync ]]
cp "$SCRATCH_DIR/data" output
echo saved >> "$MOCK/events"
HOOK
chmod +x "$a/bin/"*
echo original > "$a/input"
cat > "$a/old-setup" <<'MOCK'
echo legacy-staging >> "$MOCK/events"
exit 21
MOCK
echo 'export REPO_ENV=first' > "$a/env.sh"
cp "$repo/config.example.sh" "$work/config"
cat >> "$work/config" <<CFG
SCRATCH_ROOTS=("$work/disk")
LOG_DIR="$work"
ENV_SETUP="$a/old-setup"
declare -A PROJECT_ENVS=(["$a"]="$a/env.sh")
KEYTAB=''
CFG
run() { "$repo/slurm-utils" --config "$work/config" "$@"; }
reject() { if "$@" > "$work/error" 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi; }
schedule() {
    (cd "$a/nested" && run schedule "$@")
    batch=$(tail -1 "$work/submission")
    launch=${batch%/*}
}
start() { SLURM_JOB_ID=42 bash "$batch" > "$work/log" 2>&1 & batch_pid=$!; }
stop() { kill -TERM "$batch_pid"; wait "$batch_pid"; batch_pid=''; }
await() {
    local i
    for ((i=0; i<200; i++)); do if "$@"; then return; fi; sleep 0.03; done
    echo "Timed out waiting for $*" >&2
    cat "$work/log" >&2
    exit 1
}
events() { diff -u <(printf '%s\n' "$@") "$work/events"; }
current="$XDG_STATE_HOME/slurm-utils/current"
for cmd in jupyter connect cancel status set-up; do reject run "$cmd" --migrate-scratch; done
(cd "$b" && reject run schedule --migrate-scratch)
[[ ! -e $work/submission ]]
chmod -x "$a/bin/sync-scratch"
(cd "$a" && reject run schedule --migrate-scratch)
[[ ! -e $work/submission ]]
chmod +x "$a/bin/sync-scratch"
schedule
if grep -q -- '--signal' "$work/submission"; then exit 1; fi
start
await test -f "$launch/scratch-42"
for project in "$a" "$b"; do
    (cd "$project/nested" && run jupyter)
    expected_env=none
    if [[ $project = "$a" ]]; then expected_env=first; fi
    diff -u <(printf '%s\n' "$project/.venv" "$project/nested" "$expected_env") "$work/jupyter"
done
[[ ! -e $work/events ]]
run cancel
stop
events cancel

# Cancel before the batch starts, then simulate a racing startup.
: > "$work/events"
schedule --migrate-scratch
grep -Fxq -- '--signal=B:USR1@300' "$work/submission"
run cancel
SLURM_JOB_ID=42 bash "$batch"
events cancel
[[ ! -e $launch/scratch-42 ]]

# Stage-in failure must keep partially staged data out of interactive steps.
: > "$work/events"
schedule --migrate-scratch
touch "$work/fail-stage"
reject env SLURM_JOB_ID=42 bash "$batch"
events stage
[[ ! -e $launch/scratch-42 ]]
reject run jupyter
run cancel
rm "$work/fail-stage"

# The writer finishes a checkpoint on TERM and remains a visible workload step
# until its process exits, as the scheduler would report it.
start_writer() {
    cat > "$work/writer" <<'WRITER'
#!/bin/bash
finish() {
    echo term-received >> "$MOCK/events"
    while [[ -e $MOCK/hold-writer ]]; do sleep .03; done
    echo checkpoint > "$1/data"
    echo stopped >> "$MOCK/events"
    exit 0
}
trap 'finish "$1"' TERM
echo "$$" > "$MOCK/step"
while :; do sleep .03; done
WRITER
    bash "$work/writer" "$1" &
    writer_pid=$!
    await test -s "$work/step"
}
finish_writer() {
    rm "$work/hold-writer"
    wait "$writer_pid"
    writer_pid=''
    rm "$work/step"
}
# A five-minute warning interrupts stage-in. A concurrent cancel must wait for
# the exiting worker and then the warning's copy, without starting a second one.
: > "$work/events"
touch "$work/block-stage" "$work/hold-writer" "$work/block-sync"
schedule --migrate-scratch
start
await grep -qx stage "$work/events"
reject run connect
reject run jupyter
scratch="$work/disk/$(id -un)/42"
start_writer "$scratch"
kill -USR1 "$batch_pid"
rm "$work/block-stage"
await grep -qx term-received "$work/events"
(cd "$b" && run cancel) > "$work/cancel.log" 2>&1 & cancel_pid=$!
events stage 'term 42.3' term-received
for cmd in connect jupyter set-up; do reject run "$cmd"; done
finish_writer
await grep -qx sync "$work/events"
[[ -f $current && ! -f $launch/copied ]]
rm "$work/block-sync"
wait "$cancel_pid"
cancel_pid=''
stop
events stage 'term 42.3' term-received stopped sync saved cancel
grep -Fxq checkpoint "$a/output"
[[ -e $launch/copied && ! -e $current ]]

# The on-node remigration script also takes its own lock and rechecks success.
: > "$work/events"
schedule --migrate-scratch
start
await test -f "$launch/scratch-42"
(cd "$b/nested" && run connect && run jupyter)
grep -Fxq "$b/nested" "$work/connected"
touch "$work/block-sync"
kill -USR1 "$batch_pid"
await grep -qx sync "$work/events"
SLURM_JOB_ID=42 bash "$launch/copy-back.sh" cancel & duplicate=$!
rm "$work/block-sync"
wait "$duplicate"
await test -f "$launch/copied"
kill -USR1 "$batch_pid"
run cancel
stop
events stage sync saved cancel

# Cancellation during stage-in waits. Query and copy failures retain the job.
# Once copy-back succeeds, even a rejected scancel is safe to retry.
: > "$work/events"
touch "$work/block-stage" "$work/step-query-fail"
schedule --migrate-scratch
start
await grep -qx stage "$work/events"
(cd "$b" && run cancel) > "$work/cancel.log" 2>&1 & cancel_pid=$!
rm "$work/block-stage"
if wait "$cancel_pid"; then exit 1; fi
cancel_pid=''
events stage
[[ -f $current && ! -f $launch/copied ]]
rm "$work/step-query-fail"
touch "$work/fail-sync"
reject run cancel
events stage sync
[[ -f $current && ! -f $launch/copied ]]
rm "$work/fail-sync"
touch "$work/fail-cancel" "$work/hold-writer"
start_writer "$scratch"
(cd "$b" && run cancel) > "$work/cancel.log" 2>&1 & cancel_pid=$!
await grep -qx term-received "$work/events"
finish_writer
if wait "$cancel_pid"; then exit 1; fi
cancel_pid=''
events stage sync 'term 42.3' term-received stopped sync saved cancel
[[ -f $current && -f $launch/copied ]]
rm "$work/fail-cancel"
run cancel
stop
events stage sync 'term 42.3' term-received stopped sync saved cancel cancel
[[ ! -e $current && ! -e $b/output ]]

# Expiry followed by a late cancel also leaves the successful copy alone.
: > "$work/events"
schedule --migrate-scratch
start
await test -f "$launch/scratch-42"
stop
touch "$work/finished"
run cancel
events stage sync saved
[[ ! -e $current ]]
diff -u <(printf '%s\n' warning warning cancel cancel exit) "$work/reasons"
echo 'All scratch migration tests passed'
