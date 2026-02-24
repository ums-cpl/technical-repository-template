#!/usr/bin/env bash
# Task resolution and building task-run pairs.

# True if dir is a run folder (has framework marker files). Used to exclude run output from task resolution.
is_run_folder() {
  local dir="$1"
  [[ -f "$dir/.run_script.sh" || -f "$dir/.run_begin" || -f "$dir/.run_success" || -f "$dir/.run_failed" ]]
}

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

  # Handle wildcards: expand glob and filter to dirs with run.sh
    # (* and ? = standard glob; !( = extglob exclusion)
    # Note: arg comes from user-controlled run_deps.sh; glob chars (*?!) are safe.
    if [[ "$arg" == *"*"* || "$arg" == *"?"* || "$arg" == *"!("* ]]; then
    # Reject shell metacharacters that could enable injection in eval. Allow () for extglob !(pattern).
    case "$arg" in
      *';'*|*'|'*|*'&'*|*'`'*|*'$'*)
        echo "Error: Path contains invalid characters: $arg" >&2
        exit 1
        ;;
    esac
    shopt -s extglob  # enable !(pattern) for exclusion
    local expanded path abs
    expanded=($(eval "ls -d $arg" 2>/dev/null || true))
    for path in "${expanded[@]}"; do
      [[ -d "$path" && -f "$path/run.sh" ]] || continue
      is_run_folder "$path" && continue
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
    if [[ -f "$abs_path/run.sh" ]] && ! is_run_folder "$abs_path"; then
      resolved+=("$abs_path")
    else
      # Parent directory: find all descendant dirs with run.sh, excluding run folders
      local dir
      while IFS= read -r -d '' path; do
        dir="$(cd "$(dirname "$path")" && pwd)"
        is_run_folder "$dir" || resolved+=("$dir")
      done < <(find "$abs_path" -name "run.sh" -type f -print0 2>/dev/null)
      if [[ ${#resolved[@]} -eq 0 ]]; then
        echo "Error: No tasks found under $arg (no run.sh in descendents)" >&2
        exit 1
      fi
    fi
  fi

  printf '%s\n' "${resolved[@]}"
  )
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
      if [[ "$task_dir" != "$TASKS"* ]]; then
        echo "Error: Task must be under tasks/: $task_dir" >&2
        exit 1
      fi
      if [[ ! -f "$task_dir/run.sh" ]]; then
        echo "Error: Not a task directory (no run.sh): $task_dir" >&2
        exit 1
      fi
      if is_run_folder "$task_dir"; then
        echo "Error: Not a task directory (is a run folder): $task_dir" >&2
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
            is_run_folder "$run_folder" || continue
            runs+=("$(basename "$run_folder")")
          done
          shopt -u nullglob
          local -a sorted=()
          while IFS= read -r r; do
            [[ -n "$r" ]] && sorted+=("$r")
          done < <(printf '%s\n' "${runs[@]}" | sort)
          runs=("${sorted[@]}")
        else
          local resolved_run_spec
          resolved_run_spec=$(resolve_task_var "$task_dir" "RUN_SPEC")
          if [[ -z "$resolved_run_spec" ]]; then
            resolved_run_spec="assets"
          fi
          expand_run_spec "$resolved_run_spec" runs
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
