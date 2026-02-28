#!/usr/bin/env bash
# Configuration variables. REPOSITORY_ROOT, TASKS, CONTAINERS, ASSETS, WORKLOAD_MANAGERS
# are set by the root script before sourcing.

declare -a TASK_SPECS=()
declare -a TASK_SPEC_OVERRIDES=()
declare -a TASK_RUN_PAIRS=()
declare -a TASK_RUN_PAIR_OVERRIDES=()
declare -a TASK_RUN_PAIR_OCC_KEYS=()
declare -a TASK_OCC_KEYS=()
declare -a TASKS_UNIQUE=()
DRY_RUN=false
CLEAN=false
SKIP_SUCCEEDED=false
SKIP_VERIFY_DEF=false
FORCE_DISABLED=false
INCLUDE_DEPS=false
declare -a RUN_TASKS_MISSING_SPECS=()
WORKLOAD_MANAGER_SCRIPT=""
JOB_NAME=""
WALLTIME=""
ARRAY_MANIFEST=""
ARRAY_JOB_ID=""
ARRAY_TASK_ID=""
declare -a ENV_OVERRIDES=()

RUN_TASKS_OUTPUT_ROOT="$REPOSITORY_ROOT/workload_logs"
