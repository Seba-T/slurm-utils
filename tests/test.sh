#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home space" XDG_STATE_HOME="$work/state space"
export MOCK="$work/mock"
export REAL_BASH
REAL_BASH=$(command -v bash)
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
while [[ $1 != bash ]]; do
    case $1 in --chdir=*) cd -- "${1#--chdir=}" || exit 1 ;; esac
    shift
done
exec "$@"
MOCK
cat > "$MOCK/bin/zsh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$SCRATCH_DIR" "$SHELL" "$@" > "$MOCK/shell"
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
# Omitting the optional port uses 1234, saved with this allocation.
printf 'unset JUPYTER_PORT\n' >> "$config"
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
grep -q -- '--port=1234' "$MOCK/jupyter.args"
grep -q -- '--port-retries=0' "$MOCK/jupyter.args"
grep -q -- '--ip=0.0.0.0' "$MOCK/jupyter.args"
grep -Eq '^[a-f0-9]{64}$' "$MOCK/token"
first=$(cat "$MOCK/token")
run jupyter > "$work/url"
[[ $(cat "$MOCK/token") != "$first" ]]
run jupyter 4567 > "$work/url"
grep -Fxq -- '--port=4567' "$MOCK/jupyter.args"
grep -q ':4567/?token=' "$work/url"
# Port overrides affect only this launch, not the saved default.
run jupyter > "$work/url"
grep -Fxq -- '--port=1234' "$MOCK/jupyter.args"
run jupyter 65535 > "$work/url"
grep -Fxq -- '--port=65535' "$MOCK/jupyter.args"
for invalid_port in 0 65536 -1 0123 12.5 nope ''; do
    expect_fail run jupyter "$invalid_port"
    grep -q 'Jupyter port must be' "$work/output"
done
expect_fail run jupyter 1234 5678
expect_fail run connect 1234
[[ $(cat "$MOCK/scratch") = "$work/scratch space/$(id -un)/123" ]]
echo connect > "$MOCK/mode"
mkdir -p "$work/project space"
(cd "$work/project space" && run connect)
grep -q -- '--pty' "$MOCK/srun.args"
grep -q -- '--overlap' "$MOCK/srun.args"
grep -Fxq -- "--chdir=$work/project space" "$MOCK/srun.args"
[[ $(head -n 1 "$MOCK/shell") = "$work/project space" ]]
grep -Fxq -- '--login' "$MOCK/shell"

# Exercise actual connect code with zsh unavailable, without opening a real shell.
printf '#!%s\n' "$REAL_BASH" > "$MOCK/bin/bash"
cat >> "$MOCK/bin/bash" <<'MOCK'
if [[ ${1:-} = --login ]]; then
    printf '%s\n' "$PWD" "$SCRATCH_DIR" "$@" > "$MOCK/bash-shell"
    exit 0
fi
exec "$REAL_BASH" "$@"
MOCK
cat > "$work/bash-env" <<'MOCK'
command() {
    if [[ ${MOCK_MISSING_ZSH:-} = 1 && $* = '-v zsh' ]]; then return 1; fi
    if [[ ${MOCK_MISSING_CHSH:-} = 1 && $* = '-v chsh' ]]; then return 1; fi
    builtin command "$@"
}
MOCK
chmod +x "$MOCK/bin/bash"
(cd "$work/project space"; env BASH_ENV="$work/bash-env" MOCK_MISSING_ZSH=1 "$repo/slurm-utils" --config "$config" connect) 2> "$work/connect.error"
[[ $(head -n 1 "$MOCK/bash-shell") = "$work/project space" ]]
grep -q 'falling back to Bash' "$work/connect.error"

