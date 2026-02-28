#!/usr/bin/env bash
# Main orchestration.

main() {
  parse_args "$@"

  # Array execution mode: workload manager invokes us for a single array element
  if [[ -n "$ARRAY_MANIFEST" && -n "$ARRAY_JOB_ID" && -n "$ARRAY_TASK_ID" ]]; then
    run_array_task "$ARRAY_MANIFEST" "$ARRAY_JOB_ID" "$ARRAY_TASK_ID"
    exit $?
  fi

  # When no tasks specified, run all tasks under tasks/
  if [[ ${#TASK_SPECS[@]} -eq 0 ]]; then
    TASK_SPECS=("tasks")
    TASK_SPEC_OVERRIDES=("")
  fi
  ORIGINAL_TASK_SPEC_COUNT=${#TASK_SPECS[@]}

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
      local rel_path="${task_dir#$TASKS/}"
      local run_folder="$task_dir/$run_name"
      printf "[%0${#total_ops}d/%0${#total_ops}d] %s/%s ... " "$op_counter" "$total_ops" "$rel_path" "$run_name"
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
    # Resolve dependencies (and optionally include missing)
    declare -A task_stage
    declare -A task_dep_checks
    local max_stage=0
    while true; do
      local cs_status=0
      compute_stages TASK_OCC_KEYS TASK_RUN_PAIRS task_stage max_stage task_dep_checks || cs_status=$?
      if [[ $cs_status -eq 0 ]]; then break; fi
      if [[ "$INCLUDE_DEPS" != true ]] || [[ ${#RUN_TASKS_MISSING_SPECS[@]} -eq 0 ]]; then
        exit 1
      fi
      local added=0
      local spec existing
      for spec in "${RUN_TASKS_MISSING_SPECS[@]}"; do
        local found=false
        for existing in "${TASK_SPECS[@]}"; do
          [[ "$existing" == "$spec" ]] && { found=true; break; }
        done
        if [[ "$found" != true ]]; then
          TASK_SPECS+=("$spec")
          TASK_SPEC_OVERRIDES+=("")
          added=1
        fi
      done
      if [[ $added -eq 0 ]]; then
        echo "Error: The following dependencies could not be included (disabled or invalid):" >&2
        for spec in "${RUN_TASKS_MISSING_SPECS[@]}"; do
          echo "  - $spec" >&2
        done
        echo "" >&2
        echo "Use --run-disabled to run disabled dependency tasks." >&2
        exit 1
      fi
      build_task_run_pairs
    done

    # Store precomputed stages in globals for create_manifest (runs in subshell via command substitution)
    declare -A RUN_TASKS_PRECOMPUTED_TASK_STAGE
    for k in "${!task_stage[@]}"; do
      RUN_TASKS_PRECOMPUTED_TASK_STAGE["$k"]="${task_stage[$k]}"
    done
    RUN_TASKS_PRECOMPUTED_MAX_STAGE=$max_stage
    local total=${#TASKS_UNIQUE[@]}

    # Dry run: print manifest to stdout without writing to disk, then exit
    if [[ "$DRY_RUN" == true ]]; then
      create_manifest TASK_RUN_PAIRS TASK_OCC_KEYS
      exit 0
    fi

    # Create manifest and determine execution mode (all-direct vs cluster)
    manifest_path=$(create_manifest TASK_RUN_PAIRS TASK_OCC_KEYS)
    if [[ "$SKIP_SUCCEEDED" == true ]] && ! grep -q '^JOB	' "$manifest_path"; then
      echo "All tasks already succeeded, nothing to submit."
      exit 0
    fi
    log_dir="$(dirname "$manifest_path")"
    export REPOSITORY_ROOT

    # Parse manifest: max stage and whether all WMs are direct.sh
    max_stage_manifest=0
    all_direct=true
    while IFS= read -r line; do
      if [[ "$line" == STAGE* ]]; then
        s="${line#*	}"
        [[ "$s" =~ ^[0-9]+$ ]] && [[ $s -gt $max_stage_manifest ]] && max_stage_manifest=$s
      elif [[ "$line" == WORKLOAD_MANAGER* ]]; then
        wm_val="${line#*	}"
        is_direct_wm "$wm_val" || all_direct=false
      fi
    done < "$manifest_path"

    if [[ "$all_direct" == true ]]; then
      # All-direct mode: invoke direct.sh once per stage (no wm_job_ids)
      for stage in $(seq 0 "$max_stage_manifest"); do
        bash "$REPOSITORY_ROOT/workload_managers/direct.sh" "$manifest_path" "$log_dir" "$stage" || exit $?
      done
    else
      # Cluster mode: per-stage WM invocation, wm_job_ids in log_dir
      : > "$log_dir/wm_job_ids"
      for stage in $(seq 0 "$max_stage_manifest"); do
        # Unique WMs that have at least one JOB in this stage
        wms_for_stage=()
        current_stage=""
        while IFS= read -r line; do
          if [[ "$line" == STAGE* ]]; then
            current_stage="${line#*	}"
          elif [[ "$line" == WORKLOAD_MANAGER* ]] && [[ "$current_stage" == "$stage" ]]; then
            wms_for_stage+=("${line#*	}")
          fi
        done < "$manifest_path"
        # Deduplicate (preserve order)
        local seen_wm=() wm_path wm_script s found
        for wm_path in "${wms_for_stage[@]}"; do
          [[ -z "$wm_path" ]] && continue
          local found=0
          for s in "${seen_wm[@]}"; do [[ "$s" == "$wm_path" ]] && { found=1; break; }; done
          [[ $found -eq 1 ]] && continue
          seen_wm+=("$wm_path")
          wm_script="$wm_path"
          [[ "$wm_script" != /* ]] && wm_script="$REPOSITORY_ROOT/$wm_script"
          if [[ ! -f "$wm_script" ]]; then
            echo "Error: Workload manager script not found: $wm_path" >&2
            exit 1
          fi
          bash "$wm_script" "$manifest_path" "$log_dir" "$stage" || exit $?
        done
      done
    fi
    exit $?
  fi
}
