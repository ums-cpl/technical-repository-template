#!/usr/bin/env bash
# Task execution and manifest creation for workload manager.

run_task() {
  local task_dir="$1"
  local run_name="$2"
  local run_folder="$task_dir/$run_name"

  # Collect task_meta.sh and run_env.sh files (root-to-leaf)
  local f
  local meta_files=() run_env_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_env_files+=("$f")
  done < <(get_run_env_files "$task_dir")

  # Build source commands with overrides interleaved (task_meta.sh and run_env.sh chains)
  local source_cmds_meta
  source_cmds_meta=$(build_source_cmds_with_overrides meta_files)

  local source_cmds_run_env
  source_cmds_run_env=$(build_source_cmds_with_overrides run_env_files)

  # Resolve CONTAINER and CONTAINER_DEF from task_meta.sh chain with framework vars
  local container_path container_def container_gpu
  container_path=$(bash -c "
    export CONTAINERS=\"$CONTAINERS\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    $source_cmds_meta
    echo -n \"\${CONTAINER:-}\"
  " | xargs)
  container_def=$(bash -c "
    export CONTAINERS=\"$CONTAINERS\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    $source_cmds_meta
    echo -n \"\${CONTAINER_DEF:-}\"
  " | xargs)
  container_gpu=$(bash -c "
    export CONTAINERS=\"$CONTAINERS\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    $source_cmds_meta
    echo -n \"\${CONTAINER_GPU:-}\"
  " | xargs)

  # Dry-run mode: no file changes, caller prints DRY RUN status
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  # Error if CONTAINER is set but .sif does not exist
  if [[ -n "$container_path" ]]; then
    if [[ ! -f "$container_path" ]]; then
      echo "Error: Container image not found: $container_path" >&2
      if [[ -n "$container_def" ]]; then
        echo "Build it with: apptainer build $container_path $container_def" >&2
      fi
      return 1
    fi

    # Verify container .sif was built from CONTAINER_DEF
    if [[ "$SKIP_VERIFY_DEF" != true ]] && [[ -n "$container_def" ]]; then
      if [[ ! -f "$container_def" ]]; then
        echo "Error: Definition file not found: $container_def; cannot verify container. Use --skip-verify-def to run anyway." >&2
        return 1
      fi
      normalize_def() { sed -e 's/^[bB]ootstrap:/Bootstrap:/' -e 's/^[fF]rom:/From:/'; }
      diff_log="$run_folder/.container_verify_diff.log"
      diff_out=$(mktemp)
      if ! diff <(apptainer inspect --deffile "$container_path" | normalize_def) <(normalize_def < "$container_def") > "$diff_out" 2>&1; then
        mkdir -p "$run_folder"
        {
          echo "Container definition verification failed."
          echo "Comparing: embedded def in $container_path vs. $container_def"
          echo "---"
          cat "$diff_out"
        } > "$diff_log"
        rm -f "$diff_out"
        echo "Error: Container $container_path was not built from $container_def (definitions differ). Rebuild with: apptainer build $container_path $container_def. Use --skip-verify-def to run anyway." >&2
        echo "Diff written to $diff_log" >&2
        return 1
      fi
      rm -f "$diff_out"
    fi
  fi

  # For metadata: was container verified? (only relevant when CONTAINER is set)
  container_verified="n/a"
  if [[ -n "$container_path" ]]; then
    if [[ "$SKIP_VERIFY_DEF" == true ]] || [[ -z "$container_def" ]]; then
      container_verified="skipped"
    else
      container_verified="true"
    fi
  fi

  # Create runner script (self-contained for manual re-runs; invokes apptainer when CONTAINER set)
  mkdir -p "$run_folder"
  local runner_script="$run_folder/.run_script.sh"
  cat > "$runner_script" << RUNNER_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
export CONTAINERS="$CONTAINERS"
export ASSETS="$ASSETS"
export TASKS="$TASKS"
export WORKLOAD_MANAGERS="$WORKLOAD_MANAGERS"
export REPOSITORY_ROOT="$REPOSITORY_ROOT"
export RUN_FOLDER="$run_folder"

# Remove all files in run folder except this script
find "\$RUN_FOLDER" -mindepth 1 -maxdepth 1 ! -name '.run_script.sh' -exec rm -rf {} +

# Source task_meta.sh chain (static task configuration)
$source_cmds_meta

# If CONTAINER set and not already inside container, re-exec inside apptainer
if [[ -z "\${CONTAINER_INNER:-}" ]] && [[ -n "\${CONTAINER:-}" ]]; then
  gpu_flag=""
  [[ -n "\${CONTAINER_GPU:-}" ]] && gpu_flag="--nv "
  exec apptainer exec \$gpu_flag -B "$REPOSITORY_ROOT:$REPOSITORY_ROOT" "\$CONTAINER" env CONTAINER_INNER=1 bash "\$(cd "\$(dirname "\$0")" && pwd)/.run_script.sh"
fi

# Export RUN_ID and source run_env.sh chain (runtime helpers)
export RUN_ID="$run_name"
$source_cmds_run_env

exec > >(tee "\$RUN_FOLDER/.run_output.log") 2>&1
cd "\$RUN_FOLDER"
{
  echo "=== git ==="
  if [[ -n "\${REPOSITORY_ROOT:-}" ]] && git -C "\$REPOSITORY_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "\$REPOSITORY_ROOT" status 2>/dev/null || true
    echo "---"
    git -C "\$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || true
  else
    echo "not a git repository"
  fi
  echo ""
  echo "=== container ==="
  echo "container: ${container_path:-}"
  echo "container_def: ${container_def:-}"
  echo "verified: $container_verified"
  echo ""
  echo "=== environment ==="
  env 2>/dev/null | sort || true
  echo ""
  echo "=== hardware ==="
  echo "--- cpu ---"
  echo "cores: \$(nproc 2>/dev/null || echo N/A)"
  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null || true
  else
    grep -E '^model name|^cpu MHz' /proc/cpuinfo 2>/dev/null | head -4 || echo "N/A"
  fi
  echo ""
  echo "--- memory ---"
  if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null || true
  else
    grep MemTotal /proc/meminfo 2>/dev/null || echo "N/A"
  fi
  echo ""
  echo "--- gpu ---"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,memory.used,clocks.current.graphics --format=csv 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
} > "\$RUN_FOLDER/.run_metadata"
date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_begin"
set +e
. "$task_dir/run.sh"
task_exit=\$?
set -e
if [[ \$task_exit -eq 0 ]]; then
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_success"
else
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_failed"
  exit \$task_exit
fi
RUNNER_SCRIPT
  chmod u+x "$runner_script"

  # Run task: runner script tees to .run_output.log; suppress console when invoked from run_tasks.sh
  bash "$runner_script" > /dev/null 2>&1
  return $?
}

# Creates a single manifest file with multiple jobs, each with tasks and dependencies.
# Format: header (SKIP_VERIFY_DEF, env overrides, ---), then JOB blocks with DEPENDS and INDEX<TAB>RUN<TAB>PATH.
# When RUN_TASKS_PRECOMPUTED_TASK_STAGE and RUN_TASKS_PRECOMPUTED_MAX_STAGE are set (by main for direct
# execution), uses them instead of calling compute_stages. Avoids duplicate stage computation.
create_manifest() {
  local -n _task_run_pairs=$1
  local -n _tasks_unique=$2
  local manifest_path job_safe inv_dir n

  declare -A task_stage
  declare -A task_dep_checks
  local max_stage=0
  if [[ -n "${RUN_TASKS_PRECOMPUTED_MAX_STAGE+1}" ]]; then
    local k
    for k in "${!RUN_TASKS_PRECOMPUTED_TASK_STAGE[@]}"; do
      task_stage["$k"]="${RUN_TASKS_PRECOMPUTED_TASK_STAGE[$k]}"
    done
    max_stage=$RUN_TASKS_PRECOMPUTED_MAX_STAGE
    unset RUN_TASKS_PRECOMPUTED_TASK_STAGE RUN_TASKS_PRECOMPUTED_MAX_STAGE
  else
    compute_stages "$2" "$1" task_stage max_stage task_dep_checks
  fi

  job_safe="${JOB_NAME:-run_tasks}"
  job_safe="${job_safe//[\/ ]/_}"
  inv_dir="$RUN_TASKS_OUTPUT_ROOT/${job_safe}"
  if [[ -d "$inv_dir" ]]; then
    n=1
    while [[ -d "$RUN_TASKS_OUTPUT_ROOT/${job_safe}_${n}" ]]; do
      n=$((n + 1))
    done
    inv_dir="$RUN_TASKS_OUTPUT_ROOT/${job_safe}_${n}"
  fi
  mkdir -p "$inv_dir"
  manifest_path="$inv_dir/manifest"

  {
    echo "SKIP_VERIFY_DEF=$SKIP_VERIFY_DEF"
    for ov in "${ENV_OVERRIDES[@]}"; do
      echo "$ov"
    done
    echo "---"
    local stage job_id task_dir run_name i prev_job_id=-1
    for stage in $(seq 0 "$max_stage"); do
      # Build (task, run) pairs for this stage from _task_run_pairs; when SKIP_SUCCEEDED, exclude already-succeeded runs
      local pairs=()
      local pair
      for pair in "${_task_run_pairs[@]}"; do
        task_dir="${pair%%	*}"
        run_name="${pair#*	}"
        [[ "${task_stage[$task_dir]:--1}" != "$stage" ]] && continue
        if [[ "$SKIP_SUCCEEDED" != true ]] || ! is_task_succeeded "$task_dir" "$run_name"; then
          pairs+=("$task_dir	$run_name")
        fi
      done
      [[ ${#pairs[@]} -eq 0 ]] && continue
      job_id=$((prev_job_id + 1))
      echo "JOB	$job_id"
      local dep_list=""
      [[ $prev_job_id -ge 0 ]] && dep_list="$prev_job_id"
      echo "DEPENDS	$dep_list"
      i=0
      for pair in "${pairs[@]}"; do
        task_dir="${pair%%	*}"
        run_name="${pair#*	}"
        relative_path="${task_dir#$REPOSITORY_ROOT/}"
        printf '%d\t%s\t%s\n' "$i" "$run_name" "$relative_path"
        i=$((i + 1))
      done
      prev_job_id=$job_id
    done
  } > "$manifest_path"

  # Script to print exit states from task run folders
  cat > "$inv_dir/show_exit_states.sh" << 'EXIT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
MANIFEST="$(cd "$(dirname "$0")" && pwd)/manifest"
[[ ! -f "$MANIFEST" ]] && { echo "Error: manifest not found: $MANIFEST" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "JOB/IDX  RUN                          PATH                                                              STATUS "
echo "-------  ---------------------------  ----------------------------------------------------------------  -------"
prev_job=""
while IFS=$'\t' read -r job_id idx run path; do
  [[ -z "$path" ]] && continue
  if [[ "$job_id" != "$prev_job" ]]; then
    [[ -n "$prev_job" ]] && echo ""
    prev_job="$job_id"
  fi
  run_folder="$REPO_ROOT/$path/$run"
  if [[ -f "$run_folder/.run_success" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.run_success" ]]; then
    status=$'\033[32mSUCCESS\033[0m'
  elif [[ -f "$run_folder/.run_failed" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.run_failed" ]]; then
    status=$'\033[31mFAILED\033[0m'
  elif [[ -f "$run_folder/.run_begin" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.run_begin" ]]; then
    status=$'\033[92mRUNNING\033[0m'
  else
    status=$'\033[2mPENDING\033[0m'
  fi
  if [[ "$path" == *"/tasks/"* ]]; then
    display_path="tasks/${path#*/tasks/}"
  else
    display_path="$path"
  fi
  printf "%-7s  %-27s  %-64s  %b\n" "${job_id}/${idx}" "$run" "$display_path" "$status"
done < <(awk -F'\t' 'BEGIN{j=""} /^JOB\t/ {j=$2; next} /^[0-9]+\t/ {print j"\t"$0}' "$MANIFEST")
EXIT_SCRIPT
  chmod +x "$inv_dir/show_exit_states.sh"

  echo "$manifest_path"
}

# Run a single task from a manifest (array execution mode).
# Requires --array-job-id and --array-task-id. Looks up job block and task within it.
run_array_task() {
  local manifest="$1"
  local job_id="$2"
  local task_id="$3"
  local line task_dir

  # Parse header: SKIP_VERIFY_DEF, then KEY=VALUE lines until ---
  ENV_OVERRIDES=()
  while IFS= read -r line; do
    [[ "$line" == "---" ]] && break
    if [[ "$line" == SKIP_VERIFY_DEF=* ]]; then
      SKIP_VERIFY_DEF="${line#SKIP_VERIFY_DEF=}"
    elif [[ "$line" == *=* ]]; then
      ENV_OVERRIDES+=("$line")
    fi
  done < "$manifest"

  # Find job block for job_id, then task at task_id. Format: JOB N, DEPENDS ..., INDEX RUN PATH
  local manifest_line run_name
  manifest_line=$(awk -F'\t' -v jid="$job_id" -v tid="$task_id" '
    /^JOB\t/ { cur=$2; next }
    /^[0-9]+\t/ && cur==jid && $1==tid { print; exit }
  ' "$manifest")
  if [[ -z "$manifest_line" ]]; then
    echo "Error: No task found for job $job_id index $task_id in manifest $manifest" >&2
    return 1
  fi
  run_name=$(echo "$manifest_line" | awk -F'\t' '{print $2}')
  task_dir=$(echo "$manifest_line" | awk -F'\t' '{print $3}')
  [[ "$task_dir" != /* ]] && task_dir="$REPOSITORY_ROOT/$task_dir"

  run_task "$task_dir" "$run_name"
}
