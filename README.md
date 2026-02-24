# technical-repository-template

A template for technical work organized as tasks. Provides a common repository structure to facilitate collaboration. Use this as a starting point for benchmarks, evaluations, and reproducible experiment workflows.

> **Note:** This is a living template and is intended to be improved over time. Any feedback, suggestions, or criticism are very welcome -- please send comments to [Richard](mailto:r.schulze@uni-muenster.de).

## Getting Started on the Palma II Cluster

A [getting started guide](palmaII-getting-started.md) is available for users not familiar with the Palma II cluster or SLURM. It explains how to use the cluster without this template. That background is required for making efficient use of the template.

## Design

The template centers on `run_tasks.sh`, which executes tasks defined under `tasks/`. Tasks invoke code from `assets/`, optionally inside `containers/`, and can be submitted in parallel via `workload_managers/`.

### run_tasks.sh

Used to run tasks.

**Usage:**

```
./run_tasks.sh [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]
```

**KEY=VALUE** pairs are environment overrides applied after sourcing `task_meta.sh` and `run_env.sh` files and can be read inside the run script.

**TASK** can be:

- A task directory (path to a dir containing `run.sh`)
- A parent directory (recursively finds all descendant dirs with `run.sh`)
- A wildcard (e.g. `tasks/.../*`; use `"!(pattern)"` to exclude)

Optional suffix `:RUN_SPEC` overrides the task's `RUN_SPEC` (set in `task_meta.sh`). Examples: `:local`, `:run:1:10`, `:run*` (clean only, wildcard). Without suffix: uses the task's `RUN_SPEC`; cleans all runs with `--clean`.

**Options:**

| Option | Description |
|--------|-------------|
| `--dry-run` | Create manifest without running; print manifest contents to stdout |
| `--clean` | Remove output folders for specified tasks |
| `--workload-manager=SCRIPT` | Submit tasks as job array via workload manager script |
| `--job-name=NAME` | Job name for workload manager |
| `--walltime=TIME` | Walltime for workload manager (format: `days-hours:minutes:seconds`, e.g. `1-01:00:00` for 1 day, 1 hour, 0 minutes, 0 seconds) |
| `--skip-succeeded` | Skip task runs that have already succeeded (`.run_success` exists). |
| `--skip-verify-def` | Skip verification that container `.sif` matches `containers/*.def` |

**Examples:**

```bash
./run_tasks.sh tasks/build
./run_tasks.sh --dry-run tasks/experiment/MatMul
./run_tasks.sh tasks/experiment/MatMul/IS1/baseline:run:1:5
./run_tasks.sh --workload-manager=workload_managers/slurm.sh --walltime=1:00:00 tasks/experiment
./run_tasks.sh --clean tasks/experiment:run1
```

### Tasks

Tasks are defined as a tree under `tasks/`. A task is a directory containing at least `run.sh`; all other files (`task_meta.sh`, `run_env.sh`, `run_deps.sh`) are optional. Directories under `tasks/` form a hierarchy; any directory with `run.sh` is a task.

A **task** is a static definition of work. A **task run** is a concrete execution of that work. One task can have multiple task runs (e.g., repeated experiments).

| | Task | Task Run |
|---|---|---|
| Purpose | Static definition of work | Concrete execution of that work |
| Identified by | Directory containing `run.sh` | A named run within a task (e.g., `assets`, `run1`) |
| Configuration | `task_meta.sh` (hierarchical, root-to-leaf) | `run_env.sh` (hierarchical, inherits task config, adds `$RUN_ID`) |
| Execution | -- | `run.sh` (leaf-only, invokes code from `assets/`) |
| Dependencies | -- | `run_deps.sh` (hierarchical, writes `DEPENDENCIES`) |

#### Task: `task_meta.sh`

`task_meta.sh` files may appear along the path from `tasks/` to a task directory and are sourced in root-to-leaf order. They define the static configuration for a task.

**Available variables** (provided by the framework):

| Variable | Description |
|----------|-------------|
| `$CONTAINERS` | Path to the `containers/` directory |
| `$ASSETS` | Path to the `assets/` directory |
| `$TASKS` | Path to the `tasks/` directory |
| `$WORKLOAD_MANAGERS` | Path to the `workload_managers/` directory |

**Writable variables** (read by the framework):

| Variable | Description |
|----------|-------------|
| `CONTAINER` | Container image (`.sif`) to use for task runs |
| `CONTAINER_DEF` | Definition file (`.def`) to validate the container against |
| `CONTAINER_GPU` | Set to `ON` if the container uses a GPU |
| `RUN_SPEC` | Default task runs to execute (overridden by the CLI `:RUN_SPEC` suffix) |
| `WORKLOAD_MANAGER` | Workload manager script to use for this task |

#### Task Run: `run_env.sh`, `run_deps.sh`, `run.sh`

**`run_env.sh`** -- Hierarchical (sourced root-to-leaf, like `task_meta.sh`). Defines variables and helper functions for the run. Has all data from the `task_meta.sh` chain available. Available variables:

| Variable | Description |
|----------|-------------|
| `$CONTAINERS` | Path to the `containers/` directory |
| `$ASSETS` | Path to the `assets/` directory |
| `$TASKS` | Path to the `tasks/` directory |
| `$WORKLOAD_MANAGERS` | Path to the `workload_managers/` directory |
| `$RUN_ID` | Identifier of the current task run |

**`run_deps.sh`** -- Hierarchical (sourced root-to-leaf). Defines dependencies by writing `DEPENDENCIES` (array of dependency specs). Has the same data and variables available as `run_env.sh`. Each entry is a task path with an optional `:RUN_SPEC` suffix:

