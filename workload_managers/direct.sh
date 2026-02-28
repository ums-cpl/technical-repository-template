#!/usr/bin/env bash
# Direct workload manager: run tasks sequentially in the current process.
# Interface: ./direct.sh "$MANIFEST_PATH" "$LOG_DIR" "$STAGE"
# Only runs JOB blocks in the given STAGE where WORKLOAD_MANAGER matches this script.

set -euo pipefail

MANIFEST="${1:?Error: Manifest path required.}"
LOG_DIR="${2:?Error: Log directory required.}"
STAGE="${3:?Error: Stage number required.}"
[[ ! -f "$MANIFEST" ]] && { echo "Error: Manifest not found: $MANIFEST" >&2; exit 1; }

RUNNER="${REPOSITORY_ROOT:?}/run_tasks.sh"

# Our identity for filtering (we only run JOBs that list us as WORKLOAD_MANAGER)
OUR_SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Parse manifest: only JOB blocks where STAGE matches $STAGE and WORKLOAD_MANAGER is us
declare -a job_ids=()
declare -A job_task_count=()
current_job=""
current_stage=""
current_wm=""
in_header=true
declare -A job_id_recorded=()

while IFS= read -r line; do
  if [[ "$in_header" == true ]]; then
    [[ "$line" == "---" ]] && in_header=false
    continue
  fi
  if [[ "$line" == JOB* ]]; then
    current_job=$(echo "$line" | cut -f2)
    current_stage=""
    current_wm=""
    continue
  fi
  if [[ "$line" == STAGE* ]]; then
    current_stage=$(echo "$line" | cut -f2)
    continue
  fi
  if [[ "$line" == WORKLOAD_MANAGER* ]]; then
    current_wm=$(echo "$line" | cut -f2)
    [[ "$current_wm" != /* ]] && current_wm="${REPOSITORY_ROOT:?}/$current_wm"
    continue
  fi
  if [[ "$line" == DEPENDS* ]]; then
    continue
  fi
  if [[ "$line" == JOB_NAME* ]]; then
    continue
  fi
  if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
    if [[ "$current_stage" == "$STAGE" ]] && [[ "$current_wm" == "$OUR_SCRIPT_ABS" ]]; then
      job_task_count["$current_job"]=$((${job_task_count["$current_job"]:-0} + 1))
      # Record job id on first task line for this job (order preserved)
      if [[ -z "${job_id_recorded[$current_job]:-}" ]]; then
        job_id_recorded["$current_job"]=1
        job_ids+=("$current_job")
      fi
    fi
  fi
done < "$MANIFEST"

total_ops=0
for jid in "${job_ids[@]}"; do
  total_ops=$((total_ops + ${job_task_count["$jid"]:-0}))
done

[[ $total_ops -eq 0 ]] && exit 0

echo "Running $total_ops run(s) for stage $STAGE..."

current=0
succeeded=0
failed=0

for jid in "${job_ids[@]}"; do
  count=${job_task_count["$jid"]:-0}
  for ((idx=0; idx<count; idx++)); do
    current=$((current + 1))
    manifest_line=$(awk -F'\t' -v jid="$jid" -v tid="$idx" '
      /^JOB\t/ { cur=$2; next }
      /^[0-9]+\t/ && cur==jid && $1==tid { print; exit }
    ' "$MANIFEST")
    run_name=""
    path=""
    if [[ -n "$manifest_line" ]]; then
      run_name=$(echo "$manifest_line" | cut -f2)
      path=$(echo "$manifest_line" | cut -f3)
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
echo "Stage $STAGE: $succeeded successes, $failed failures."
exit $((failed > 0 ? 1 : 0))
