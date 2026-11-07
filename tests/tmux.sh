#!/usr/bin/env bash
# Real tmux, fake Slurm: verify the commands launched by new windows and panes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
export REAL_TMUX
REAL_TMUX=$(command -v tmux) || { echo 'tmux required for this test' >&2; exit 1; }
work=$(mktemp -d)
export TEST_SOCKET="$work/tmux.sock" TEST_WORK="$work"
cleanup() {
    "$REAL_TMUX" -S "$TEST_SOCKET" kill-server 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT
unset TMUX TMUX_PANE BASH_ENV
export HOME="$work/home" XDG_STATE_HOME="$work/state ' space"
mkdir -p "$HOME" "$work/bin" "$work/project ' space"
export PATH="$work/bin:$PATH"
cat > "$work/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case $1 in
    attach-session|switch-client) printf '%s\n' "$@" > "$TEST_WORK/attach"; exit 0 ;;
esac
exec "$REAL_TMUX" -S "$TEST_SOCKET" -f /dev/null "$@"
MOCK
cat > "$work/bin/squeue" <<'MOCK'
#!/usr/bin/env bash
echo '123|RUNNING|compute1'
MOCK
cat > "$work/bin/srun" <<'MOCK'
#!/usr/bin/env bash
[[ $1 = --jobid && $2 = 123 && $3 = --overlap ]] || exit 1
while [[ $1 != bash ]]; do shift; done
exec "$@"
MOCK
cat > "$work/bin/zsh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$PWD|$SCRATCH_DIR|${TMUX-unset}|${TMUX_PANE-unset}|$*" >> "$TEST_WORK/shells"
exec sleep 120
MOCK
chmod +x "$work/bin/"*
launch="$XDG_STATE_HOME/slurm-utils/launch.test"
mkdir -p "$launch"
printf 'JOB_ID=123\nLAUNCH_DIR=%q\n' "$launch" > "$XDG_STATE_HOME/slurm-utils/current"
printf 'LOG_DIR=%q\n' "$work" > "$launch/settings.sh"
printf '%s\n' "$work/scratch ' space" > "$launch/scratch-123"
session=slurm-utils-123-test
wait_shells() {
    for ((i=0; i<100; i++)); do
        if [[ -f $work/shells ]] && [[ $(wc -l < "$work/shells") = "$1" ]]; then return; fi
        sleep 0.05
    done
    echo "Expected $1 compute shells" >&2
    tmux capture-pane -p -t "=$session:" >&2 || true
    exit 1
}

# An existing server and unrelated session must retain their defaults.
tmux new-session -d -s unrelated 'sleep 120'
tmux set-option -t unrelated default-command 'sleep 120'
(cd "$work/project ' space" && "$repo/slurm-utils" connect)
wait_shells 1
grep -Fxq attach-session "$work/attach"
grep -Fxq "=$session" "$work/attach"
[[ $(tmux show-option -v -t unrelated default-command) = 'sleep 120' ]]

tmux new-window -t "=$session"
wait_shells 2
tmux split-window -t "=$session:"
wait_shells 3
expected="$work/project ' space|$work/scratch ' space|unset|unset|--login"
[[ $(grep -Fxc -- "$expected" "$work/shells") = 3 ]]

# Reconnecting from a different directory keeps the existing session/launcher.
(cd "$work" && timeout 5 "$repo/slurm-utils" connect)
[[ $(wc -l < "$work/shells") = 3 ]]
TMUX=existing-client timeout 5 "$repo/slurm-utils" connect
grep -Fxq switch-client "$work/attach"
tmux new-window -t "=$session"
wait_shells 4
[[ $(grep -Fxc -- "$expected" "$work/shells") = 4 ]]

# Closing the session allows connect to recreate it for the same allocation.
tmux kill-session -t "=$session"
(cd "$work/project ' space" && timeout 5 "$repo/slurm-utils" connect)
wait_shells 5
echo 'All tmux integration tests passed'
