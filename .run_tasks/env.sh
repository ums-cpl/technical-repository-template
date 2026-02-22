#!/usr/bin/env bash
# Environment file collection and dependency resolution.

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
