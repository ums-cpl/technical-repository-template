# Template Reference

This template centers on `run_tasks.sh`, which executes tasks defined under `tasks/`. Tasks invoke code from `assets/`, optionally inside `containers/`, and are executed by a workload manager (by default `workload_managers/direct.sh` runs tasks sequentially in the current process).

## run_tasks.sh

Used to run tasks.

**Usage:**

```
./run_tasks.sh [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]
```

**KEY=VALUE** pairs are environment overrides. They are **positional and accumulate**: each `KEY=VALUE` applies from that point onward to all subsequent task specs. For example, `FOO=1 task1 FOO=2 BAR=3 task2` gives `task1` the set `{FOO=1}` and `task2` the set `{FOO=2, BAR=3}` (later values win). Overrides are applied after each sourced file (`task_meta.sh`, `run_env.sh`, `run_deps.sh`) so every file in the chain sees them. If the same task and run are specified twice with different override context (e.g. `FOO=1 tasks/build/gcc FOO=2 tasks/build/gcc`), they run in consecutive stages and the second occurrence overwrites the first in the same run folder.

**TASK** can be:

- A task directory (path to a dir containing `run.sh`)
- A parent directory (recursively finds all descendant dirs with `run.sh`)
- A wildcard (e.g. `tasks/.../*`; use `"!(pattern)"` to exclude)

Optional suffix `:RUN_SPEC` overrides the task's `RUN_SPEC` (set in `task_meta.sh`). Examples: `:local`, `:run:1:10`, `:run*` (clean only, wildcard). Without suffix: uses the task's `RUN_SPEC`; cleans all runs with `--clean`.

**Options:**


| Option              | Description                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------- |
| `--dry-run`         | Create manifest without running; print manifest contents to stdout                                |
| `--clean`           | Remove output folders for specified tasks                                                         |
| `--skip-succeeded`  | Skip task runs that have already succeeded (`.run_success` exists).                                |
| `--skip-verify-def` | Skip verification that container `.sif` matches `containers/*.def`                                |
| `--run-disabled`    | Run tasks even if `TASK_DISABLED` is set in `task_meta.sh`                                        |
| `--include-deps`    | Include missing dependency task runs in the invocation instead of failing                          |


**Examples:**

```bash
./run_tasks.sh tasks/build
./run_tasks.sh --dry-run tasks/experiment/MatMul
./run_tasks.sh tasks/experiment/MatMul/IS1/baseline:run:1:5
./run_tasks.sh WORKLOAD_MANAGER=workload_managers/palmaII-skylake.sh tasks/experiment
./run_tasks.sh --clean tasks/experiment:run1
```

## Tasks

Tasks are defined as a tree under `tasks/`. A task is a directory containing at least `run.sh`; all other files (`task_meta.sh`, `run_env.sh`, `run_deps.sh`) are optional. Directories under `tasks/` form a hierarchy; any directory with `run.sh` is a task.

A **task** is a static definition of work. A **task run** is a concrete execution of that work. One task can have multiple task runs (e.g., repeated experiments).


|               | Task                                        | Task Run                                                          |
| ------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| Purpose       | Static definition of work                   | Concrete execution of that work                                   |
| Identified by | Directory containing `run.sh`               | A named run within a task (e.g., `assets`, `run1`)                |
| Configuration | `task_meta.sh` (hierarchical, root-to-leaf) | `run_env.sh` (hierarchical, inherits task config, adds `$RUN_ID`) |
| Execution     | --                                          | `run.sh` (leaf-only, invokes code from `assets/`)                 |
| Dependencies  | --                                          | `run_deps.sh` (hierarchical, writes `DEPENDENCIES`)               |


### Task: `task_meta.sh`

`task_meta.sh` files may appear along the path from `tasks/` to a task directory and are sourced in root-to-leaf order. They define the static configuration for a task.

**Available variables** (provided by the framework):


| Variable             | Description                                |
| -------------------- | ------------------------------------------ |
| `$CONTAINERS`        | Path to the `containers/` directory        |
| `$ASSETS`            | Path to the `assets/` directory            |
| `$TASKS`             | Path to the `tasks/` directory             |
| `$WORKLOAD_MANAGERS` | Path to the `workload_managers/` directory |


