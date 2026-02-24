#!/usr/bin/env bash
# Run spec expansion and task status.

# Check if a task run has already succeeded (has .run_success file).
is_task_succeeded() {
  local task_dir="$1"
  local run_name="$2"
  [[ -f "$task_dir/$run_name/.run_success" ]]
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
      is_run_folder "$run_folder" || continue
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
