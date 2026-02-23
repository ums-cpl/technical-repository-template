#!/usr/bin/env bash
# Environment file collection and dependency resolution.

# Collect task_meta.sh files from tasks/ down to task dir, in root-to-leaf order.
get_task_meta_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS/}"
  local files=()
  local current="$TASKS"

  [[ -f "$current/task_meta.sh" ]] && files+=("$current/task_meta.sh")
  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/task_meta.sh" ]] && files+=("$current/task_meta.sh")
  done

  printf '%s\n' "${files[@]}"
}

# Collect run_env.sh files from tasks/ down to task dir, in root-to-leaf order.
get_run_env_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS/}"
  local files=()
  local current="$TASKS"

  [[ -f "$current/run_env.sh" ]] && files+=("$current/run_env.sh")
  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/run_env.sh" ]] && files+=("$current/run_env.sh")
  done

  printf '%s\n' "${files[@]}"
}

# Collect run_deps.sh files from tasks/ down to task dir, in root-to-leaf order.
get_run_deps_files() {
  local task_dir="$1"
  local rel_path="${task_dir#$TASKS/}"
  local files=()
  local current="$TASKS"

  [[ -f "$current/run_deps.sh" ]] && files+=("$current/run_deps.sh")
  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/run_deps.sh" ]] && files+=("$current/run_deps.sh")
  done

  printf '%s\n' "${files[@]}"
}

# Source the task_meta.sh chain in a subshell with framework vars and echo the
# requested variable. Used to resolve RUN_SPEC, CONTAINER, CONTAINER_DEF per task.
resolve_task_var() {
  local task_dir="$1"
  local var_name="$2"

  local meta_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")

  local source_cmds=""
  for f in "${meta_files[@]}"; do
    source_cmds+="source \"$f\"; "
  done

  bash -c "
    export CONTAINERS=\"$CONTAINERS\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    $source_cmds
    echo -n \"\${$var_name:-}\"
  " 2>/dev/null || true
}

# Get DEPENDENCIES for a task run by sourcing task_meta.sh chain, then run_deps.sh chain,
# with framework vars and RUN_ID. Returns array of dependency specs.
get_task_dependencies() {
  local task_dir="$1"
  local run_name="$2"
  local -n _out=$3
  _out=()

  local meta_files=() deps_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && deps_files+=("$f")
  done < <(get_run_deps_files "$task_dir")

  local source_cmds_meta=""
  for f in "${meta_files[@]}"; do
    source_cmds_meta+="source \"$f\"; "
  done

  local export_cmds=""
  for ov in "${ENV_OVERRIDES[@]}"; do
    export_cmds+="export $ov; "
  done

  local source_cmds_deps=""
  for f in "${deps_files[@]}"; do
    source_cmds_deps+="source \"$f\"; "
  done

  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && _out+=("$dep")
  done < <(bash -c "
    export CONTAINERS=\"$CONTAINERS\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    $source_cmds_meta
    export RUN_ID=\"$run_name\"
    $export_cmds
    DEPENDENCIES=()
    $source_cmds_deps
    for d in \"\${DEPENDENCIES[@]:-}\"; do
      [[ -n \"\$d\" ]] && echo \"\$d\"
    done
  " 2>/dev/null || true)
}
