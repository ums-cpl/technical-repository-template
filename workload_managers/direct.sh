#!/usr/bin/env bash
# Direct workload manager: run tasks sequentially in the current process.
# Same interface as other workload managers: ./direct.sh "$MANIFEST_PATH" "$LOG_DIR"
# Used by default when no --workload-manager is set.

set -euo pipefail

MANIFEST="${1:?Error: Manifest path required.}"
LOG_DIR="${2:?Error: Log directory required.}"
[[ ! -f "$MANIFEST" ]] && { echo "Error: Manifest not found: $MANIFEST" >&2; exit 1; }

RUNNER="${REPOSITORY_ROOT:?}/run_tasks.sh"

# Parse manifest: job order and task count per job (same structure as slurm_common)
declare -a job_ids=()
declare -A job_task_count=()
current_job=""
in_header=true

while IFS= read -r line; do
  if [[ "$in_header" == true ]]; then
    [[ "$line" == "---" ]] && in_header=false
    continue
  fi
  if [[ "$line" == JOB* ]]; then
    current_job=$(echo "$line" | cut -f2)
    job_ids+=("$current_job")
    continue
  fi
  if [[ "$line" == DEPENDS* ]]; then
    continue
  fi
  if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
    job_task_count["$current_job"]=$((${job_task_count["$current_job"]:-0} + 1))
  fi
done < "$MANIFEST"

# Total runs and stage count for progress message
total_ops=0
for jid in "${job_ids[@]}"; do
  total_ops=$((total_ops + ${job_task_count["$jid"]:-0}))
done
num_stages=${#job_ids[@]}

echo "Running $total_ops run(s) in $num_stages stage(s)..."

current=0
succeeded=0
failed=0

for jid in "${job_ids[@]}"; do
  echo ""
  echo "--- Stage $jid ---"
  count=${job_task_count["$jid"]:-0}
  for ((idx=0; idx<count; idx++)); do
    current=$((current + 1))
    # Get run_name and path from manifest for progress line (INDEX RUN PATH [KEY=VALUE...])
    manifest_line=$(awk -F'\t' -v jid="$jid" -v tid="$idx" '
      /^JOB\t/ { cur=$2; next }
      /^[0-9]+\t/ && cur==jid && $1==tid { print; exit }
    ' "$MANIFEST")
    run_name=""
    path=""
    if [[ -n "$manifest_line" ]]; then
      run_name=$(echo "$manifest_line" | cut -f2)
      path=$(echo "$manifest_line" | cut -f3)
      # Display path: strip leading tasks/ if present
      if [[ "$path" == tasks/* ]]; then
        display_path="${path#tasks/}"
      else
        display_path="$path"
      fi
    else
      display_path="job${jid}/idx${idx}"
      run_name="?"
    fi
    printf "[%0${#total_ops}d/%0${#total_ops}d] %s/%s ... " "$current" "$total_ops" "$display_path" "$run_name"
    if "$RUNNER" --array-manifest="$MANIFEST" --array-job-id="$jid" --array-task-id="$idx" > /dev/null 2>&1; then
      echo -e "\033[0;32mSUCCESS\033[0m"
      succeeded=$((succeeded + 1))
    else
      echo -e "\033[0;31mFAILED\033[0m"
      failed=$((failed + 1))
    fi
  done
done

echo ""
summary="Finished with $succeeded successes and $failed failures."
echo "$summary"
exit $((failed > 0 ? 1 : 0))
