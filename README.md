# technical-repository-template

A template for technical work organized as tasks. Provides a common repository structure to facilitate collaboration. Use this as a starting point for benchmarks, evaluations, and reproducible experiment workflows.

> **Note:** This is a living template and is intended to be improved over time. Any feedback, suggestions, or criticism are very welcome -- please send comments to [Richard](mailto:r.schulze@uni-muenster.de).

## Getting Started on the Palma II Cluster

A [getting started guide](palmaII-getting-started.md) is available for users not familiar with the Palma II cluster or SLURM. It explains how to use the cluster without this template. That background is required for making efficient use of the template.

## Design

The template centers on `run_tasks.sh`, which executes tasks defined under `tasks/`. Tasks invoke code in `assets/`, optionally inside `containers/`, and can be submitted in parallel via `workload_managers/`.

### run_tasks.sh

Used to run tasks.

**Usage:**

```
./run_tasks.sh [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]
```

**KEY=VALUE** pairs are environment overrides applied after sourcing env files and can be read inside the task script.

**TASK** can be:

- A task directory (path to a dir containing `task.sh`)
- A parent directory (recursively finds all descendant dirs with `task.sh`)
- A wildcard (e.g. `tasks/.../*`; use `"!(pattern)"` to exclude)

Optional suffix `:RUN_SPEC` sets run(s). Examples: `:local`, `:run:1:10`, `:run*` (clean only, wildcard). Without suffix: default run `assets` for execute; cleans all runs with `--clean`.

**Options:**

| Option | Description |
|--------|-------------|
| `--dry-run` | Print tasks only, do not run |
| `--clean` | Remove output folders for specified tasks |
| `--workload-manager=SCRIPT` | Submit tasks as job array via workload manager script |
| `--job-name=NAME` | Job name for workload manager |
| `--walltime=TIME` | Walltime for workload manager (format: `days-hours:minutes:seconds`, e.g. `1-01:00:00` for 1 day, 1 hour, 0 minutes, 0 seconds) |
| `--skip-succeeded` | Skip task runs that have already succeeded (`.success` exists). |
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

Tasks are defined as a tree under `tasks/`. Each task is a directory containing `task.sh`.

- **Tree structure:** Directories under `tasks/` form a hierarchy; any dir with `task.sh` is a task.
- **env files:** `env.sh`, `env_host.sh`, and `env_container.sh` may appear along the path from `tasks/` to a task. They are sourced in root-to-leaf order before `task.sh` runs. `env_host.sh` is used on the host; `env_container.sh` inside the container. Optionally set `CONTAINER` to a `.sif` file in `containers/` to run the task inside that container.
- **Paths:** Use `$REPOSITORY_ROOT` and `$RUN_FOLDER` for paths. Reference assets and containers relative to `$REPOSITORY_ROOT`. Task output goes to `$RUN_FOLDER`.
- **Dependencies:** Optionally set `TASK_DEPENDS` (array of task path patterns) in `env.sh` to declare dependencies. The runner orders the tasks of the current invocation by dependency. If a task depends on another task that is not part of the invocation, the runner does not run the missing tasks; it fails with an error listing the missing dependencies.

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
- **Tasks:** Keep `task.sh` short and simple; do task-related processing in asset files. Use `env.sh` to define helper functions shared by similar tasks.
- **Containers:** Avoid unnecessary bloat to keep image sizes small.
- **Documentation:** Describe the available tasks and how they are expected to run. For each task (or task group), document its purpose, prerequisites, inputs, outputs, and exact call to `run_tasks.sh` (e.g., via a README).

## Example

The example implements a MatMul benchmark: `tasks/build/` compiles data and experiment binaries; `tasks/experiment/MatMul/` runs experiments for different input sizes and variants (baseline, optimized); `tasks/plot/MatMul/` generates plots from the results. It illustrates env inheritance, container use for build and plot, and how assets receive task paths as arguments.

### Running the Example Tasks

```bash
# 1. Build data and experiment binaries (compiles with the appropriate container)
./run_tasks.sh tasks/build

# 2. Create data used for experiments
./run_tasks.sh tasks/experiment/MatMul/*/data

# 3. Run all experiment tasks (except data generation) 5 times
./run_tasks.sh "tasks/experiment/MatMul/*/!(data):run:1:5"

# 4. Generate plots from experiment results in tasks/plot/MatMul/assets
./run_tasks.sh tasks/plot

# 5. Clean task data
./run_tasks.sh --clean tasks
```

With dependencies declared in `env.sh` (via `TASK_DEPENDS`), the workflow can be submitted as a single command:

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
