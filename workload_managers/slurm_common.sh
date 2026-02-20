#!/usr/bin/env bash
# Shared logic for SLURM workload managers: parse manifest fully, then submit jobs.
# Source this from workload manager scripts after setting SBATCH_* variables.

# Parse manifest and submit jobs. Uses: MANIFEST, RUNNER, OUTPUT_DIR (log directory), JOB_NAME, WALLTIME,
# and SBATCH_PARTITION, SBATCH_GRES (optional), SBATCH_CPUS_PER_TASK, SBATCH_MEM, SBATCH_TIME.
# Writes stdout and stderr to the same .log file per array task (output is typically empty).
parse_and_submit() {
  local manifest="$1"
  [[ ! -f "$manifest" ]] && { echo "Error: Manifest not found: $manifest" >&2; exit 1; }

  # --- Parse phase: fully parse manifest before any sbatch ---
  declare -a job_ids=()
  declare -A job_depends=()
  declare -A job_task_count=()
  local current_job=""
  local in_header=true

  while IFS= read -r line; do
    if [[ "$in_header" == true ]]; then
      [[ "$line" == "---" ]] && in_header=false
      continue
    fi
    if [[ "$line" == JOB* ]]; then
      current_job=$(echo "$line" | cut -f2)
      job_ids+=("$current_job")
      continue
    fi
    if [[ "$line" == DEPENDS* ]]; then
      job_depends["$current_job"]=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
      job_task_count["$current_job"]=$((${job_task_count["$current_job"]:-0} + 1))
    fi
  done < "$manifest"

  # Validate: at least one job
  if [[ ${#job_ids[@]} -eq 0 ]]; then
    echo "Error: Manifest has no jobs." >&2
    exit 1
  fi

  # Validate: each job has tasks and DEPENDS references valid job IDs
  local jid dep
  for jid in "${job_ids[@]}"; do
    if [[ ${job_task_count["$jid"]:-0} -eq 0 ]]; then
      echo "Error: Job $jid has no tasks." >&2
      exit 1
    fi
    for dep in $(echo "${job_depends["$jid"]}" | tr ',' ' '); do
      dep=$(echo "$dep" | tr -d ' ')
      [[ -z "$dep" ]] && continue
      local valid=false
      for j in "${job_ids[@]}"; do
        if [[ "$j" == "$dep" ]]; then
          valid=true
          break
        fi
      done
      if [[ "$valid" != true ]]; then
        echo "Error: Job $jid DEPENDS references invalid job $dep." >&2
        exit 1
      fi
      if [[ "$dep" -ge "$jid" ]]; then
        echo "Error: Job $jid DEPENDS on $dep (must be earlier job)." >&2
        exit 1
      fi
    done
  done

  # --- Submit phase: only after parsing succeeds ---
  declare -A slurm_job_id=()
  local dep_list dep_jid

  for jid in "${job_ids[@]}"; do
    local array_max=$((${job_task_count["$jid"]} - 1))
    local dep_slurm=""
    for dep in $(echo "${job_depends["$jid"]}" | tr ',' ' '); do
      dep=$(echo "$dep" | tr -d ' ')
      [[ -z "$dep" ]] && continue
      dep_jid="${slurm_job_id[$dep]:-}"
      if [[ -n "$dep_jid" ]]; then
        [[ -n "$dep_slurm" ]] && dep_slurm+=","
        dep_slurm+="$dep_jid"
      fi
    done

    local dep_line=""
    [[ -n "$dep_slurm" ]] && dep_line="#SBATCH --dependency=afterok:$dep_slurm"

    local gres_line=""
    [[ -n "${SBATCH_GRES:-}" ]] && gres_line="#SBATCH --gres=${SBATCH_GRES}"

    local tmp=$(mktemp)
    {
      echo "#!/bin/bash"
      echo "#SBATCH --array=0-${array_max}"
      echo "#SBATCH --partition=${SBATCH_PARTITION}"
      [[ -n "$gres_line" ]] && echo "$gres_line"
      echo "#SBATCH --cpus-per-task=${SBATCH_CPUS_PER_TASK}"
      echo "#SBATCH --mem=${SBATCH_MEM}"
      echo "#SBATCH --time=${SBATCH_TIME:-${WALLTIME:-2:00:00}}"
      echo "#SBATCH --job-name=${JOB_NAME:-run_tasks}_${jid}"
      echo "#SBATCH --output=${OUTPUT_DIR}/job${jid}_%a.log"
      [[ -n "$dep_line" ]] && echo "$dep_line"
      echo ""
      echo "module add Apptainer"
      echo "exec \"$RUNNER\" --array-manifest=\"$manifest\" --array-job-id=\"$jid\" --array-task-id=\${SLURM_ARRAY_TASK_ID}"
    } > "$tmp"
    slurm_job_id["$jid"]=$(sbatch --parsable "$tmp")
    rm -f "$tmp"
    echo "Submitted job $jid (SLURM ${slurm_job_id[$jid]}) with ${job_task_count["$jid"]} task(s)"
  done
}
