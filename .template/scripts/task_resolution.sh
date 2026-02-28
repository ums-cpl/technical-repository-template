#!/usr/bin/env bash
# Task resolution and building task-run pairs.

# True if dir is a run folder (has framework marker files). Used to exclude run output from task resolution.
is_run_folder() {
  local dir="$1"
  [[ -f "$dir/.run_script.sh" || -f "$dir/.run_begin" || -f "$dir/.run_success" || -f "$dir/.run_failed" || -f "$dir/.run_metadata" ]]
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

# Reduce tab-separated KEY=VALUE list to final value per key (last occurrence wins).
# Output: tab-separated KEY=VALUE (order = last occurrence of each key).
reduce_override_to_final_per_key() {
  local tsv="$1"
  if [[ -z "$tsv" ]]; then
    return
  fi
  local -a parts=()
  IFS=$'\t' read -ra parts <<< "$tsv"
  declare -A ov=()
  local -a out_keys=()
  local p key
  for p in "${parts[@]}"; do
    [[ "$p" != *=* ]] && continue
    key="${p%%=*}"
    ov["$key"]="${p#*=}"
    # Keep order of last occurrence: remove key if present, then append
    local -a new_order=()
    local k
    for k in "${out_keys[@]}"; do
      [[ "$k" != "$key" ]] && new_order+=("$k")
    done
    out_keys=("${new_order[@]}" "$key")
  done
  local i=0
  for key in "${out_keys[@]}"; do
    [[ -z "${ov[$key]+x}" ]] && continue
    [[ $i -gt 0 ]] && printf '\t'
    printf '%s=%s' "$key" "${ov[$key]}"
    ((i++)) || true
  done
}

# Build TASK_RUN_PAIRS, TASK_RUN_PAIR_OVERRIDES, TASK_RUN_PAIR_OCC_KEYS, TASK_OCC_KEYS, TASKS_UNIQUE from TASK_SPECS.
# Overrides are per-spec (TASK_SPEC_OVERRIDES). Same (task_dir, override_snapshot) = same occurrence group (OCC:N).
# Pairs are emitted in spec order; within each spec, run-first task-second order. Duplicate (task_dir, run_name) across specs allowed.
build_task_run_pairs() {
  TASK_RUN_PAIRS=()
  TASK_RUN_PAIR_OVERRIDES=()
  TASK_RUN_PAIR_OCC_KEYS=()
  TASK_OCC_KEYS=()
  TASKS_UNIQUE=()
  declare -A occ_key_by_task_override=()
  local occ_counter=0
  local -a pairs_with_override=()
  local spec_idx=0

  for spec in "${TASK_SPECS[@]}"; do
    [[ -z "$spec" ]] && ((spec_idx++)) || true
    [[ -z "$spec" ]] && continue
    local override_tsv="${TASK_SPEC_OVERRIDES[$spec_idx]:-}"
    ENV_OVERRIDES=()
    if [[ -n "$override_tsv" ]]; then
      IFS=$'\t' read -ra ENV_OVERRIDES <<< "$override_tsv"
    fi
    local parsed
    set -f
    parsed=($(parse_task_spec "$spec"))
    set +f
    local task_path="${parsed[0]}"
    local run_spec="${parsed[1]:-}"

    local -a tasks_ordered=()
    declare -A task_runs=()

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

      if [[ "$FORCE_DISABLED" != true ]]; then
        local task_disabled
        task_disabled=$(resolve_task_var "$task_dir" "TASK_DISABLED" | tr '[:upper:]' '[:lower:]')
        case "$task_disabled" in
          true|1|yes) continue ;;
        esac
      fi

      if [[ -z "${task_runs[$task_dir]+x}" ]]; then
        tasks_ordered+=("$task_dir")
      fi

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

      local existing="${task_runs[$task_dir]:-}"
      for r in "${runs[@]}"; do
        existing="${existing:+$existing }$r"
      done
      task_runs["$task_dir"]="$existing"
    done < <(resolve_arg "$task_path" "$REPOSITORY_ROOT")

    # Emit pairs for this spec in run-first, task-second order
    # Only add RUN_SPEC to overrides when explicitly from CLI: user-used suffix (spec_idx < ORIGINAL_TASK_SPEC_COUNT). Do not add for specs added by --include-deps or when RUN_SPEC comes from task_meta/default.
    local effective_ov_tsv="$override_tsv"
    if [[ -n "$run_spec" ]] && [[ "$spec_idx" -lt "${ORIGINAL_TASK_SPEC_COUNT:-0}" ]]; then
      effective_ov_tsv="${effective_ov_tsv:+${effective_ov_tsv}$'\t'}RUN_SPEC=$run_spec"
    fi
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
          pairs_with_override+=("$t	${truns[$run_idx]}	$effective_ov_tsv")
        fi
      done
    done

    ((spec_idx++)) || true
  done

  # Assign occurrence keys and build output arrays
  TASK_RUN_PAIR_WM=()
  TASK_RUN_PAIR_JOB_NAME=()
  local pair_override
  for pair_override in "${pairs_with_override[@]}"; do
    local task_dir="${pair_override%%	*}"
    local rest="${pair_override#*	}"
    local run_name="${rest%%	*}"
    local ov_tsv="${rest#*	}"
    if [[ "$ov_tsv" == "$run_name" ]]; then
      ov_tsv=""
    fi

    local occ_key
    if [[ -z "${occ_key_by_task_override["$task_dir	$ov_tsv"]+x}" ]]; then
      occ_key="$task_dir	OCC:$occ_counter"
      occ_key_by_task_override["$task_dir	$ov_tsv"]="$occ_key"
      TASK_OCC_KEYS+=("$occ_key")
      ((occ_counter++)) || true
    else
      occ_key="${occ_key_by_task_override["$task_dir	$ov_tsv"]}"
    fi

    local pair_ov_tsv
    pair_ov_tsv=$(reduce_override_to_final_per_key "$ov_tsv")
    TASK_RUN_PAIRS+=("$task_dir	$run_name")
    TASK_RUN_PAIR_OVERRIDES+=("$pair_ov_tsv")
    TASK_RUN_PAIR_OCC_KEYS+=("$occ_key")

    # Resolve WORKLOAD_MANAGER and JOB_NAME per pair (with this pair's overrides)
    ENV_OVERRIDES=()
    [[ -n "$pair_ov_tsv" ]] && IFS=$'\t' read -ra ENV_OVERRIDES <<< "$pair_ov_tsv"
    local wm job_name
    wm=$(resolve_task_var "$task_dir" "WORKLOAD_MANAGER")
    [[ -z "$wm" ]] && wm="workload_managers/direct.sh"
    job_name=$(resolve_task_var "$task_dir" "JOB_NAME")
    # Default to run_tasks only when JOB_NAME is unset (neither in overrides nor task_meta.sh)
    if [[ -z "$job_name" ]]; then
      local is_set
      is_set=$(resolve_task_var_isset "$task_dir" "JOB_NAME")
      if [[ "$is_set" == "1" ]]; then
        job_name=""   # explicitly set to empty
      else
        job_name="run_tasks"
      fi
    fi
    TASK_RUN_PAIR_WM+=("$wm")
    TASK_RUN_PAIR_JOB_NAME+=("$job_name")
  done

  # TASKS_UNIQUE: unique task dirs for display (first occurrence order)
  declare -A seen_task=()
  for pair_override in "${pairs_with_override[@]}"; do
    local task_dir="${pair_override%%	*}"
    if [[ -z "${seen_task[$task_dir]+x}" ]]; then
      seen_task["$task_dir"]=1
      TASKS_UNIQUE+=("$task_dir")
    fi
  done
}
