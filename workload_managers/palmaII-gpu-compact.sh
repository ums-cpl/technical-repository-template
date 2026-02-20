#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
NUM_TASKS="$2"
[[ "$NUM_TASKS" -eq 0 ]] && { echo "Error: No tasks to submit." >&2; exit 1; }
RUNNER="$REPOSITORY_ROOT/run_tasks.sh"
ARRAY_MAX=$((NUM_TASKS - 1))
OUTPUT_DIR="$(dirname "$MANIFEST")"

TMP=$(mktemp)
trap "rm -f $TMP" EXIT

cat > "$TMP" << WRAPPER
#!/bin/bash
#SBATCH --array=0-${ARRAY_MAX}
#SBATCH --partition=gpuexpress
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=28gb
#SBATCH --time=${WALLTIME:-2:00:00}
#SBATCH --job-name=${JOB_NAME:-run_tasks}
#SBATCH --output=${OUTPUT_DIR}/task_%a.out
#SBATCH --error=${OUTPUT_DIR}/task_%a.err

module add Apptainer
TASK_ID=\${SLURM_ARRAY_TASK_ID}
exec "$RUNNER" --array-manifest="$MANIFEST" --array-task-id=\$TASK_ID
WRAPPER

sbatch "$TMP"
