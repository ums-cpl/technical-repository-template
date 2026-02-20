#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
[[ -z "$MANIFEST" ]] && { echo "Error: Manifest path required." >&2; exit 1; }
RUNNER="$REPOSITORY_ROOT/run_tasks.sh"
OUTPUT_DIR="$(dirname "$MANIFEST")"

SBATCH_PARTITION="express,normal,long"
SBATCH_CPUS_PER_TASK="4"
SBATCH_MEM="10gb"
SBATCH_TIME="${WALLTIME:-2:00:00}"

source "$(dirname "$0")/slurm_common.sh"
parse_and_submit "$MANIFEST"
