#!/usr/bin/env bash
# All scheduler commands are fakes; no cluster access or jobs are needed.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export VMEM_TEST_WORK="$work"
mkdir -p "$work/bin" "$work/log space"
export PATH="$work/bin:$PATH"
unset BASH_ENV
cat > "$work/bin/sinfo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$VMEM_TEST_WORK/sinfo.args"
[[ ! -e $VMEM_TEST_WORK/inventory-fail ]] || exit 1
cat "$VMEM_TEST_WORK/inventory"
MOCK
cat > "$work/bin/sbatch" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 = --test-only ]]; then
    printf '%s\n' "$*" >> "$VMEM_TEST_WORK/estimates"
    for arg in "$@"; do
        case $arg in --gres=*) request=${arg#--gres=} ;; esac
    done
    type=${request#gpu:}; type=${type%:*}
    [[ ! -e $VMEM_TEST_WORK/estimate-fail ]] || exit 1
    [[ -f $VMEM_TEST_WORK/$type.start ]] || { echo 'Unavailable' >&2; exit 1; }
    printf 'sbatch: Job 1 to start at %s using 4 processors\n' "$(cat "$VMEM_TEST_WORK/$type.start")" >&2
else
    printf '%s\n' "$@" > "$VMEM_TEST_WORK/submit.args"
    printf 'submit\n' >> "$VMEM_TEST_WORK/submissions"
    [[ ! -e $VMEM_TEST_WORK/submit-fail ]] || exit 1
    echo 123
fi
MOCK
cat > "$work/bin/squeue" <<'MOCK'
#!/usr/bin/env bash
printf '123|RUNNING|node1\n'
MOCK
chmod +x "$work/bin/"*
config="$work/config space.sh"
cat > "$config" <<CFG
JOB_NAME=vmem-test
PARTITION=ICF-Free
GRES=gpu:1
CPUS_PER_TASK=4
MEMORY=16G
TIME_LIMIT=04:00:00
LOG_DIR=$(printf %q "$work/log space")
SCRATCH_ROOTS=(/tmp)
CFG
cat > "$work/inventory" <<'INVENTORY'
gpu:h200:1(S:0),gpu:h200_3g.71gb:4(S:0),gpu:h200_1g.18gb:35(S:0-1)
gpu:a40:4(S:0-1)
gpu:a40:8(S:0-1)
gpu:nvidia_l40s:4(S:0-1)
gpu:mystery:1
gpu:nvidia_geforce_rtx_2080_ti:8(S:0-1)
gpu:nvidia_rtx_a6000:8(S:0-1)
gpu:nvidia_rtx_pro_6000_blackwell_server_edition:4(S:0-15)
INVENTORY
for type in a40 h200 h200_3g.71gb nvidia_l40s; do
    printf '2026-11-07T14:00:00\n' > "$work/$type.start"
done
printf '2026-11-07T13:00:00\n' > "$work/h200_3g.71gb.start"
case_number=0
fresh() {
    case_number=$((case_number + 1))
    export XDG_STATE_HOME="$work/state $case_number"
    : > "$work/submissions"
    : > "$work/estimates"
}
run() { "$repo/slurm-utils" --config "$config" "$@" > "$work/output" 2>&1; }
expect_fail() {
    if run "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi
    [[ ! -s $work/submissions ]]
    [[ ! -f $XDG_STATE_HOME/slurm-utils/current ]]
}
fresh
run schedule --vmem 30
[[ $(wc -l < "$work/submissions") = 1 ]]
[[ $(wc -l < "$work/estimates") = 6 ]]
grep -Fxq -- '--partition=ICF-Free' "$work/sinfo.args"
grep -Fxq -- '--gres=gpu:h200_3g.71gb:1' "$work/submit.args"
[[ $(grep -c -- '--gres=gpu:a40:1' "$work/estimates") = 1 ]]
! grep -q 'h200_1g.18gb' "$work/estimates"
grep -q 'Skipping GPU mystery: unknown VRAM' "$work/output"
grep -q 'Considering GPUs with at least 30 GB' "$work/output"
grep -q 'gpu:a40:1 (48 GB per GPU)' "$work/output"
grep -q 'gpu:nvidia_rtx_pro_6000_blackwell_server_edition:1 (96 GB' "$work/output"
grep -q 'gpu:a40:1: estimated start 2026-11-07T14:00:00 UTC' "$work/output"
grep -q 'Chosen GPU: gpu:h200_3g.71gb:1.*expected start 2026-11-07T13:00:00 UTC' "$work/output"
grep -q 'estimate unavailable' "$work/output"
# Actual selection is saved; active allocation stops all further queries/submits.
# shellcheck disable=SC1091
source "$XDG_STATE_HOME/slurm-utils/current"
grep -q '^GRES=gpu:h200_3g.71gb:1$' "$LAUNCH_DIR/settings.sh"
: > "$work/submissions"
if run schedule --vmem 30; then exit 1; fi
grep -q 'still RUNNING' "$work/output"
[[ ! -s $work/submissions ]]

# Minimum is inclusive, preserved GPU count is per GPU, and ties are stable.
printf '2026-11-07T14:00:00\n' > "$work/h200_3g.71gb.start"
printf 'GRES=gpu:nvidia_h200:2\n' >> "$config"
fresh
run schedule --vmem 48G
grep -Fxq -- '--gres=gpu:a40:2' "$work/submit.args"

# A site capacity override supports otherwise unknown names; suffixes support
# new model names and MIG profiles without a catalog update.
printf 'declare -A GPU_MEMORY_GB=([mystery]=64)\n' >> "$config"
printf '2026-11-07T12:00:00\n' > "$work/mystery.start"
fresh
run schedule --vmem 64GB
grep -Fxq -- '--gres=gpu:mystery:2' "$work/submit.args"
! grep -q 'gpu:a40:' "$work/estimates"
printf 'gpu:new_model_80gb:1(S:0)\n' >> "$work/inventory"
printf '2026-11-07T11:00:00\n' > "$work/new_model_80gb.start"
fresh
run schedule --vmem 80
grep -Fxq -- '--gres=gpu:new_model_80gb:2' "$work/submit.args"

# Empty partition omits its flag; an empty GRES defaults to one GPU.
printf "PARTITION=''\nGRES=''\n" >> "$config"
fresh
run schedule --vmem 80
! grep -q -- '--partition' "$work/sinfo.args"
grep -Fxq -- '--gres=gpu:new_model_80gb:1' "$work/submit.args"

# Unknown capacity is never guessed, and all failure paths avoid submission.
fresh
expect_fail schedule --vmem 999
for value in 0 -1 1.5 nope 30M 1000000; do
    fresh
    expect_fail schedule --vmem "$value"
done
fresh; expect_fail schedule --vmem
fresh; expect_fail status --vmem 30
fresh; expect_fail schedule --vmem 30 --vmem 40
touch "$work/inventory-fail"
fresh; expect_fail schedule --vmem 30
rm "$work/inventory-fail"
touch "$work/estimate-fail"
fresh; expect_fail schedule --vmem 30
rm "$work/estimate-fail"
for start_file in "$work/"*.start; do printf 'not-a-time\n' > "$start_file"; done
fresh; expect_fail schedule --vmem 80
printf 'GRES=gpu:1,gpu:a40:1\n' >> "$config"
fresh; expect_fail schedule --vmem 30
# Plain schedule continues to submit the configured request without discovery.
fresh
run schedule
[[ ! -s $work/estimates ]]
grep -Fxq -- '--gres=gpu:1,gpu:a40:1' "$work/submit.args"
echo 'All VRAM selection tests passed'
