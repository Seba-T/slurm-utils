# shellcheck shell=bash
# Settings are consumed by slurm-utils.
# shellcheck disable=SC2034
# Trusted Bash code: review before sourcing. All resource values are required.
JOB_NAME=inf_job
PARTITION=ICF-Free
GRES=gpu:1
CPUS_PER_TASK=4
MEMORY=16G
TIME_LIMIT=08:00:00

LOG_DIR="$HOME"
SCRATCH_ROOTS=(
  /disk/scratch_fast
  /disk/scratch_big
  /disk/scratch1
  /disk/scratch
)

KEYTAB="$HOME/my.keytab"
ENV_SETUP=""                 # Optional absolute path to a shell setup file
JUPYTER_PORT=8888
