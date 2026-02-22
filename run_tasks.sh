#!/usr/bin/env bash
# Runner script for tasks. Executes tasks with proper environment setup,
# logging, and success tracking. See readme.md for design details.

set -euo pipefail

# --- Configuration ---
REPOSITORY_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASKS_DIR="$REPOSITORY_ROOT/tasks"
declare -a TASK_SPECS=()
declare -a TASK_RUN_PAIRS=()
declare -a TASKS_UNIQUE=()
DRY_RUN=false
CLEAN=false
SKIP_SUCCEEDED=false
SKIP_VERIFY_DEF=false
WORKLOAD_MANAGER_SCRIPT=""
JOB_NAME=""
WALLTIME=""
ARRAY_MANIFEST=""
ARRAY_JOB_ID=""
ARRAY_TASK_ID=""
declare -a ENV_OVERRIDES=()

# --- Usage ---
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]

Execute tasks. TASK can be:
  - Task directory: path to dir containing task.sh (e.g. tasks/.../task1)
  - Parent directory: recursively finds all descendant dirs with task.sh
  - Wildcard: expands to matching dirs (e.g. tasks/.../*). Use !(pattern) to exclude (e.g. tasks/.../*/!(data))

  Optional suffix :RUN_SPEC sets run(s). Examples: :local, :run:1:10, :run* (clean only, wildcard).
  Without suffix: default run "assets" for execute; cleans all runs with --clean.
  Quote the task spec if RUN_SPEC contains * or ? (e.g. "tasks/task1:run*").

Options:
  --dry-run              Create manifest without running (no workload manager submit)
  --clean                Remove output folders for specified tasks, do not run
  --job-name=NAME        Set job name for workload manager (default: run_tasks)
  --walltime=TIME        Set walltime for workload manager (e.g. 1:00:00, 5:00:00)
  --workload-manager=SCRIPT  Submit tasks as job array via workload manager script
  --skip-succeeded       Skip task runs that have already succeeded (.success exists)
  --skip-verify-def      Skip verification that container .sif matches containers/*.def
  -h, --help             Show this help

Environment overrides (KEY=VALUE) are applied after sourcing env files.
EOF
}

# --- Argument parsing ---
# Parse TASK arg into task_path and run_spec. Split on first ':'.
parse_task_spec() {
  local arg="$1"
  if [[ "$arg" == *:* ]]; then
    printf '%s\n%s' "${arg%%:*}" "${arg#*:}"
  else
    printf '%s\n' "$arg"
  fi
}

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
      --array-job-id=*)
        ARRAY_JOB_ID="${1#--array-job-id=}"
        shift
        ;;
      --array-task-id=*)
        ARRAY_TASK_ID="${1#--array-task-id=}"
        shift
        ;;
      --skip-succeeded)
        SKIP_SUCCEEDED=true
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
        TASK_SPECS+=("$1")
        shift
        ;;
    esac
  done
}

# Check if a task run has already succeeded (has .success file).
is_task_succeeded() {
  local task_dir="$1"
  local run_name="$2"
  [[ -f "$task_dir/$run_name/.success" ]]
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

# For clean mode: expand run spec, supporting wildcards (*, ?) that match existing run folders.
expand_run_spec_for_clean() {
  local task_dir="$1"
  local spec="$2"
  local -n _out=$3
  _out=()
  if [[ "$spec" == *"*"* || "$spec" == *"?"* ]]; then
    shopt -s nullglob
    local run_folder
    for run_folder in "$task_dir"/*/; do
      [[ -d "$run_folder" ]] || continue
      local run_name
      run_name=$(basename "$run_folder")
      [[ "$run_name" == $spec ]] && _out+=("$run_name")
    done
    shopt -u nullglob
    # Sort for deterministic ordering
    local -a sorted=()
    local _run
    while IFS= read -r _run; do
      [[ -n "$_run" ]] && sorted+=("$_run")
    done < <(printf '%s\n' "${_out[@]}" | sort)
    _out=("${sorted[@]}")
  else
    local -a tmp_runs=()
    expand_run_spec "$spec" tmp_runs
    _out=("${tmp_runs[@]}")
  fi
}

