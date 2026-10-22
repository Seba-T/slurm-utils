#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home space" XDG_STATE_HOME="$work/state space"
export MOCK="$work/mock"
mkdir -p "$HOME" "$MOCK/bin" "$work/scratch space"
export PATH="$MOCK/bin:$PATH"
cat > "$MOCK/bin/sbatch" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK/sbatch.args"
printf '%s' "${!#}" > "$MOCK/batch"
echo "${SUBMIT_RESULT:-123;cluster}"
MOCK
cat > "$MOCK/bin/squeue" <<'MOCK'
#!/usr/bin/env bash
[[ ! -f $MOCK/query-fail ]] || exit 1
cat "$MOCK/queue"
MOCK
cat > "$MOCK/bin/scancel" <<'MOCK'
#!/usr/bin/env bash
[[ ! -f $MOCK/cancel-fail ]]
MOCK
cat > "$MOCK/bin/srun" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK/srun.args"
while [[ $1 != bash ]]; do shift; done
# Inspect interactive attachment without opening a shell in the test runner.
[[ $(cat "$MOCK/mode") != connect ]] || exit 0
exec "$@"
MOCK
cat > "$MOCK/bin/jupyter" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK/jupyter.args"
printf '%s\n' "$JUPYTER_TOKEN" > "$MOCK/token"
printf '%s\n' "$SCRATCH_DIR" > "$MOCK/scratch"
[[ $ACTIVATED = yes ]]
MOCK
chmod +x "$MOCK/bin/"*
: > "$MOCK/queue"
echo jupyter > "$MOCK/mode"
config="$work/config space.sh"
run() { "$repo/slurm-utils" --config "$config" "$@"; }
expect_fail() {
    if "$@" > "$work/output" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi
}
expect_fail run schedule
cp "$repo/config.example.sh" "$config"
cat >> "$config" <<CFG
LOG_DIR=$(printf %q "$HOME/log space")
SCRATCH_ROOTS=(/nonexistent $(printf %q "$work/scratch space"))
ENV_SETUP=$(printf %q "$work/setup space.sh")
PARTITION=''
GRES=''
CFG
printf 'export ACTIVATED=yes\n' > "$work/setup space.sh"
cp "$config" "$work/good-config"
printf 'unset MEMORY\n' >> "$config"
expect_fail run schedule
cp "$work/good-config" "$config"
run schedule
[[ $(stat -c %a "$XDG_STATE_HOME/slurm-utils") = 700 ]]
if grep -q -- '--partition\|--gres' "$MOCK/sbatch.args"; then exit 1; fi
printf '123|PENDING|(Priority)\n' > "$MOCK/queue"
expect_fail run schedule
run status | grep -q PENDING
expect_fail run connect
printf '123|RUNNING|node1\n' > "$MOCK/queue"
expect_fail run connect
grep -q 'initializing; retry shortly' "$work/output"
touch "$MOCK/query-fail"
expect_fail run schedule
expect_fail run status
[[ -f $XDG_STATE_HOME/slurm-utils/current ]]
rm "$MOCK/query-fail"
# Run the actual submitted payload; timeout simulates allocation cancellation.
set +e
SLURM_JOB_ID=123 timeout 2 bash "$(cat "$MOCK/batch")" > "$work/batch.log" 2>&1
rc=$?
set -e
[[ $rc = 124 ]]
# Existing launch settings survive edits and removal of the configuration.
printf 'JUPYTER_PORT=9999\n' > "$config"
run jupyter > "$work/url"
grep -q -- '--port=8888' "$MOCK/jupyter.args"
grep -q -- '--port-retries=0' "$MOCK/jupyter.args"
grep -q -- '--ip=0.0.0.0' "$MOCK/jupyter.args"
grep -Eq '^[a-f0-9]{64}$' "$MOCK/token"
first=$(cat "$MOCK/token")
run jupyter > "$work/url"
[[ $(cat "$MOCK/token") != "$first" ]]
[[ $(cat "$MOCK/scratch") = "$work/scratch space/$(id -un)/123" ]]
echo connect > "$MOCK/mode"
run connect
grep -q -- '--pty' "$MOCK/srun.args"
grep -q -- '--overlap' "$MOCK/srun.args"
touch "$MOCK/cancel-fail"
expect_fail run cancel
[[ -f $XDG_STATE_HOME/slurm-utils/current ]]
rm "$MOCK/cancel-fail"
run cancel
[[ ! -f $XDG_STATE_HOME/slurm-utils/current ]]
[[ -d $work/scratch\ space/$(id -un)/123 ]]
cp "$work/good-config" "$config"
run schedule
: > "$MOCK/queue"
run status | grep -q FINISHED
run schedule
export SUBMIT_RESULT='garbage'
expect_fail run schedule
run status | grep -q 'Job: 123'
unset SUBMIT_RESULT
# All scratch roots unusable: payload fails clearly.
printf 'SCRATCH_ROOTS=(/nonexistent)\n' >> "$config"
run schedule
expect_fail env SLURM_JOB_ID=124 bash "$(cat "$MOCK/batch")"
grep -q 'No usable configured scratch root' "$work/output"
echo 'All shell tests passed'