- `tasks/task1` -- depends on all runs of task1: every run must have `.run_success`, and at least one run must exist
- `tasks/task1:local` -- depends on the `local` run of task1
- `tasks/task1:run:1:10` -- depends on runs `run1` through `run10` of task1
- `"tasks/task1:run*"` -- depends on all runs matching `run*` (quote to prevent shell glob expansion)

A dependency is resolved if it is in the current invocation or already has a `.run_success` file on disk. If neither holds, the runner fails with an error listing the unresolved dependencies. Between stages, the runner verifies that all dependency runs have `.run_success` files before proceeding.

**`run.sh`** -- Leaf-only (one per task, required). The entry point for execution; invokes code from `assets/`. Has all data from the `task_meta.sh` and `run_env.sh` chains available.

Run folders are identified by framework marker files (`.run_script.sh`, `.run_begin`, `.run_success`, `.run_failed`). These distinguish task output directories from task definition directories when resolving tasks.

### Assets

Assets hold the actual implementation of experiments. Structure is flexible; there is no predefined layout. Write outputs to the current working directory (which is `$RUN_FOLDER`) so the task framework manages data placement.

### Containers

Containers provide a fixed environment for running tasks and document how to build experiments. They are runtime-only: all task output is stored on the host. Use Apptainer `.def` files; build with `apptainer build <image>.sif containers/<name>.def`.

### Workload Managers

Workload manager scripts allow running tasks in parallel to reduce overall runtime. `run_tasks.sh` creates a manifest and invokes the script; the script submits one or multiple job arrays where each array element runs one task.

Several pre-defined workload manager scripts are provided in the `workload_managers/` directory. These scripts are categorized by CPU or GPU architecture and the expected runtime. The default script has no suffix; scripts with suffixes like `l`, `xl`, or `xxl` are intended for longer runtimes, while the `compact` script is suited for sequential or low-resource tasks such as compilation.

**Interface:** A workload manager script is invoked as:

```bash
./workload_managers/<script> "$MANIFEST_PATH" "$LOG_DIR"
```

**Arguments:** `$1` = manifest path, `$2` = directory for job log files

**Environment:** `REPOSITORY_ROOT` is exported. `JOB_NAME` and `WALLTIME` are exported if passed via `run_tasks.sh`.

**Contract:** The script must (1) fully parse and validate the manifest before submitting any jobs to avoid partially submitted workloads; (2) submit and ensure processing of jobs in dependency order; (3) each array element must run:

```bash
"$REPOSITORY_ROOT/run_tasks.sh" --array-manifest="$MANIFEST_PATH" --array-job-id=<JOB> --array-task-id=<INDEX>
```

where `<JOB>` is the job ID from the manifest and `<INDEX>` is the 0-based task index within that job.

**Manifest format:** Header (SKIP_VERIFY_DEF, env overrides, `---`), then job blocks: `JOB\t<N>`, `DEPENDS\t<id1>,<id2>`, and `INDEX\tRUN\tPATH` lines per task.

## Best Practices

- **Assets:** Write them as if tasks don't exist—executable by themselves, not reading the `tasks/` folder directly. Accept paths to files/folders (that may be in `tasks/`) as arguments instead.
- **Tasks:** Keep `run.sh` short and simple; do task-related processing in asset files. Use `task_meta.sh` for shared metadata across a subtree and `run_env.sh` for setting up the environment in which the task is run.
- **Containers:** Avoid unnecessary bloat to keep image sizes small.
- **Documentation:** Describe the available tasks and how they are expected to run. For each task (or task group), document its purpose, prerequisites, inputs, outputs, and exact call to `run_tasks.sh` (e.g., via a README).

## Example

The example implements a MatMul benchmark: `tasks/build/` compiles data and experiment binaries; `tasks/experiment/MatMul/` runs experiments for different input sizes and variants (baseline, optimized); `tasks/plot/` generates plots from the results. It illustrates hierarchical configuration via `task_meta.sh`, container use for build and plot, and how assets receive task paths as arguments.

### Running the Example Tasks

```bash
# 1. Build data and experiment binaries (compiles with the appropriate container)
./run_tasks.sh tasks/build

# 2. Create data used for experiments
./run_tasks.sh tasks/experiment/MatMul/*/data

# 3. Run all experiment tasks (except data generation) 5 times
./run_tasks.sh "tasks/experiment/MatMul/*/!(data):run:1:5"

# 4. Generate plots from experiment results
./run_tasks.sh tasks/plot

# 5. Clean task data
./run_tasks.sh --clean tasks
```

With dependencies declared in `run_deps.sh` (via `DEPENDENCIES`), the workflow can be submitted as a single command:

```bash
./run_tasks.sh tasks/build tasks/experiment/*/*/data "tasks/experiment/*/*/!(data):run:1:5" tasks/plot
```

## Artifact Packing

This template simplifies the process of creating an artifact (e.g., a reproducibility artifact for a submission) into the following steps:

1. Gather relevant assets, tasks, containers, workload managers, and `run_tasks.sh` into a new repository.
2. Create high-level scripts that run the necessary tasks via `run_tasks.sh` (typically: build, create data, run experiments, plot results).
3. Create an artifact readme.
4. Distribute:
   - **Mutable on GitHub:** Most up-to-date version (e.g., including bug fixes) with container definition files only.
   - **Immutable on Zenodo (or similar):** For paper reference, with both container definition files and built containers. Artifact readme links to GitHub for the latest version.
   - This separation records the exact environment used for experiments while keeping the GitHub repository small.
