#!/usr/bin/env bash
# Shared logic for SLURM workload managers.
# Source this from workload manager scripts after setting SBATCH_* variables.
# Scripts are invoked as: ./script "$MANIFEST" "$LOG_DIR" "$STAGE"

# Parse manifest for our JOBs in the given stage, resolve DEPENDS from wm_job_ids, submit, append to wm_job_ids.
# Uses: RUNNER, OUTPUT_DIR (use LOG_DIR), SBATCH_* variables. JOB_NAME and SBATCH_TIME come from script.
parse_and_submit_stage() {
  local manifest="$1"
  local log_dir="$2"
  local stage="$3"
  [[ ! -f "$manifest" ]] && { echo "Error: Manifest not found: $manifest" >&2; exit 1; }

  # Identity of the script that sourced us (only run JOBs that list this WM)
  local our_wm_abs
  our_wm_abs="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/$(basename "${BASH_SOURCE[1]}")"

  local wm_job_ids_file="$log_dir/wm_job_ids"
  [[ ! -f "$wm_job_ids_file" ]] && wm_job_ids_file=""

  # Parse manifest: only JOB blocks where STAGE==stage and WORKLOAD_MANAGER matches us
  declare -a job_ids=()
  declare -A job_depends=()
  declare -A job_task_count=()
  declare -A job_job_name=()
  local current_job="" current_stage="" current_wm="" in_header=true
  declare -A job_id_seen=()

  while IFS= read -r line; do
    if [[ "$in_header" == true ]]; then
      [[ "$line" == "---" ]] && in_header=false
      continue
    fi
    if [[ "$line" == JOB* ]]; then
      current_job=$(echo "$line" | cut -f2)
      current_stage=""
      current_wm=""
      continue
    fi
    if [[ "$line" == STAGE* ]]; then
      current_stage=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" == JOB_NAME* ]]; then
      job_job_name["$current_job"]=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" == WORKLOAD_MANAGER* ]]; then
      current_wm=$(echo "$line" | cut -f2)
      [[ "$current_wm" != /* ]] && current_wm="${REPOSITORY_ROOT:?}/$current_wm"
      continue
    fi
    if [[ "$line" == DEPENDS* ]]; then
      job_depends["$current_job"]=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
      if [[ "$current_stage" == "$stage" ]] && [[ "$current_wm" == "$our_wm_abs" ]]; then
        job_task_count["$current_job"]=$((${job_task_count["$current_job"]:-0} + 1))
        if [[ -z "${job_id_seen[$current_job]:-}" ]]; then
          job_id_seen["$current_job"]=1
          job_ids+=("$current_job")
        fi
      fi
    fi
  done < "$manifest"

  # Load existing manifest_job_id -> slurm_job_id mapping
  declare -A wm_id_map=()
  if [[ -n "$wm_job_ids_file" ]] && [[ -f "$wm_job_ids_file" ]]; then
    while IFS= read -r mjid wmid; do
      [[ -n "$mjid" ]] && wm_id_map["$mjid"]="$wmid"
    done < "$wm_job_ids_file"
  fi

  # Submit our jobs and append to wm_job_ids
  local jid dep dep_slurm job_name_val
  for jid in "${job_ids[@]}"; do
    local array_max=$((${job_task_count["$jid"]:-0} - 1))
    dep_slurm=""
    for dep in $(echo "${job_depends["$jid"]}" | tr ',' ' '); do
      dep=$(echo "$dep" | tr -d ' ')
      [[ -z "$dep" ]] && continue
      local wmid="${wm_id_map[$dep]:-}"
      [[ -z "$wmid" ]] && continue
      # Only add numeric SLURM ids as afterok (skip non-numeric like "completed" if any)
      if [[ "$wmid" =~ ^[0-9]+$ ]]; then
        [[ -n "$dep_slurm" ]] && dep_slurm+=","
        dep_slurm+="$wmid"
      fi
    done

    local dep_line=""
    [[ -n "$dep_slurm" ]] && dep_line="#SBATCH --dependency=afterok:$dep_slurm"

    local gres_line=""
    [[ -n "${SBATCH_GRES:-}" ]] && gres_line="#SBATCH --gres=${SBATCH_GRES}"

    job_name_val="${job_job_name[$jid]:-run_tasks}"

    local tmp
    tmp=$(mktemp)
    {
      echo "#!/bin/bash"
      echo "#SBATCH --array=0-${array_max}"
      echo "#SBATCH --partition=${SBATCH_PARTITION}"
      [[ -n "$gres_line" ]] && echo "$gres_line"
      echo "#SBATCH --cpus-per-task=${SBATCH_CPUS_PER_TASK}"
      echo "#SBATCH --mem=${SBATCH_MEM}"
      echo "#SBATCH --time=${SBATCH_TIME:-2:00:00}"
      echo "#SBATCH --job-name=${job_name_val}_${jid}"
      echo "#SBATCH --output=${log_dir}/job${jid}_%a.log"
      [[ -n "$dep_line" ]] && echo "$dep_line"
      echo ""
      echo "module add Apptainer"
      echo "exec \"$RUNNER\" --array-manifest=\"$manifest\" --array-job-id=\"$jid\" --array-task-id=\${SLURM_ARRAY_TASK_ID}"
    } > "$tmp"
    local slurm_id
    slurm_id=$(sbatch --parsable "$tmp")
    rm -f "$tmp"
    echo "$jid	$slurm_id" >> "$log_dir/wm_job_ids"
    echo "Submitted job $jid (SLURM $slurm_id) with ${job_task_count["$jid"]} task(s)"
  done
}