# Setup prompts and failure handling use fake external installers and account tools.
cat > "$MOCK/bin/chsh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK/chsh.args"
[[ ! -e $MOCK/chsh-fail ]]
MOCK
cat > "$MOCK/bin/python3" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$MOCK/python.args"
[[ ! -e $MOCK/venv-fail ]] || exit 1
mkdir -p .venv/bin
printf 'home = mock\n' > .venv/pyvenv.cfg
printf 'export VIRTUAL_ENV="$PWD/.venv"\nexport PATH="$VIRTUAL_ENV/bin:$PATH"\n' > .venv/bin/activate
cp "$MOCK/venv-python" .venv/bin/python
chmod +x .venv/bin/python
MOCK
cat > "$MOCK/venv-python" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" >> "$MOCK/venv-python.args"
if [[ $1 = -c ]]; then exit 0; fi
case "$*" in
    '-m pip --version') [[ ! -e $MOCK/pip-missing ]] ;;
    '-m ensurepip --upgrade')
        [[ ! -e $MOCK/ensurepip-fail ]] || exit 1
        rm "$MOCK/pip-missing"
        ;;
    '-m pip install notebook ipykernel')
        [[ ! -e $MOCK/pip-fail ]] || exit 1
        cp "$MOCK/venv-jupyter" "$(dirname -- "$0")/jupyter"
        chmod +x "$(dirname -- "$0")/jupyter"
        ;;
    '-m ipykernel install '* )
        [[ ! -e $MOCK/kernel-fail ]] || exit 1
        printf '%s\n' "$0" "$@" > "$MOCK/kernel.args"
        ;;
    *) exit 1 ;;
esac
MOCK
cat > "$MOCK/venv-jupyter" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$0" "$PWD" "$VIRTUAL_ENV" "$@" > "$MOCK/venv-jupyter.args"
MOCK
cat > "$MOCK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$MOCK/curl.args"
[[ ! -e $MOCK/curl-fail ]] || exit 22
[[ ! -e $MOCK/curl-empty ]] || exit 0
cat <<'INSTALLER'
printf '%s\n' "$bin_path" > "$MOCK/bin_path"
[[ ! -e $MOCK/install-fail ]] || exit 1
cp "$MOCK/direnv-template" "$bin_path/direnv"
chmod +x "$bin_path/direnv"
INSTALLER
MOCK
cat > "$MOCK/direnv-template" <<'MOCK'
#!/usr/bin/env bash
case $1 in
    version) echo 2.37.1 ;;
    allow) [[ ! -e $MOCK/allow-fail ]] || exit 1; printf '%s\n' "$PWD" > "$MOCK/allowed" ;;
    hook) printf ':\n' ;;
