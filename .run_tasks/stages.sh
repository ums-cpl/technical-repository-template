#!/usr/bin/env bash
# Stage computation and dependency verification.

# Compute stages from task dependencies. Populates _task_stage[path]=stage_id.
# Sets _max_stage to max stage id (stages are 0.._max_stage).
# Populates _task_dep_checks with per-task dependency checks for inter-stage verification.
# Each DEPENDENCIES entry may include a run suffix (e.g. :local, :run:1:10, :run*).
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
  # Dependencies are per-run: iterate over task-run pairs, aggregate at the task level.
  declare -A deps
  declare -A dep_edges_added
  declare -A missing_deps
  local missing_count=0
  local task_dir dep_entry

  # Initialize deps for all tasks
  for task_dir in "${_tasks[@]}"; do
    deps["$task_dir"]=""
  done

  # Collect deps per task-run pair
  for pair in "${_task_run_pairs_ref[@]}"; do
    task_dir="${pair%%	*}"
    local run_name="${pair#*	}"
    local dep_entries=()
    get_task_dependencies "$task_dir" "$run_name" dep_entries
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
            local rel_task="${task_dir#$TASKS/}"
            local rel_dep="${r#$TASKS/}"
            missing_deps["tasks/$rel_dep"]="${missing_deps["tasks/$rel_dep"]:+${missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
            missing_count=$((missing_count + 1))
          fi
          _task_dep_checks["$task_dir"]+="ALL	$r"$'\n'

        elif [[ "$dep_run_spec" == *"*"* || "$dep_run_spec" == *"?"* ]]; then
          # Wildcard: expand against existing folders on disk
          local -a matched_runs=()
          expand_run_spec_for_clean "$r" "$dep_run_spec" matched_runs
          if [[ ${#matched_runs[@]} -eq 0 ]]; then
            local rel_task="${task_dir#$TASKS/}"
            local rel_dep="${r#$TASKS/}"
            local dep_label="tasks/$rel_dep:$dep_run_spec (no matching run folders on disk)"
            missing_deps["$dep_label"]="${missing_deps["$dep_label"]:+${missing_deps["$dep_label"]}, }tasks/$rel_task"
            missing_count=$((missing_count + 1))
          else
            for rn in "${matched_runs[@]}"; do
              if [[ -z "${invocation_pair_set["$r	$rn"]+x}" ]] && [[ ! -f "$r/$rn/.success" ]]; then
                local rel_task="${task_dir#$TASKS/}"
                local rel_dep="${r#$TASKS/}"
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
              local rel_task="${task_dir#$TASKS/}"
              local rel_dep="${r#$TASKS/}"
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
          local rel_dep="${dep_dir#$TASKS/}"
          local rel_task="${task_dir#$TASKS/}"
          unsatisfied+=("tasks/$rel_dep (at least one run required) required by tasks/$rel_task")
        else
          for rn in "${!union_runs[@]}"; do
            if [[ ! -f "$dep_dir/$rn/.success" ]]; then
              local rel_dep="${dep_dir#$TASKS/}"
              local rel_task="${task_dir#$TASKS/}"
              unsatisfied+=("tasks/$rel_dep/$rn required by tasks/$rel_task")
            fi
          done
        fi
      elif [[ "$check_type" == "RUN" ]]; then
        dep_dir="${rest%%	*}"
        dep_run="${rest#*	}"
        if [[ ! -f "$dep_dir/$dep_run/.success" ]]; then
          local rel_dep="${dep_dir#$TASKS/}"
          local rel_task="${task_dir#$TASKS/}"
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