# Build TASK_RUN_PAIRS and TASKS_UNIQUE from TASK_SPECS.
# TASK_RUN_PAIRS: array of "task_dir<TAB>run_name" in run-first, task-second order
# TASKS_UNIQUE: deduplicated task dirs for stage computation
build_task_run_pairs() {
  TASK_RUN_PAIRS=()
  TASKS_UNIQUE=()
  local -a tasks_ordered=()
  declare -A task_runs=()

  local spec task_path run_spec
  for spec in "${TASK_SPECS[@]}"; do
    [[ -z "$spec" ]] && continue
    local parsed
    set -f
    parsed=($(parse_task_spec "$spec"))
    set +f
    task_path="${parsed[0]}"
    run_spec="${parsed[1]:-}"

    while IFS= read -r task_dir; do
      [[ -z "$task_dir" ]] && continue
      if [[ "$task_dir" != "$TASKS_DIR"* ]]; then
        echo "Error: Task must be under tasks/: $task_dir" >&2
        exit 1
      fi
      if [[ ! -f "$task_dir/task.sh" ]]; then
        echo "Error: Not a task directory (no task.sh): $task_dir" >&2
        exit 1
      fi

      # Add to tasks_ordered on first appearance
      if [[ -z "${task_runs[$task_dir]+x}" ]]; then
        tasks_ordered+=("$task_dir")
        TASKS_UNIQUE+=("$task_dir")
      fi

      # Get runs for this task
      local -a runs=()
      if [[ -z "$run_spec" ]]; then
        if [[ "$CLEAN" == true ]]; then
          shopt -s nullglob
          local run_folder
          for run_folder in "$task_dir"/*/; do
            [[ -d "$run_folder" ]] || continue
            runs+=("$(basename "$run_folder")")
          done
          shopt -u nullglob
          local -a sorted=()
          while IFS= read -r r; do
            [[ -n "$r" ]] && sorted+=("$r")
          done < <(printf '%s\n' "${runs[@]}" | sort)
          runs=("${sorted[@]}")
        else
          runs=("assets")
        fi
      else
        if [[ "$CLEAN" == true ]]; then
          expand_run_spec_for_clean "$task_dir" "$run_spec" runs
        else
          expand_run_spec "$run_spec" runs
        fi
      fi

      # Merge runs into task_runs
      local existing="${task_runs[$task_dir]:-}"
      for r in "${runs[@]}"; do
        existing="${existing:+$existing }$r"
      done
      task_runs["$task_dir"]="$existing"
    done < <(resolve_arg "$task_path" "$REPOSITORY_ROOT")
  done

  # Build TASK_RUN_PAIRS in run-first, task-second order
  local max_runs=0
  local t
  for t in "${tasks_ordered[@]}"; do
    local -a truns=()
    read -ra truns <<< "${task_runs[$t]:-}"
    [[ ${#truns[@]} -gt $max_runs ]] && max_runs=${#truns[@]}
  done

  local run_idx
  for ((run_idx=0; run_idx < max_runs; run_idx++)); do
    for t in "${tasks_ordered[@]}"; do
      local -a truns=()
      read -ra truns <<< "${task_runs[$t]:-}"
      if [[ $run_idx -lt ${#truns[@]} ]]; then
        TASK_RUN_PAIRS+=("$t	${truns[$run_idx]}")
      fi
    done
  done
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

# Collect depends.sh files from tasks/ down to task dir, in root-to-leaf order.
get_depends_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS_DIR/}"
  local depends_files=()
  local current="$TASKS_DIR"

  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/depends.sh" ]] && depends_files+=("$current/depends.sh")
  done

  printf '%s\n' "${depends_files[@]}"
}

# Get TASK_DEPENDS for a task by sourcing env files, applying overrides, then depends.sh.
# Returns array of dependency patterns; empty if no depends.sh or TASK_DEPENDS not set.
# depends.sh is sourced after env.sh, env_host.sh, and ENV_OVERRIDES so variables are available.
get_task_depends() {
  local task_dir="$1"
  local -n _out=$2
  _out=()
  local env_files=() env_host_files=() depends_files=()
  local env_file
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && env_files+=("$env_file")
  done < <(get_env_files "$task_dir")
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && env_host_files+=("$env_file")
  done < <(get_env_host_files "$task_dir")
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] && depends_files+=("$env_file")
  done < <(get_depends_files "$task_dir")

  local source_cmds=""
  for ef in "${env_files[@]}"; do
    source_cmds+="source \"$ef\"; "
  done
  for ef in "${env_host_files[@]}"; do
    source_cmds+="source \"$ef\"; "
  done

  local export_cmds=""
  for ov in "${ENV_OVERRIDES[@]}"; do
    export_cmds+="export $ov; "
  done

  local depends_source_cmds=""
  for df in "${depends_files[@]}"; do
    depends_source_cmds+="source \"$df\"; "
  done

  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && _out+=("$dep")
  done < <(bash -c "
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export RUN_FOLDER=\"$task_dir/assets\"
    $source_cmds
    $export_cmds
    TASK_DEPENDS=()
    $depends_source_cmds
    for d in \"\${TASK_DEPENDS[@]:-}\"; do
      [[ -n \"\$d\" ]] && echo \"\$d\"
    done
  " 2>/dev/null || true)
}

# Compute stages from task dependencies. Populates _task_stage[path]=stage_id.
# Sets _max_stage to max stage id (stages are 0.._max_stage).
# Populates _task_dep_checks with per-task dependency checks for inter-stage verification.
# Each TASK_DEPENDS entry may include a run suffix (e.g. :local, :run:1:10, :run*).
# A dependency is resolved if it is in the current invocation or has .success on disk.
# For task-only deps (no run spec): all runs on disk must have .success, and at least one run must exist (disk or invocation).
compute_stages() {
  local -n _tasks=$1
  local -n _task_run_pairs_ref=$2
  local -n _task_stage=$3
  local -n _max_stage=$4
  local -n _task_dep_checks=$5
  _task_stage=()
  _task_dep_checks=()

  # Build invocation lookup structures from TASK_RUN_PAIRS
  declare -A invocation_pair_set
  declare -A invocation_task_set
  local pair td rn
  for pair in "${_task_run_pairs_ref[@]}"; do
    td="${pair%%	*}"
    rn="${pair#*	}"
    invocation_pair_set["$td	$rn"]=1
    invocation_task_set["$td"]=1
  done

  # Build dependency map: task -> list of dep tasks (for DAG, deduplicated)
  # Validate that each dependency is resolved (in invocation or .success on disk)
  declare -A deps
  declare -A dep_edges_added
  declare -A missing_deps
  local missing_count=0
  local task_dir dep_entry
  for task_dir in "${_tasks[@]}"; do
    deps["$task_dir"]=""
    local dep_entries=()
    get_task_depends "$task_dir" dep_entries
    for dep_entry in "${dep_entries[@]}"; do
      local parsed
      set -f
      parsed=($(parse_task_spec "$dep_entry"))
      set +f
      local dep_task_path="${parsed[0]}"
      local dep_run_spec="${parsed[1]:-}"
      local resolved=() r
      while IFS= read -r r; do
        [[ -n "$r" ]] && resolved+=("$r")
      done < <(resolve_arg "$dep_task_path" "$REPOSITORY_ROOT")

      for r in "${resolved[@]}"; do
        # Add task-level DAG edge (deduplicated, only for dep tasks in the invocation)
        local edge_key="$task_dir	$r"
        if [[ -z "${dep_edges_added["$edge_key"]+x}" ]] && [[ -n "${invocation_task_set["$r"]+x}" ]]; then
          deps["$task_dir"]+=" $r"
          dep_edges_added["$edge_key"]=1
        fi

        if [[ -z "$dep_run_spec" ]]; then
          # No run_spec: all runs (disk and invocation) must succeed; at least one run required
          local -a disk_runs=()
          shopt -s nullglob
          local rf
          for rf in "$r"/*/; do
            [[ -d "$rf" ]] && disk_runs+=("$(basename "$rf")")
          done
          shopt -u nullglob

          local all_disk_ok=true
          local rn
          for rn in "${disk_runs[@]}"; do
            if [[ ! -f "$r/$rn/.success" ]]; then
              all_disk_ok=false
              break
            fi
          done

          local has_at_least_one=false
          [[ -n "${invocation_task_set["$r"]+x}" ]] && has_at_least_one=true
          [[ ${#disk_runs[@]} -gt 0 ]] && has_at_least_one=true

          local resolved_ok=false
          [[ "$all_disk_ok" == true ]] && [[ "$has_at_least_one" == true ]] && resolved_ok=true

          if [[ "$resolved_ok" != true ]]; then
            local rel_task="${task_dir#$TASKS_DIR/}"
            local rel_dep="${r#$TASKS_DIR/}"
            missing_deps["tasks/$rel_dep"]="${missing_deps["tasks/$rel_dep"]:+${missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
            missing_count=$((missing_count + 1))
          fi
          _task_dep_checks["$task_dir"]+="ALL	$r"$'\n'

        elif [[ "$dep_run_spec" == *"*"* || "$dep_run_spec" == *"?"* ]]; then
          # Wildcard: expand against existing folders on disk
          local -a matched_runs=()
          expand_run_spec_for_clean "$r" "$dep_run_spec" matched_runs
          if [[ ${#matched_runs[@]} -eq 0 ]]; then
            local rel_task="${task_dir#$TASKS_DIR/}"
            local rel_dep="${r#$TASKS_DIR/}"
            local dep_label="tasks/$rel_dep:$dep_run_spec (no matching run folders on disk)"
            missing_deps["$dep_label"]="${missing_deps["$dep_label"]:+${missing_deps["$dep_label"]}, }tasks/$rel_task"
            missing_count=$((missing_count + 1))
          else
            for rn in "${matched_runs[@]}"; do
              if [[ -z "${invocation_pair_set["$r	$rn"]+x}" ]] && [[ ! -f "$r/$rn/.success" ]]; then
                local rel_task="${task_dir#$TASKS_DIR/}"
                local rel_dep="${r#$TASKS_DIR/}"
                missing_deps["tasks/$rel_dep:$rn"]="${missing_deps["tasks/$rel_dep:$rn"]:+${missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
                missing_count=$((missing_count + 1))
              fi
              _task_dep_checks["$task_dir"]+="RUN	$r	$rn"$'\n'
            done
          fi

        else
          # Literal/range: expand and validate each run
          local -a dep_runs=()
          expand_run_spec "$dep_run_spec" dep_runs
          for rn in "${dep_runs[@]}"; do
            if [[ -z "${invocation_pair_set["$r	$rn"]+x}" ]] && [[ ! -f "$r/$rn/.success" ]]; then
              local rel_task="${task_dir#$TASKS_DIR/}"
              local rel_dep="${r#$TASKS_DIR/}"
              missing_deps["tasks/$rel_dep:$rn"]="${missing_deps["tasks/$rel_dep:$rn"]:+${missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
              missing_count=$((missing_count + 1))
            fi
            _task_dep_checks["$task_dir"]+="RUN	$r	$rn"$'\n'
          done
        fi
      done
    done
  done

  if [[ $missing_count -gt 0 ]]; then
    echo "Error: The following dependencies are neither in the current invocation nor satisfied on disk:" >&2
    for dep in "${!missing_deps[@]}"; do
      echo "  - $dep" >&2
      echo "    required by:" >&2
      local req
      for req in $(echo "${missing_deps[$dep]}" | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
        [[ -n "$req" ]] && echo "      - $req" >&2
      done
    done
    echo "" >&2
    echo "Include these dependency runs in your invocation or run them first." >&2
    exit 1
  fi

  # Topological sort with cycle detection (Kahn's algorithm)
  declare -A in_degree
  for task_dir in "${_tasks[@]}"; do
    in_degree["$task_dir"]=0
  done
  for task_dir in "${_tasks[@]}"; do
    for dep in ${deps["$task_dir"]}; do
      [[ -n "$dep" ]] && in_degree["$task_dir"]=$((${in_degree["$task_dir"]} + 1))
    done
  done

  local stage=0
  local remaining=("${_tasks[@]}")
  while [[ ${#remaining[@]} -gt 0 ]]; do
    local ready=()
    for task_dir in "${remaining[@]}"; do
      if [[ ${in_degree["$task_dir"]} -eq 0 ]]; then
        ready+=("$task_dir")
      fi
    done
    if [[ ${#ready[@]} -eq 0 ]]; then
      echo "Error: Circular dependency detected among tasks." >&2
      exit 1
    fi
    for task_dir in "${ready[@]}"; do
      _task_stage["$task_dir"]=$stage
    done
    for task_dir in "${remaining[@]}"; do
      for dep in ${deps["$task_dir"]}; do
        for ready_task in "${ready[@]}"; do
          if [[ "$dep" == "$ready_task" ]]; then
            in_degree["$task_dir"]=$((${in_degree["$task_dir"]} - 1))
            break
          fi
        done
      done
    done
    local new_remaining=()
    for task_dir in "${remaining[@]}"; do
      local is_ready=false
      for r in "${ready[@]}"; do
        [[ "$task_dir" == "$r" ]] && { is_ready=true; break; }
      done
      [[ "$is_ready" != true ]] && new_remaining+=("$task_dir")
    done
    remaining=("${new_remaining[@]}")
    stage=$((stage + 1))
  done
  _max_stage=$((stage - 1))
}

# Verify that all dependency runs for tasks in a given stage have .success files.
# Aborts the pipeline if any dependency is unsatisfied.
check_stage_deps() {
  local stage=$1
  local -n _csd_tasks=$2
  local -n _csd_task_stage=$3
  local -n _csd_dep_checks=$4
  local -n _csd_task_run_pairs=$5

  local -a unsatisfied=()
  local task_dir
  for task_dir in "${_csd_tasks[@]}"; do
    [[ "${_csd_task_stage[$task_dir]:--1}" != "$stage" ]] && continue
    local checks="${_csd_dep_checks[$task_dir]:-}"
    [[ -z "$checks" ]] && continue
    while IFS= read -r check; do
      [[ -z "$check" ]] && continue
      local check_type rest dep_dir dep_run
      check_type="${check%%	*}"
      rest="${check#*	}"
      if [[ "$check_type" == "ALL" ]]; then
        dep_dir="$rest"
        local -a disk_runs=()
        shopt -s nullglob
        local rf
        for rf in "$dep_dir"/*/; do
          [[ -d "$rf" ]] && disk_runs+=("$(basename "$rf")")
        done
        shopt -u nullglob

        local -A union_runs=()
        local rn
        for rn in "${disk_runs[@]}"; do
          union_runs["$rn"]=1
        done
        local pair td rn_val
        for pair in "${_csd_task_run_pairs[@]}"; do
          td="${pair%%	*}"
          rn_val="${pair#*	}"
          [[ "$td" == "$dep_dir" ]] && union_runs["$rn_val"]=1
        done

        if [[ ${#union_runs[@]} -eq 0 ]]; then
          local rel_dep="${dep_dir#$TASKS_DIR/}"
          local rel_task="${task_dir#$TASKS_DIR/}"
          unsatisfied+=("tasks/$rel_dep (at least one run required) required by tasks/$rel_task")
        else
          for rn in "${!union_runs[@]}"; do
            if [[ ! -f "$dep_dir/$rn/.success" ]]; then
              local rel_dep="${dep_dir#$TASKS_DIR/}"
              local rel_task="${task_dir#$TASKS_DIR/}"
              unsatisfied+=("tasks/$rel_dep/$rn required by tasks/$rel_task")
            fi
          done
        fi
      elif [[ "$check_type" == "RUN" ]]; then
        dep_dir="${rest%%	*}"
        dep_run="${rest#*	}"
        if [[ ! -f "$dep_dir/$dep_run/.success" ]]; then
          local rel_dep="${dep_dir#$TASKS_DIR/}"
          local rel_task="${task_dir#$TASKS_DIR/}"
          unsatisfied+=("tasks/$rel_dep/$dep_run required by tasks/$rel_task")
        fi
      fi
    done <<< "$checks"
  done

  if [[ ${#unsatisfied[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Error: Unsatisfied dependencies before stage $stage:" >&2
    for u in "${unsatisfied[@]}"; do
      echo "  - $u" >&2
    done
    exit 1
  fi
}

# --- Manifest (for workload manager job arrays) ---
# Creates a single manifest file with multiple jobs, each with tasks and dependencies.
# Format: header (SKIP_VERIFY_DEF, env overrides, ---), then JOB blocks with DEPENDS and INDEX<TAB>RUN<TAB>PATH.
RUN_TASKS_OUTPUT_ROOT="$REPOSITORY_ROOT/workload_logs"
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

# --- Main ---
main() {
  parse_args "$@"

  # Array execution mode: workload manager invokes us for a single array element
  if [[ -n "$ARRAY_MANIFEST" && -n "$ARRAY_JOB_ID" && -n "$ARRAY_TASK_ID" ]]; then
    run_array_task "$ARRAY_MANIFEST" "$ARRAY_JOB_ID" "$ARRAY_TASK_ID"
    exit $?
  fi

  # Check if any tasks were specified
  if [[ ${#TASK_SPECS[@]} -eq 0 ]]; then
    echo "Error: No tasks specified." >&2
    usage >&2
    exit 1
  fi

  build_task_run_pairs

  if [[ "$CLEAN" == true ]]; then
    # Clean mode: remove output folders only, with progress output
    local total=${#TASKS_UNIQUE[@]}
    local total_ops=${#TASK_RUN_PAIRS[@]}
    echo "Cleaning $total_ops run(s) across $total task(s)$([[ "$DRY_RUN" == true ]] && echo " (dry run)" || true)..."
    local op_counter=0
    local pair
    for pair in "${TASK_RUN_PAIRS[@]}"; do
      op_counter=$((op_counter + 1))
      local task_dir="${pair%%	*}"
      local run_name="${pair#*	}"
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
    echo "Cleaned $total_ops run(s) for $total task(s)$([[ "$DRY_RUN" == true ]] && echo " (dry run)" || true)."
    exit 0
  else
    local total=${#TASKS_UNIQUE[@]}

    # Workload manager path: create manifest, invoke workload manager (single arg)
    if [[ -n "$WORKLOAD_MANAGER_SCRIPT" ]]; then
      local wm_script manifest_path
      wm_script="$WORKLOAD_MANAGER_SCRIPT"
      [[ "$wm_script" != /* ]] && wm_script="$REPOSITORY_ROOT/$wm_script"
      if [[ ! -f "$wm_script" ]]; then
        echo "Error: Workload manager script not found: $WORKLOAD_MANAGER_SCRIPT" >&2
        exit 1
      fi
      manifest_path=$(create_manifest TASK_RUN_PAIRS TASKS_UNIQUE)
      if [[ "$DRY_RUN" == true ]]; then
        cat "$manifest_path"
        exit 0
      fi
      if [[ "$SKIP_SUCCEEDED" == true ]] && ! grep -q '^JOB	' "$manifest_path"; then
        echo "All tasks already succeeded, nothing to submit."
        exit 0
      fi
      log_dir="$(dirname "$manifest_path")"
      export REPOSITORY_ROOT
      [[ -n "$JOB_NAME" ]] && export JOB_NAME
      [[ -n "$WALLTIME" ]] && export WALLTIME
      bash "$wm_script" "$manifest_path" "$log_dir"
      exit $?
    fi

    # Direct execution: create manifest (for audit), run stages sequentially, then (task, run) pairs within each stage
    declare -A task_stage
    declare -A task_dep_checks
    local max_stage=0
    compute_stages TASKS_UNIQUE TASK_RUN_PAIRS task_stage max_stage task_dep_checks

    local manifest_path
    manifest_path=$(create_manifest TASK_RUN_PAIRS TASKS_UNIQUE)
    if [[ "$DRY_RUN" == true ]]; then
      cat "$manifest_path"
      exit 0
    fi

    local total_ops=${#TASK_RUN_PAIRS[@]}
    local current=0
    local succeeded=0
    local failed=0
    local skipped=0

    echo "Running $total_ops run(s) across $total task(s) in $((max_stage + 1)) stage(s)..."
    for stage in $(seq 0 "$max_stage"); do
      echo ""
      echo "--- Stage $stage ---"
      check_stage_deps "$stage" TASKS_UNIQUE task_stage task_dep_checks TASK_RUN_PAIRS
      local pair
      for pair in "${TASK_RUN_PAIRS[@]}"; do
        local task_dir="${pair%%	*}"
        local run_name="${pair#*	}"
        [[ "${task_stage[$task_dir]:--1}" != "$stage" ]] && continue
        current=$((current + 1))
        local rel_path="${task_dir#$TASKS_DIR/}"
        printf "[%d/%d] %s/%s ... " "$current" "$total_ops" "$rel_path" "$run_name"
        if [[ "$SKIP_SUCCEEDED" == true ]] && is_task_succeeded "$task_dir" "$run_name"; then
          echo -e "\033[0;33mSKIPPED\033[0m"
          skipped=$((skipped + 1))
        elif run_task "$task_dir" "$run_name"; then
          echo -e "\033[0;32mSUCCESS\033[0m"
          succeeded=$((succeeded + 1))
        else
          echo -e "\033[0;31mFAILED\033[0m"
          failed=$((failed + 1))
        fi
      done
    done
    echo
    local summary="Finished with $succeeded successes and $failed failures."
    [[ $skipped -gt 0 ]] && summary="$summary $skipped already succeeded (skipped)."
    echo "$summary"
    exit $((failed > 0 ? 1 : 0))
  fi
}

main "$@"