esac
MOCK
chmod +x "$MOCK/bin/chsh" "$MOCK/bin/python3" "$MOCK/bin/curl"
# Use a separate installed binary, so setup must install direnv beside it.
mkdir -p "$work/installed bin" "$work/setup project"
cp "$repo/slurm-utils" "$work/installed bin/slurm-utils"
setup() { (cd "$work/setup project" && "$work/installed bin/slurm-utils" set-up); }
answers() { printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n'; }
printf 'n\n' > "$work/answers"
expect_fail setup < "$work/answers"
[[ ! -e $work/setup\ project/.venv ]]
# Accept connection, decline venv: no downstream commands may execute.
printf 'y\nn\n' > "$work/answers"
expect_fail setup < "$work/answers"
[[ ! -e $MOCK/python.args && ! -e $MOCK/curl.args ]]
touch "$MOCK/venv-fail"
answers > "$work/answers"
expect_fail setup < "$work/answers"
grep -q 'venv creation failed' "$work/output"
rm "$MOCK/venv-fail"
# Missing zsh fails before changing the project or invoking installers.
(cd "$work/setup project"; expect_fail env BASH_ENV="$work/bash-env" MOCK_MISSING_ZSH=1 "$work/installed bin/slurm-utils" set-up < "$work/answers")
grep -q 'zsh is unavailable' "$work/output"
[[ ! -e $MOCK/curl.args ]]
# chsh failure must preserve an existing envrc and offer the SHELL fallback.
printf '# existing project config\nexport PRESERVED=yes\n' > "$work/setup project/.envrc"
touch "$MOCK/chsh-fail"
setup < "$work/answers" > "$work/setup.output" 2>&1
[[ $(cat "$MOCK/bin_path") = "$work/installed bin" ]]
[[ $(cat "$MOCK/allowed") = "$work/setup project" ]]
grep -q '^export PRESERVED=yes$' "$work/setup project/.envrc"
grep -q '^export SHELL=' "$work/setup project/.envrc"
grep -q '^source .venv/bin/activate$' "$work/setup project/.envrc"
grep -q 'chsh failed' "$work/setup.output"
grep -q 'python3 -m venv .venv' "$work/setup.output"
grep -q 'bin_path=' "$work/setup.output"
grep -q 'pip install notebook ipykernel' "$work/setup.output"
[[ $(head -n 1 "$MOCK/kernel.args") = "$work/setup project/.venv/bin/python" ]]
grep -Fxq -- '--user' "$MOCK/kernel.args"
grep -Eq '^slurm-utils-[a-f0-9]{16}$' "$MOCK/kernel.args"
grep -Fxq -- "Python (.venv: $work/setup project)" "$MOCK/kernel.args"
cp "$MOCK/kernel.args" "$work/kernel-before"
grep -q 'hook zsh' "$HOME/.zshrc"
grep -q 'hook bash' "$HOME/.bashrc"
cp "$work/setup project/.envrc" "$work/envrc-before"
cp "$HOME/.zshrc" "$work/zshrc-before"
setup < "$work/answers" > "$work/setup.output" 2>&1
cmp "$work/envrc-before" "$work/setup project/.envrc"
cmp "$work/zshrc-before" "$HOME/.zshrc"
cmp "$work/kernel-before" "$MOCK/kernel.args"
# No chsh command still offers the project-local fallback.
(cd "$work/setup project"; env BASH_ENV="$work/bash-env" MOCK_MISSING_CHSH=1 "$work/installed bin/slurm-utils" set-up < "$work/answers") > "$work/setup.output" 2>&1
grep -q 'chsh is unavailable' "$work/setup.output"
# Reject chsh but permit its fallback; no call to chsh.
rm "$MOCK/chsh.args"
printf 'y\nn\ny\n' > "$work/answers"
setup < "$work/answers" > "$work/setup.output" 2>&1
[[ ! -e $MOCK/chsh.args ]]
grep -q 'chsh declined' "$work/setup.output"
# A successful chsh needs no fallback in a fresh project's envrc.
rm "$MOCK/chsh-fail"
mv "$work/setup project/.envrc" "$work/envrc-fallback"
answers > "$work/answers"
setup < "$work/answers" > "$work/setup.output" 2>&1
if grep -q '^export SHELL=' "$work/setup project/.envrc"; then exit 1; fi
# A declined allow step leaves the envrc present, but never executes allow.
rm "$MOCK/allowed"
printf 'y\ny\nn\n' > "$work/answers"
expect_fail setup < "$work/answers"
[[ ! -e $MOCK/allowed ]]
grep -q '.envrc not allowed' "$work/output"
answers > "$work/answers"
touch "$MOCK/allow-fail"
expect_fail setup < "$work/answers"
grep -q 'direnv allow failed' "$work/output"
rm "$MOCK/allow-fail" "$MOCK/chsh.args"
# Optional install decline skips pip and registration, but completes setup.
rm "$MOCK/kernel.args" "$MOCK/venv-python.args"
printf 'y\ny\ny\nn\n' > "$work/answers"
setup < "$work/answers" > "$work/setup.output" 2>&1
[[ ! -e $MOCK/kernel.args ]]
if grep -Fxq pip "$MOCK/venv-python.args"; then exit 1; fi
grep -q 'Skipping optional Jupyter' "$work/setup.output"
# Installing packages does not implicitly approve kernel registration.
printf 'y\ny\ny\ny\nn\n' > "$work/answers"
expect_fail setup < "$work/answers"
grep -q 'kernel registration declined' "$work/output"
[[ ! -e $MOCK/kernel.args ]]
answers > "$work/answers"
touch "$MOCK/pip-fail"
expect_fail setup < "$work/answers"
grep -q 'Jupyter installation failed' "$work/output"
[[ ! -e $MOCK/kernel.args ]]
rm "$MOCK/pip-fail"
touch "$MOCK/pip-missing"
setup < "$work/answers" > "$work/setup.output" 2>&1
grep -q 'ensurepip --upgrade' "$work/setup.output"
[[ -f $MOCK/kernel.args && ! -e $MOCK/pip-missing ]]
touch "$MOCK/pip-missing" "$MOCK/ensurepip-fail"
expect_fail setup < "$work/answers"
grep -q 'pip bootstrap failed' "$work/output"
rm "$MOCK/pip-missing" "$MOCK/ensurepip-fail"
touch "$MOCK/kernel-fail"
expect_fail setup < "$work/answers"
grep -q 'kernel registration failed' "$work/output"
rm "$MOCK/kernel-fail" "$MOCK/chsh.args"
# Installation failure and empty responses must stop before account changes.
rm "$work/installed bin/direnv"
answers > "$work/answers"
touch "$MOCK/curl-fail"
expect_fail setup < "$work/answers"
grep -q 'direnv download failed' "$work/output"
[[ ! -e $MOCK/chsh.args ]]
rm "$MOCK/curl-fail"
touch "$MOCK/curl-empty"
expect_fail setup < "$work/answers"
grep -q 'installer download was empty' "$work/output"
rm "$MOCK/curl-empty"
touch "$MOCK/install-fail"
expect_fail setup < "$work/answers"
grep -q 'direnv installation failed' "$work/output"
rm "$MOCK/install-fail"
# Never overwrite a partial or unrelated .venv directory.
mv "$work/setup project/.venv/pyvenv.cfg" "$work/pyvenv.cfg"
expect_fail setup < "$work/answers"
grep -q 'Existing .venv is incomplete' "$work/output"
mv "$work/pyvenv.cfg" "$work/setup project/.venv/pyvenv.cfg"

# A rejected file append preserves the user's file contents.
printf '# user-owned envrc\n' > "$work/setup project/.envrc"
cp "$work/setup project/.envrc" "$work/envrc-before"
printf 'y\ny\ny\nn\n' > "$work/answers"
expect_fail setup < "$work/answers"
cmp "$work/envrc-before" "$work/setup project/.envrc"

touch "$MOCK/cancel-fail"
expect_fail run cancel
[[ -f $XDG_STATE_HOME/slurm-utils/current ]]
rm "$MOCK/cancel-fail"
run cancel
[[ ! -f $XDG_STATE_HOME/slurm-utils/current ]]
[[ -d $work/scratch\ space/$(id -un)/123 ]]
cp "$work/good-config" "$config"
# Without ENV_SETUP, Jupyter should use the newly installed project environment.
printf 'ENV_SETUP=""\n' >> "$config"
run schedule
printf '123|RUNNING|node1\n' > "$MOCK/queue"
SLURM_JOB_ID=123 timeout 2 bash "$(cat "$MOCK/batch")" > "$work/batch.log" 2>&1 || [[ $? = 124 ]]
(cd "$work/setup project" && run jupyter 6789) > "$work/url"
grep -Fxq -- '--port=6789' "$MOCK/venv-jupyter.args"
grep -Fxq -- "$work/setup project/.venv/bin/jupyter" "$MOCK/venv-jupyter.args"
grep -Fxq -- "$work/setup project/.venv" "$MOCK/venv-jupyter.args"
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