**Writable variables** (read by the framework):


| Variable           | Description                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------- |
| `CONTAINER`        | Container image (`.sif`) to use for task runs                                                     |
| `CONTAINER_DEF`    | Definition file (`.def`) to validate the container against                                        |
| `CONTAINER_GPU`    | Set to `ON` if the container uses a GPU                                                           |
| `RUN_SPEC`         | Default task runs to execute (e.g. `assets`, `run:1:10`)                                          |
| `WORKLOAD_MANAGER` | Workload manager script to use for this task (default: `workload_managers/direct.sh`)             |
| `JOB_NAME`         | Job name for the workload manager, e.g. SLURM job name (default: `run_tasks`)                     |
| `TASK_DISABLED`    | Set to `true` (or `1`, `yes`) to disable the task; skipped unless `--run-disabled` is used        |

**Priority** (same for all writable variables, highest to lowest): CLI override where applicable (e.g. `:RUN_SPEC` suffix) > `KEY=VALUE` env override on the command line > value from `task_meta.sh` chain (root-to-leaf) > built-in default.


### Task Run: `run_env.sh`, `run_deps.sh`, `run.sh`

**`run_env.sh`** -- Hierarchical (sourced root-to-leaf, like `task_meta.sh`). Defines variables and helper functions for the run. Has all data from the `task_meta.sh` chain available. Available variables:

| Variable             | Description                                |
| -------------------- | ------------------------------------------ |
| `$CONTAINERS`        | Path to the `containers/` directory        |
| `$ASSETS`            | Path to the `assets/` directory            |
| `$TASKS`             | Path to the `tasks/` directory             |
| `$WORKLOAD_MANAGERS` | Path to the `workload_managers/` directory |
| `$RUN_ID`            | Identifier of the current task run         |


**`run_deps.sh`** -- Hierarchical (sourced root-to-leaf). Defines dependencies by writing `DEPENDENCIES` (array of dependency specs). Has the same data and variables available as `run_env.sh`. Each entry is a task path with an optional `:RUN_SPEC` suffix:

- `tasks/task1` -- depends on all runs of task1: every run must have `.run_success`, and at least one run must exist
- `tasks/task1:local` -- depends on the `local` run of task1
- `tasks/task1:run:1:10` -- depends on runs `run1` through `run10` of task1
- `"tasks/task1:run*"` -- depends on all runs matching `run*` (quote to prevent shell glob expansion)

A dependency is resolved if it is in the current invocation or already has a `.run_success` file on disk. If neither holds, the runner fails with an error listing the unresolved dependencies. Between stages, the runner verifies that all dependency runs have `.run_success` files before proceeding.

**`run.sh`** -- Leaf-only (one per task, required). The entry point for execution; invokes code from `assets/`. Has all data from the `task_meta.sh` and `run_env.sh` chains available.

Run folders are identified by framework marker files (`.run_script.sh`, `.run_begin`, `.run_success`, `.run_failed`, `.run_metadata`). These distinguish task output directories from task definition directories when resolving tasks.

## Assets

Assets hold the actual implementation of experiments. Structure is flexible; there is no predefined layout. Write outputs to the current working directory (which is `$RUN_FOLDER`) so the task framework manages data placement.

## Containers

Containers provide a fixed environment for running tasks and document how to build experiments. They are runtime-only: all task output is stored on the host. Use Apptainer `.def` files; build with `apptainer build <image>.sif containers/<name>.def`.

## Workload Managers

Execution always goes through a workload manager. `run_tasks.sh` creates a single manifest and invokes workload manager scripts per stage. The default is `workload_managers/direct.sh`, which runs tasks sequentially in the current process (no cluster). For cluster execution, set `WORKLOAD_MANAGER` in `task_meta.sh` or via `KEY=VALUE` overrides (e.g. `WORKLOAD_MANAGER=workload_managers/palmaII-gpu4090.sh tasks/...`). Cluster scripts submit jobs to the scheduler (e.g. SLURM). You cannot mix `direct.sh` with other workload managers in the same invocation; the framework errors at manifest creation if both appear.

