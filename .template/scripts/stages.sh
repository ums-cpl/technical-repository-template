#!/usr/bin/env bash
# Stage computation and dependency verification.

# Validate a single dependency (dependent occ_key depends on dep_task_dir with dep_run_spec).
# Updates _missing_deps, _missing_count_ref, and _dep_checks. Used by compute_stages.
# _dep_checks is keyed by occ_key (the dependent).
validate_dependency() {
  local occ_key="$1"
  local dep_task_dir="$2"
  local dep_run_spec="$3"
  local -n _inv_pair_set=$4
  local -n _inv_task_set=$5
  local -n _pairs_ref=$6
  local -n _missing_deps=$7
  local -n _missing_count_ref=$8
  local -n _dep_checks=$9
  local task_dir="${occ_key%	OCC:*}"

  if [[ -z "$dep_run_spec" ]]; then
    local -a disk_runs=()
    shopt -s nullglob
    local rf
    for rf in "$dep_task_dir"/*/; do
      [[ -d "$rf" ]] && disk_runs+=("$(basename "$rf")")
    done
    shopt -u nullglob

    local all_disk_ok=true
    local rn
    for rn in "${disk_runs[@]}"; do
      if [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; then
        all_disk_ok=false
        break
      fi
    done

    local has_at_least_one=false
    [[ -n "${_inv_task_set["$dep_task_dir"]+x}" ]] && has_at_least_one=true
    [[ ${#disk_runs[@]} -gt 0 ]] && has_at_least_one=true

    local resolved_ok=false
    [[ "$all_disk_ok" == true ]] && [[ "$has_at_least_one" == true ]] && resolved_ok=true

    if [[ "$INCLUDE_DEPS" == true ]]; then
      if [[ -z "${_inv_task_set["$dep_task_dir"]+x}" ]]; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        _missing_deps["tasks/$rel_dep"]="${_missing_deps["tasks/$rel_dep"]:+${_missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
        _missing_count_ref=$((_missing_count_ref + 1))
      fi
    else
      if [[ "$resolved_ok" != true ]]; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        _missing_deps["tasks/$rel_dep"]="${_missing_deps["tasks/$rel_dep"]:+${_missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
        _missing_count_ref=$((_missing_count_ref + 1))
      fi
    fi
    _dep_checks["$occ_key"]+="ALL	$dep_task_dir"$'\n'

  elif [[ "$dep_run_spec" == *"*"* || "$dep_run_spec" == *"?"* ]]; then
    local -a matched_runs=()
    expand_run_spec_for_clean "$dep_task_dir" "$dep_run_spec" matched_runs
    declare -A _matched_set=()
    local _mr
    for _mr in "${matched_runs[@]}"; do _matched_set["$_mr"]=1; done
    local _inv_pair _inv_td _inv_rn
    for _inv_pair in "${_pairs_ref[@]}"; do
      _inv_td="${_inv_pair%%	*}"
      _inv_rn="${_inv_pair#*	}"
      if [[ "$_inv_td" == "$dep_task_dir" ]] && [[ "$_inv_rn" == $dep_run_spec ]] \
         && [[ -z "${_matched_set["$_inv_rn"]+x}" ]]; then
        matched_runs+=("$_inv_rn")
        _matched_set["$_inv_rn"]=1
      fi
    done
    if [[ ${#matched_runs[@]} -eq 0 ]]; then
      local rel_task="${task_dir#$TASKS/}"
      local rel_dep="${dep_task_dir#$TASKS/}"
      local dep_label="tasks/$rel_dep:$dep_run_spec (no matching run folders on disk)"
      _missing_deps["$dep_label"]="${_missing_deps["$dep_label"]:+${_missing_deps["$dep_label"]}, }tasks/$rel_task"
      _missing_count_ref=$((_missing_count_ref + 1))
    else
      for rn in "${matched_runs[@]}"; do
        if [[ -z "${_inv_pair_set["$dep_task_dir	$rn"]+x}" ]] && { [[ "$INCLUDE_DEPS" == true ]] || [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; }; then
          local rel_task="${task_dir#$TASKS/}"
          local rel_dep="${dep_task_dir#$TASKS/}"
          _missing_deps["tasks/$rel_dep:$rn"]="${_missing_deps["tasks/$rel_dep:$rn"]:+${_missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
          _missing_count_ref=$((_missing_count_ref + 1))
        fi
        _dep_checks["$occ_key"]+="RUN	$dep_task_dir	$rn"$'\n'
      done
    fi

  else
    local -a dep_runs=()
    expand_run_spec "$dep_run_spec" dep_runs
    for rn in "${dep_runs[@]}"; do
      if [[ -z "${_inv_pair_set["$dep_task_dir	$rn"]+x}" ]] && { [[ "$INCLUDE_DEPS" == true ]] || [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; }; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        _missing_deps["tasks/$rel_dep:$rn"]="${_missing_deps["tasks/$rel_dep:$rn"]:+${_missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
        _missing_count_ref=$((_missing_count_ref + 1))
      fi
      _dep_checks["$occ_key"]+="RUN	$dep_task_dir	$rn"$'\n'
    done
  fi
}

# Compute stages from task dependencies. Populates _task_stage[occ_key]=stage_id.
# _tasks is TASK_OCC_KEYS (occurrence keys). Dependency on a task resolves to its last occurrence.
# Implicit sequential deps: same (task_dir, run_name) in consecutive pairs -> later stage.
compute_stages() {
  local -n _tasks=$1
  local -n _task_run_pairs_ref=$2
  local -n _task_stage=$3
  local -n _max_stage=$4
  local -n _task_dep_checks=$5
  _task_stage=()
  _task_dep_checks=()

  # Build invocation lookup: pair set, task set, and task_dir -> last occ_key (for dep resolution)
  declare -A invocation_pair_set
  declare -A invocation_task_set
  declare -A task_dir_to_last_occ
  local i pair td rn occ_key
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    rn="${pair#*	}"
    invocation_pair_set["$td	$rn"]=1
    invocation_task_set["$td"]=1
    task_dir_to_last_occ["$td"]="$occ_key"
  done

  declare -A deps
  declare -A dep_edges_added
  declare -A missing_deps
  local missing_count=0
  local dep_entry

  # Initialize deps for all occurrence keys (newline-separated to preserve occ_key with tab)
  for occ_key in "${_tasks[@]}"; do
    deps["$occ_key"]=""
  done

  # Implicit sequential deps: same (task_dir, run_name) in consecutive pairs
  declare -A prev_occ_by_pair
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    rn="${pair#*	}"
    local pair_key="$td	$rn"
    if [[ -n "${prev_occ_by_pair[$pair_key]+x}" ]]; then
      local prev_occ="${prev_occ_by_pair[$pair_key]}"
      local edge_key="$prev_occ	$occ_key"
      if [[ -z "${dep_edges_added["$edge_key"]+x}" ]]; then
        deps["$occ_key"]+="${deps["$occ_key"]:+$'\n'}$prev_occ"
        dep_edges_added["$edge_key"]=1
      fi
    fi
    prev_occ_by_pair["$pair_key"]="$occ_key"
  done

  # Collect explicit deps per pair; dependency on task X -> edge to last occurrence of X
  # Use this pair's overrides when resolving deps so BUILD_FOLDER etc. are correct
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    local run_name="${pair#*	}"
    ENV_OVERRIDES=()
    local ov_tsv="${TASK_RUN_PAIR_OVERRIDES[$i]:-}"
    if [[ -n "$ov_tsv" ]]; then
      IFS=$'\t' read -ra ENV_OVERRIDES <<< "$ov_tsv"
    fi
    local dep_entries=()
    get_task_dependencies "$td" "$run_name" dep_entries
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
        validate_dependency "$occ_key" "$r" "$dep_run_spec" \
          invocation_pair_set invocation_task_set _task_run_pairs_ref \
          missing_deps missing_count _task_dep_checks
        [[ -z "${invocation_task_set["$r"]+x}" ]] && continue
        local dep_occ="${task_dir_to_last_occ["$r"]}"
        local edge_key="$occ_key	$dep_occ"
        if [[ -z "${dep_edges_added["$edge_key"]+x}" ]] && [[ "$occ_key" != "$dep_occ" ]]; then
          deps["$occ_key"]+="${deps["$occ_key"]:+$'\n'}$dep_occ"
          dep_edges_added["$edge_key"]=1
        fi
      done
    done
  done

  if [[ $missing_count -gt 0 ]]; then
    if [[ "$INCLUDE_DEPS" == true ]]; then
      RUN_TASKS_MISSING_SPECS=()
      for dep in "${!missing_deps[@]}"; do
        local spec
        if [[ "$dep" == *" (no matching run folders on disk)" ]]; then
          spec="${dep%%:*}"
        else
          spec="${dep% (no matching run folders on disk)}"
        fi
        RUN_TASKS_MISSING_SPECS+=("$spec")
      done
      return 1
    fi
    echo "Error: The following dependencies are neither in the current invocation nor satisfied on disk:" >&2
    for dep in "${!missing_deps[@]}"; do
      echo "  - $dep" >&2
      echo "    required by:" >&2
      local req
      for req in $(echo "${missing_deps[$dep]}" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u); do
        [[ -n "$req" ]] && echo "      - $req" >&2
      done
    done
    echo "" >&2
    echo "Include these dependency runs in your invocation or run them first." >&2
    exit 1
  fi

  # Topological sort (Kahn's algorithm) on occurrence keys (deps are newline-separated)
  declare -A in_degree
  for occ_key in "${_tasks[@]}"; do
    in_degree["$occ_key"]=0
  done
  for occ_key in "${_tasks[@]}"; do
    local dep
    while IFS= read -r dep; do
      [[ -n "$dep" ]] && in_degree["$occ_key"]=$((${in_degree["$occ_key"]} + 1))
    done <<< "${deps["$occ_key"]}"
  done

  local stage=0
  local remaining=("${_tasks[@]}")
  while [[ ${#remaining[@]} -gt 0 ]]; do
    local ready=()
    for occ_key in "${remaining[@]}"; do
      if [[ ${in_degree["$occ_key"]} -eq 0 ]]; then
        ready+=("$occ_key")
      fi
    done
    if [[ ${#ready[@]} -eq 0 ]]; then
      echo "Error: Circular dependency detected among tasks." >&2
      exit 1
    fi
    for occ_key in "${ready[@]}"; do
      _task_stage["$occ_key"]=$stage
    done
    for occ_key in "${remaining[@]}"; do
      local dep
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        for ready_occ in "${ready[@]}"; do
          if [[ "$dep" == "$ready_occ" ]]; then
            in_degree["$occ_key"]=$((${in_degree["$occ_key"]} - 1))
            break
          fi
        done
      done <<< "${deps["$occ_key"]}"
    done
    local new_remaining=()
    for occ_key in "${remaining[@]}"; do
      local is_ready=false
      for r in "${ready[@]}"; do
        [[ "$occ_key" == "$r" ]] && { is_ready=true; break; }
      done
      [[ "$is_ready" != true ]] && new_remaining+=("$occ_key")
    done
    remaining=("${new_remaining[@]}")
    stage=$((stage + 1))
  done
  _max_stage=$((stage - 1))
}

# Verify that all dependency runs for tasks in a given stage have .run_success files.
# _csd_tasks is TASK_OCC_KEYS; _csd_task_stage and _csd_dep_checks are keyed by occ_key.
check_stage_deps() {
  local stage=$1
  local -n _csd_tasks=$2
  local -n _csd_task_stage=$3
  local -n _csd_dep_checks=$4
  local -n _csd_task_run_pairs=$5

  local -a unsatisfied=()
  local occ_key
  for occ_key in "${_csd_tasks[@]}"; do
    [[ "${_csd_task_stage[$occ_key]:--1}" != "$stage" ]] && continue
    local checks="${_csd_dep_checks[$occ_key]:-}"
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
          local task_dir="${occ_key%	OCC:*}"
          local rel_task="${task_dir#$TASKS/}"
          unsatisfied+=("tasks/$rel_dep (at least one run required) required by tasks/$rel_task")
        else
          for rn in "${!union_runs[@]}"; do
            if [[ ! -f "$dep_dir/$rn/.run_success" ]]; then
              local rel_dep="${dep_dir#$TASKS/}"
              local task_dir="${occ_key%	OCC:*}"
              local rel_task="${task_dir#$TASKS/}"
              unsatisfied+=("tasks/$rel_dep/$rn required by tasks/$rel_task")
            fi
          done
        fi
      elif [[ "$check_type" == "RUN" ]]; then
        dep_dir="${rest%%	*}"
        dep_run="${rest#*	}"
        if [[ ! -f "$dep_dir/$dep_run/.run_success" ]]; then
          local rel_dep="${dep_dir#$TASKS/}"
          local task_dir="${occ_key%	OCC:*}"
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
