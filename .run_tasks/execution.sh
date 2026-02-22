#!/usr/bin/env bash
# Task execution and manifest creation for workload manager.

run_task() {
  local task_dir="$1"
  local run_name="$2"
  local run_folder="$task_dir/$run_name"

  # Collect all env files from tasks/ root down to this task's directory
  local env_file
  local env_files=() env_host_files=() env_container_files=()
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && env_files+=("$env_file")
  done < <(get_env_files "$task_dir")
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && env_host_files+=("$env_file")
  done < <(get_env_host_files "$task_dir")
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && env_container_files+=("$env_file")
  done < <(get_env_container_files "$task_dir")

  # Build source commands: env.sh first, then env_host.sh or env_container.sh
  local source_cmds_host=""
  for ef in "${env_files[@]}"; do
    source_cmds_host+="source \"$ef\"; "
  done
  for ef in "${env_host_files[@]}"; do
    source_cmds_host+="source \"$ef\"; "
  done

  local source_cmds_container=""
  for ef in "${env_files[@]}"; do
    source_cmds_container+="source \"$ef\"; "
  done
  for ef in "${env_container_files[@]}"; do
    source_cmds_container+="source \"$ef\"; "
  done

  # Build export commands for overrides
  local export_cmds=""
  for ov in "${ENV_OVERRIDES[@]}"; do
    export_cmds+="export $ov; "
  done

  # Resolve CONTAINER and CONTAINER_GPU from environment (sourcing env files on host)
  local container_path container_gpu
  container_path=$(bash -c "
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export RUN_FOLDER=\"$run_folder\"
    export RUN=\"$run_name\"
    $source_cmds_host
    $export_cmds
    echo -n \"\${CONTAINER:-}\"
  " | xargs)
  container_gpu=$(bash -c "
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export RUN_FOLDER=\"$run_folder\"
    export RUN=\"$run_name\"
    $source_cmds_host
    $export_cmds
    echo -n \"\${CONTAINER_GPU:-}\"
  " | xargs)

  # Dry-run mode: no file changes, caller prints DRY RUN status
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  # Error if CONTAINER is set but .sif does not exist
  if [[ -n "$container_path" ]]; then
    if [[ ! -f "$container_path" ]]; then
      local def_name
      def_name="$(basename "${container_path%.sif}").def"
      echo "Error: Container image not found: $container_path" >&2
      echo "Build it with: apptainer build $container_path containers/$def_name" >&2
      return 1
    fi

    # Verify container .sif was built from the corresponding .def in containers/
    if [[ "$SKIP_VERIFY_DEF" != true ]]; then
      local def_name def_path
      def_name="$(basename "${container_path%.sif}").def"
      def_path="$REPOSITORY_ROOT/containers/$def_name"
      if [[ ! -f "$def_path" ]]; then
        echo "Error: Definition file not found: $def_path; cannot verify container. Use --skip-verify-def to run anyway." >&2
        return 1
      fi
      normalize_def() { sed -e 's/^[bB]ootstrap:/Bootstrap:/' -e 's/^[fF]rom:/From:/'; }
      if ! diff -q <(apptainer inspect --deffile "$container_path" | normalize_def) <(normalize_def < "$def_path") >/dev/null 2>&1; then
        echo "Error: Container $container_path was not built from $def_path (definitions differ). Rebuild with: apptainer build $container_path $def_path. Use --skip-verify-def to run anyway." >&2
        return 1
      fi
    fi
  fi

  # Create runner script (self-contained for manual re-runs; invokes apptainer when CONTAINER set)
  mkdir -p "$run_folder"
  local runner_script="$run_folder/.runner_script.sh"
  local gpu_flag=""
  [[ -n "$container_gpu" ]] && gpu_flag="--nv "
  cat > "$runner_script" << RUNNER_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
export REPOSITORY_ROOT="$REPOSITORY_ROOT"
export RUN_FOLDER="$run_folder"
export RUN="$run_name"

# Remove all files in run folder except this script
find "\$RUN_FOLDER" -mindepth 1 -maxdepth 1 ! -name '.runner_script.sh' -exec rm -rf {} +

# On host: source env_host to get CONTAINER; if set, re-exec self inside apptainer
if [[ -z "\${CONTAINER_INNER:-}" ]]; then
  $source_cmds_host
  if [[ -n "\${CONTAINER:-}" ]]; then
    gpu_flag=""
    [[ -n "\${CONTAINER_GPU:-}" ]] && gpu_flag="--nv "
    exec apptainer exec \$gpu_flag -B "\$REPOSITORY_ROOT:\$REPOSITORY_ROOT" "\$CONTAINER" env CONTAINER_INNER=1 bash "\$(cd "\$(dirname "\$0")" && pwd)/.runner_script.sh"
  fi
else
  :
  $source_cmds_container
fi
$export_cmds

exec > >(tee "\$RUN_FOLDER/.output.log") 2>&1
cd "\$RUN_FOLDER"
date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.begin"
set +e
. "$task_dir/task.sh"
task_exit=\$?
set -e
if [[ \$task_exit -eq 0 ]]; then
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.success"
else
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.failed"
  exit \$task_exit
fi
RUNNER_SCRIPT
  chmod u+x "$runner_script"

  # Run task: runner script tees to .output.log; suppress console when invoked from run_tasks.sh
  bash "$runner_script" > /dev/null 2>&1
  return $?
}

# Creates a single manifest file with multiple jobs, each with tasks and dependencies.
# Format: header (SKIP_VERIFY_DEF, env overrides, ---), then JOB blocks with DEPENDS and INDEX<TAB>RUN<TAB>PATH.
create_manifest() {
  local -n _task_run_pairs=$1
  local -n _tasks_unique=$2
  local manifest_path job_safe inv_dir n

  declare -A task_stage
  declare -A task_dep_checks
  local max_stage=0
  compute_stages "$2" "$1" task_stage max_stage task_dep_checks

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
        printf '%d\t%s\t%s\n' "$i" "$run_name" "$task_dir"
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
echo "JOB/IDX  RUN                          PATH                                                              STATUS "
echo "-------  ---------------------------  ----------------------------------------------------------------  -------"
prev_job=""
while IFS=$'\t' read -r job_id idx run path; do
  [[ -z "$path" ]] && continue
  if [[ "$job_id" != "$prev_job" ]]; then
    [[ -n "$prev_job" ]] && echo ""
    prev_job="$job_id"
  fi
  run_folder="$path/$run"
  if [[ -f "$run_folder/.success" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.success" ]]; then
    status=$'\033[32mSUCCESS\033[0m'
  elif [[ -f "$run_folder/.failed" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.failed" ]]; then
    status=$'\033[31mFAILED\033[0m'
  elif [[ -f "$run_folder/.begin" ]] && [[ ! "$MANIFEST" -nt "$run_folder/.begin" ]]; then
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

  run_task "$task_dir" "$run_name"
}
