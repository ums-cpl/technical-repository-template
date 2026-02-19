#!/usr/bin/env bash
# Runner script for tasks. Executes tasks with proper environment setup,
# logging, and success tracking. See readme.md for design details.

set -euo pipefail

# --- Configuration ---
REPOSITORY_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASKS_DIR="$REPOSITORY_ROOT/tasks"
RUN_SPEC="assets"
RUN_PROVIDED=false
declare -a RUNS=()
DRY_RUN=false
CLEAN=false
SKIP_VERIFY_DEF=false
WORKLOAD_MANAGER_SCRIPT=""
JOB_NAME=""
WALLTIME=""
ARRAY_MANIFEST=""
ARRAY_TASK_ID=""
declare -a ENV_OVERRIDES=()
declare -a TASK_ARGS=()

# --- Usage ---
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]

Execute tasks. TASK can be:
  - Task directory: path to dir containing task.sh (e.g. tasks/.../task1)
  - Parent directory: recursively finds all descendant dirs with task.sh
  - Wildcard: expands to matching dirs (e.g. tasks/.../*). Use !(pattern) to exclude (e.g. tasks/.../*/!(data))

Options:
  --dry-run              Print tasks only, do not run
  --clean                Remove output folders for specified tasks, do not run
  --run=SPEC             Set run(s) (default: assets). Comma-separated list; each entry is either
                         prefix:start:end (e.g. run:1:10 for run1..run10) or a literal name (e.g. local).
                         With --clean, if omitted, cleans all run folders.
  --job-name=NAME        Set job name for workload manager (default: run_tasks)
  --walltime=TIME        Set walltime for workload manager (e.g. 1:00:00, 5:00:00)
  --workload-manager=SCRIPT  Submit tasks as job array via workload manager script
  --skip-verify-def      Skip verification that container .sif matches containers/*.def
  -h, --help             Show this help

Environment overrides (KEY=VALUE) are applied after sourcing env files.
EOF
}

# --- Argument parsing ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --clean)
        CLEAN=true
        shift
        ;;
      --run=*)
        RUN_SPEC="${1#--run=}"
        RUN_PROVIDED=true
        shift
        ;;
      --job-name=*)
        JOB_NAME="${1#--job-name=}"
        shift
        ;;
      --walltime=*)
        WALLTIME="${1#--walltime=}"
        shift
        ;;
      --workload-manager=*)
        WORKLOAD_MANAGER_SCRIPT="${1#--workload-manager=}"
        shift
        ;;
      --array-manifest=*)
        ARRAY_MANIFEST="${1#--array-manifest=}"
        shift
        ;;
      --array-task-id=*)
        ARRAY_TASK_ID="${1#--array-task-id=}"
        shift
        ;;
      --skip-verify-def)
        SKIP_VERIFY_DEF=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *=*)
        ENV_OVERRIDES+=("$1")
        shift
        ;;
      *)
        TASK_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Expand RUN_SPEC to array of run names. Each comma-separated entry is either:
# - prefix:start:end (e.g. run:1:10 -> run1, run2, ..., run10)
# - a literal string (e.g. local)
expand_run_spec() {
  local spec="$1"
  local -n _out=$2
  _out=()
  local old_ifs="$IFS"
  IFS=,
  for entry in $spec; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [[ "$entry" =~ ^([^:]+):([0-9]+):([0-9]+)$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local start="${BASH_REMATCH[2]}"
      local end="${BASH_REMATCH[3]}"
      local i
      for ((i=start; i<=end; i++)); do
        _out+=("${prefix}${i}")
      done
    else
      [[ -n "$entry" ]] && _out+=("$entry")
    fi
  done
  IFS="$old_ifs"
}

# --- Task resolution ---
# Resolves a single argument to a list of absolute task directory paths.
# Must be called from REPOSITORY_ROOT or with paths relative to it.
resolve_arg() {
  local arg="$1"
  local repo_root="$2"
  local resolved=()

  # Enter the repository root directory to ensure relative path handling,
  # and determine the absolute path of the 'tasks' directory for later checking.
  (cd "$repo_root" || exit 1
  local tasks_root_abs
  tasks_root_abs="$(cd "$repo_root/tasks" && pwd)"

  # Handle wildcards: expand glob and filter to dirs with task.sh
  # (* and ? = standard glob; !( = extglob exclusion)
  if [[ "$arg" == *"*"* || "$arg" == *"?"* || "$arg" == *"!("* ]]; then
    shopt -s extglob  # enable !(pattern) for exclusion
    local expanded path abs
    expanded=($(eval "ls -d $arg" 2>/dev/null || true))
    for path in "${expanded[@]}"; do
      [[ -d "$path" && -f "$path/task.sh" ]] || continue
      abs="$(cd "$path" && pwd)"
      [[ "$abs" == "$tasks_root_abs"* ]] && resolved+=("$abs")
    done
  else
    [[ ! -e "$arg" ]] && { echo "Error: Path does not exist: $arg" >&2; exit 1; }
    # Skip files (e.g. env.sh when glob expands data1/*)
    [[ -f "$arg" ]] && return 0
    [[ ! -d "$arg" ]] && { echo "Error: Not a directory: $arg" >&2; exit 1; }
    local abs_path
    abs_path="$(cd "$arg" && pwd)"
    if [[ "$abs_path" != "$tasks_root_abs"* ]]; then
      echo "Error: Task must be under tasks/: $arg" >&2
      exit 1
    fi
    if [[ -f "$abs_path/task.sh" ]]; then
      resolved+=("$abs_path")
    else
      # Parent directory: find all descendant dirs with task.sh
      while IFS= read -r -d '' path; do
        resolved+=("$(cd "$(dirname "$path")" && pwd)")
      done < <(find "$abs_path" -name "task.sh" -type f -print0 2>/dev/null)
      if [[ ${#resolved[@]} -eq 0 ]]; then
        echo "Error: No tasks found under $arg (no task.sh in descendents)" >&2
        exit 1
      fi
    fi
  fi

  printf '%s\n' "${resolved[@]}"
  )
}

# Resolve all task arguments to a deduplicated, sorted list.
resolve_all_tasks() {
  local all_tasks=()
  local seen=""

  for arg in "${TASK_ARGS[@]}"; do
    while IFS= read -r task_dir; do
      [[ -z "$task_dir" ]] && continue
      # Validate task is under TASKS_DIR
      if [[ "$task_dir" != "$TASKS_DIR"* ]]; then
        echo "Error: Task must be under tasks/: $task_dir" >&2
        exit 1
      fi
      if [[ ! -f "$task_dir/task.sh" ]]; then
        echo "Error: Not a task directory (no task.sh): $task_dir" >&2
        exit 1
      fi
      if [[ "|$seen|" != *"|$task_dir|"* ]]; then
        seen+="|$task_dir|"
        all_tasks+=("$task_dir")
      fi
    done < <(resolve_arg "$arg" "$REPOSITORY_ROOT")
  done

  # Sort for stable ordering
  printf '%s\n' "${all_tasks[@]}" | sort -u
}

# --- Environment building ---
# Collect env.sh files from tasks/ down to task dir, in root-to-leaf order.
get_env_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS_DIR/}"
  local env_files=()
  local current="$TASKS_DIR"

  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/env.sh" ]] && env_files+=("$current/env.sh")
  done

  printf '%s\n' "${env_files[@]}"
}

# Collect env_host.sh files from tasks/ down to task dir, in root-to-leaf order.
get_env_host_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS_DIR/}"
  local env_files=()
  local current="$TASKS_DIR"

  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/env_host.sh" ]] && env_files+=("$current/env_host.sh")
  done

  printf '%s\n' "${env_files[@]}"
}

# Collect env_container.sh files from tasks/ down to task dir, in root-to-leaf order.
get_env_container_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS_DIR/}"
  local env_files=()
  local current="$TASKS_DIR"

  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/env_container.sh" ]] && env_files+=("$current/env_container.sh")
  done

  printf '%s\n' "${env_files[@]}"
}

# --- Manifest (for workload manager job arrays) ---
# Creates a manifest file mapping array index to task path.
# Format: SKIP_VERIFY_DEF, env overrides (one per line), ---, INDEX<TAB>RUN<TAB>PATH per task.
# Each invocation uses workload_logs/<job>/ or workload_logs/<job>_<n>/ if job folder exists (n=1,2,...).
RUN_TASKS_OUTPUT_ROOT="$REPOSITORY_ROOT/workload_logs"
create_manifest() {
  local -n _tasks=$1
  local -n _runs=$2
  local manifest_path job_safe inv_dir n
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
    local i=0
    for run_name in "${_runs[@]}"; do
      for task_dir in "${_tasks[@]}"; do
        printf '%d\t%s\t%s\n' "$i" "$run_name" "$task_dir"
        i=$((i + 1))
      done
    done
  } > "$manifest_path"

  echo "$manifest_path"
}

# Run a single task from a manifest (array execution mode).
run_array_task() {
  local manifest="$1"
  local task_id="$2"
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

  # Look up task dir and run for this array index. Format: INDEX<TAB>RUN<TAB>PATH
  local manifest_line run_name
  manifest_line=$(awk -F'\t' -v id="$task_id" '$1==id {print; exit}' "$manifest")
  if [[ -z "$manifest_line" ]]; then
    echo "Error: No task found for array index $task_id in manifest $manifest" >&2
    return 1
  fi
  run_name=$(echo "$manifest_line" | awk -F'\t' '{print $2}')
  task_dir=$(echo "$manifest_line" | awk -F'\t' '{print $3}')

  run_task "$task_dir" "$run_name"
}

# --- Execution ---
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
      if ! diff -q <(apptainer inspect --deffile "$container_path") "$def_path" >/dev/null 2>&1; then
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

# --- Main ---
main() {
  parse_args "$@"
  expand_run_spec "$RUN_SPEC" RUNS

  # Array execution mode: workload manager invokes us for a single array element
  if [[ -n "$ARRAY_MANIFEST" && -n "$ARRAY_TASK_ID" ]]; then
    run_array_task "$ARRAY_MANIFEST" "$ARRAY_TASK_ID"
    exit $?
  fi

  # Check if any tasks were specified
  if [[ ${#TASK_ARGS[@]} -eq 0 ]]; then
    echo "Error: No tasks specified." >&2
    usage >&2
    exit 1
  fi

  if [[ "$CLEAN" == true ]]; then
    # Clean mode: remove output folders only, with progress output
    local tasks=()
    local task_dir
    while IFS= read -r task_dir; do
      [[ -z "$task_dir" ]] && continue
      tasks+=("$task_dir")
    done < <(resolve_all_tasks)

    local total=${#tasks[@]}
    local current=0

    if [[ "$RUN_PROVIDED" == true ]]; then
      local total_ops=$((${#tasks[@]} * ${#RUNS[@]}))
      echo "Cleaning $total_ops run(s) across $total task(s)$([[ "$DRY_RUN" == true ]] && echo " (dry run)" || true)..."
      local op_counter=0
      for run_name in "${RUNS[@]}"; do
        for task_dir in "${tasks[@]}"; do
          op_counter=$((op_counter + 1))
          local rel_path="${task_dir#$TASKS_DIR/}"
          local run_folder="$task_dir/$run_name"
          printf "[%d/%d] %s/%s ... " "$op_counter" "$total_ops" "$rel_path" "$run_name"
          if [[ -d "$run_folder" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
              echo -e "\033[0;90mDRY RUN\033[0m"
            else
              rm -rf "$run_folder"
              echo -e "\033[0;32mREMOVED\033[0m"
            fi
          else
            if [[ "$DRY_RUN" == true ]]; then
              echo -e "\033[0;90mDRY RUN (not found)\033[0m"
            else
              echo -e "\033[0;32mREMOVED (not found)\033[0m"
            fi
          fi
        done
      done
      total_runs=$total_ops
    else
      shopt -s nullglob
      local total_runs=0
      for task_dir in "${tasks[@]}"; do
        for run_folder in "$task_dir"/*/; do
          [[ -d "$run_folder" ]] && total_runs=$((total_runs + 1))
        done
      done
      echo "Cleaning $total_runs run(s) for $total task(s)$([[ "$DRY_RUN" == true ]] && echo " (dry run)" || true)..."
      local run_counter=0
      local task_counter=0
      for task_dir in "${tasks[@]}"; do
        task_counter=$((task_counter + 1))
        local rel_path="${task_dir#$TASKS_DIR/}"
        local run_folder
        local has_runs=false
        for run_folder in "$task_dir"/*/; do
          [[ -d "$run_folder" ]] || continue
          has_runs=true
          local run_name
          run_name=$(basename "$run_folder")
          run_counter=$((run_counter + 1))
          printf "[%d/%d] %s/%s ... " "$run_counter" "$total_runs" "$rel_path" "$run_name"
          if [[ "$DRY_RUN" == true ]]; then
            echo -e "\033[0;90mDRY RUN\033[0m"
          else
            rm -rf "$task_dir/$run_name"
            echo -e "\033[0;32mREMOVED\033[0m"
          fi
        done
        if [[ "$has_runs" != true ]]; then
          printf "[%d/%d] %s ... " "$task_counter" "$total" "$rel_path"
          echo -e "\033[0;90m(no runs)\033[0m"
        fi
      done
      shopt -u nullglob
    fi
    echo "Cleaned $total_runs run(s) for $total task(s)$([[ "$DRY_RUN" == true ]] && echo " (dry run)" || true)."
    exit 0
  else
    # Resolve tasks
    local tasks=()
    while IFS= read -r task_dir; do
      [[ -z "$task_dir" ]] && continue
      tasks+=("$task_dir")
    done < <(resolve_all_tasks)

    local total=${#tasks[@]}

    # Workload manager path: create manifest, submit job array, exit
    if [[ -n "$WORKLOAD_MANAGER_SCRIPT" ]]; then
      local wm_script manifest_path total_ops
      wm_script="$WORKLOAD_MANAGER_SCRIPT"
      [[ "$wm_script" != /* ]] && wm_script="$REPOSITORY_ROOT/$wm_script"
      if [[ ! -f "$wm_script" ]]; then
        echo "Error: Workload manager script not found: $WORKLOAD_MANAGER_SCRIPT" >&2
        exit 1
      fi
      total_ops=$((${#tasks[@]} * ${#RUNS[@]}))
      if [[ "$DRY_RUN" == true ]]; then
        echo "Would create manifest and call: $wm_script <manifest> $total_ops"
        exit 0
      fi
      manifest_path=$(create_manifest tasks RUNS)
      export REPOSITORY_ROOT
      [[ -n "$JOB_NAME" ]] && export JOB_NAME
      [[ -n "$WALLTIME" ]] && export WALLTIME
      bash "$wm_script" "$manifest_path" "$total_ops"
      exit $?
    fi

    # Direct execution: run each task for each run with progress output
    local current=0
    local total_ops=$((${#tasks[@]} * ${#RUNS[@]}))
    local succeeded=0
    local failed=0

    echo "Running $total_ops run(s) across $total task(s)..."
    for run_name in "${RUNS[@]}"; do
      for task_dir in "${tasks[@]}"; do
        current=$((current + 1))
        local rel_path="${task_dir#$TASKS_DIR/}"
        printf "[%d/%d] %s/%s ... " "$current" "$total_ops" "$rel_path" "$run_name"
        if [[ "$DRY_RUN" == true ]]; then
          echo -e "\033[0;90mDRY RUN\033[0m"
        elif run_task "$task_dir" "$run_name"; then
          echo -e "\033[0;32mSUCCESS\033[0m"
          succeeded=$((succeeded + 1))
        else
          echo -e "\033[0;31mFAILED\033[0m"
          failed=$((failed + 1))
        fi
      done
    done
    if [[ "$DRY_RUN" == true ]]; then
      echo "Finished. $total_ops run(s) (dry run)."
    else
      echo "Finished with $succeeded successes and $failed failures."
    fi
    exit $((failed > 0 ? 1 : 0))
  fi
}

main "$@"
