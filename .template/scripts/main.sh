#!/usr/bin/env bash
# Main orchestration.

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
      compute_stages TASKS_UNIQUE TASK_RUN_PAIRS task_stage max_stage task_dep_checks || cs_status=$?
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
      create_manifest TASK_RUN_PAIRS TASKS_UNIQUE
      exit 0
    fi

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

    # Direct execution: create manifest (for audit), run stages sequentially
    local manifest_path
    manifest_path=$(create_manifest TASK_RUN_PAIRS TASKS_UNIQUE)

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
        local rel_path="${task_dir#$TASKS/}"
        printf "[%0${#total_ops}d/%0${#total_ops}d] %s/%s ... " "$current" "$total_ops" "$rel_path" "$run_name"
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
