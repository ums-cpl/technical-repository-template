#!/usr/bin/env bash
# Runner script for tasks. Executes tasks with proper environment setup,
# logging, and success tracking. See readme.md for design details.

set -euo pipefail

# Abort whole run on CTRL+C (SIGINT)
trap 'echo ""; echo "Interrupted. Aborting run." >&2; exit 130' INT

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS="$REPOSITORY_ROOT/tasks"
CONTAINERS="$REPOSITORY_ROOT/containers"
ASSETS="$REPOSITORY_ROOT/assets"
WORKLOAD_MANAGERS="$REPOSITORY_ROOT/workload_managers"
RUN_TASKS_LIB="$REPOSITORY_ROOT/.run_tasks"

source "$RUN_TASKS_LIB/config.sh"
source "$RUN_TASKS_LIB/args.sh"
source "$RUN_TASKS_LIB/run_spec.sh"
source "$RUN_TASKS_LIB/task_resolution.sh"
source "$RUN_TASKS_LIB/env.sh"
source "$RUN_TASKS_LIB/stages.sh"
source "$RUN_TASKS_LIB/execution.sh"
source "$RUN_TASKS_LIB/main.sh"

main "$@"
