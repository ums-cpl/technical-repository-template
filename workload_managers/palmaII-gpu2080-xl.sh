#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="${3:?Error: Stage number required.}"
[[ -z "$MANIFEST" ]] && { echo "Error: Manifest path required." >&2; exit 1; }
[[ -z "$LOG_DIR" ]] && { echo "Error: Log directory required." >&2; exit 1; }
RUNNER="$REPOSITORY_ROOT/run_tasks.sh"
OUTPUT_DIR="$LOG_DIR"

SBATCH_PARTITION="gpu2080"
SBATCH_GRES="gpu:1"
SBATCH_CPUS_PER_TASK="4"
SBATCH_MEM="28gb"
SBATCH_TIME="${WALLTIME:-3-00:00:00}"

source "$(dirname "$0")/slurm_common.sh"
parse_and_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"
