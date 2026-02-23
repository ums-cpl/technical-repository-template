#!/usr/bin/env bash
# Configuration variables. REPOSITORY_ROOT, TASKS, CONTAINERS, ASSETS, WORKLOAD_MANAGERS
# are set by the root script before sourcing.

declare -a TASK_SPECS=()
declare -a TASK_RUN_PAIRS=()
declare -a TASKS_UNIQUE=()
DRY_RUN=false
CLEAN=false
SKIP_SUCCEEDED=false
SKIP_VERIFY_DEF=false
WORKLOAD_MANAGER_SCRIPT=""
JOB_NAME=""
WALLTIME=""
ARRAY_MANIFEST=""
ARRAY_JOB_ID=""
ARRAY_TASK_ID=""
declare -a ENV_OVERRIDES=()

RUN_TASKS_OUTPUT_ROOT="$REPOSITORY_ROOT/workload_logs"