Several cluster workload manager scripts are provided in the `workload_managers/` directory, categorized by CPU or GPU architecture and expected runtime. Scripts with suffixes like `l`, `xl`, or `xxl` are for longer runtimes; the `compact` script is suited for sequential or low-resource tasks such as compilation. Walltime is hardcoded per script (e.g. `SBATCH_TIME` in each script).

**Interface:** A workload manager script is invoked once per stage:

```bash
./wm_script "$MANIFEST" "$LOG_DIR" "$STAGE"
```

- **$1** = manifest path  
- **$2** = log directory (also contains `wm_job_ids` in cluster mode)  
- **$3** = stage number to process (0, 1, …)

The script parses the manifest, filters to JOB blocks where `STAGE` matches `$3` and `WORKLOAD_MANAGER` matches itself, then for each matching JOB: resolves `DEPENDS` via `wm_job_ids`, submits or runs the job, and appends the mapping to `wm_job_ids`.

**wm_job_ids:** A file `wm_job_ids` in the same directory as the manifest maps manifest JOB ids to workload-manager-specific job ids (e.g. SLURM job ids). Format: one line per submitted job, tab-separated, append-only: `<manifest_job_id>\t<wm_job_id>`. Before submitting, the WM reads this file to resolve `DEPENDS` to concrete job ids (e.g. `#SBATCH --dependency=afterok:...`). After submitting, it appends a new line. `direct.sh` does not use `wm_job_ids`.

**Contract:** The script must (1) fully parse and validate the manifest before submitting any jobs; (2) submit/run only jobs in the given stage whose `WORKLOAD_MANAGER` matches the script; (3) each task run must execute:

```bash
"$REPOSITORY_ROOT/run_tasks.sh" --array-manifest="$MANIFEST_PATH" --array-job-id=<JOB> --array-task-id=<INDEX>
```

where `<JOB>` is the manifest JOB id and `<INDEX>` is the 0-based task index within that job.

**Manifest format:** Header: `SKIP_VERIFY_DEF` (true/false), then `---`. Then JOB blocks ordered by stage. Each block:

- `JOB\t<id>` — unique job id
- `STAGE\t<N>` — stage number
- `JOB_NAME\t<name>` — job name for the WM (e.g. `#SBATCH --job-name`)
- `WORKLOAD_MANAGER\t<script path>` — script that owns this job
- `DEPENDS\t<comma-separated manifest job ids or empty>`
- Task lines: `<idx>\t<run_name>\t<task_path>[\tKEY=VALUE...]`. PATH is relative to REPOSITORY_ROOT. Per-task overrides appear as extra tab-separated fields.

## Test runner

The test runner in `.template/tests/` checks that `run_tasks.sh --dry-run` produces the expected manifest for given task specs. Run it from the repository root.

**Usage:**

```bash
./.template/tests/run_tests.sh [TEST ...]
```

- **No arguments:** Run all case files under `.template/tests/cases/` recursively. Only files with the `.expected` suffix are considered case files.
- **With arguments:** Run only the cases specified by each TEST. TEST can be:
  - A **case file** (path to a `.expected` file): run that case.
  - A **directory:** run all `.expected` files under that directory recursively.
  - A **wildcard pattern:** e.g. `.template/tests/cases/build*` or `.template/tests/cases/**/*.expected`. Bash `globstar` is enabled for `**`.

TEST paths are relative to the current working directory (or absolute). For example, from the repository root you might pass `.template/tests/cases/build.expected` or `.template/tests/cases/`. The runner resolves TESTs to a deduplicated list of case files (`.expected` only), then runs each.

**Case file format:** Case files use the `.expected` suffix (e.g. `build.expected`). Comment lines (starting with `#` after optional leading whitespace) are ignored throughout. After skipping comments: the first line is the invocation args for `run_tasks.sh` (e.g. `tasks/build`), the second must be `EXPECT_SUCCESS:` or `EXPECT_FAILURE:`, and the rest is the expected output. For `EXPECT_SUCCESS:` the expected content is the manifest (same format as `--dry-run` stdout). For `EXPECT_FAILURE:` the run is expected to exit non-zero and the expected content is stderr (optional; if empty, only the non-zero exit is asserted). You can use comments to document the test's purpose, including at the top of the file. On diff failure, the actual output is saved to a file with the same base name and `.actual` suffix (e.g. `build.actual`).