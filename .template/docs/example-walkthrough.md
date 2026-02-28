# Example Walkthrough

## Overview

This example demonstrates an end-to-end workflow: build, experiment, and plot. The output plot is written to `tasks/plot/assets`. Requires an [Apptainer](https://apptainer.org/) installation.

**What the template provides.** The template provides `run_tasks.sh` and requires work to be divided into `assets/` and `tasks/` that run inside `containers/`. The framework handles task resolution, dependencies, and execution.

**What is specific to this example.** How assets and tasks are structured is completely chosen by the example. It shows one best practice: a hierarchical task tree with shared configuration, containerized builds and runs, and executables that accept paths as arguments. With good reason, other structures may be more sensible for different use cases.

## Directory Layout

The example populates the four top-level directories: `assets/`, `containers/`, `tasks/`, and `workload_managers/`. The following tree shows the layout and key files used in this walkthrough. See the following sections for details.

```
.
|-- run_tasks.sh                 # Main entry point for running tasks
|
|-- assets/                      # Implementation: data generation, experiments, plotting
|   |-- data/
|   |   |-- data_helper.h        # Shared helper providing data utility functions
|   |   |-- matmul.cpp           # Gold implementation generating inputs and expected outputs
|   |  
|   |-- experiments/
|   |   |-- baseline
|   |   |   |-- matmul.cpp       # Experiment measuring runtimes of a baseline matmul
|   |   |
|   |   |-- optimized
|   |       |-- matmul.cpp       # Experiment measuring runtimes of an optimized matmul
|   |  
|   |-- plots/
|       |-- runtimes.py          # Plotting script comparing baseline and optimized runtimes
|
|-- containers/
|   |-- gcc.def                  # Build container (compile C++)
|   |-- plot.def                 # Plot container (run Python)
|
|-- tasks/
|   |-- build/                   # Build tasks: build containers + binaries
|   |   |-- containers/
|   |   |   |-- gcc/             # Build gcc.def into gcc.sif
|   |   |   |-- plot/            # Build plot.def into plot.sif
|   |   |-- data/                # Compile data binary
|   |   |-- baseline/            # Compile baseline binary
|   |   |-- optimized/           # Compile optimized binary
|   |   |-- debug/               # Compile baseline with debug symbols (DISABLED)
|   |
|   |-- experiment/MatMul/      # Experiment tasks: run matmul variants for two input sizes
|   |   |-- IS1/
|   |   |   |-- data/            # Generate data for this input size
|   |   |   |-- baseline/        # Run baseline (repeated runs)
|   |   |   |-- optimized/
|   |   |-- IS2/
|   |   |   |-- data/
|   |   |   |-- baseline/
|   |   |   |-- optimized/
|   |
|   |-- plot/                    # Plot task: aggregate results
|
|-- workload_managers/           # workload manager scripts
    |-- palmaII-skylake.sh       # e.g. palmaII-skylake.sh for cluster runs
    |-- ...
```

## Assets

Assets are organized by purpose: data generation, experiment variants, and plotting. They stay independent of the task framework: each asset accepts file paths as arguments and writes outputs to the current working directory. Common code is shared across asset variants via a helper header.

## Containers

The example uses two container definitions: one for compilation and one for plotting. Container `.def` files are built into `.sif` images by dedicated build tasks. Other tasks then reference these built containers through `CONTAINER` and verify them against `CONTAINER_DEF`. The template also supports `CONTAINER_GPU` for GPU tasks, though this CPU-only example does not use it.

## Task Hierarchy

### Build Tasks (`tasks/build/`)

Container build tasks (`tasks/build/containers/gcc/` and `tasks/build/containers/plot/`) run `apptainer build` and need no `task_meta.sh`. Compilation tasks (`tasks/build/data/`, `tasks/build/baseline/`, `tasks/build/optimized/`) each compile a different asset source file. Each compilation task sets `CONTAINER` and `CONTAINER_DEF` in its own `task_meta.sh` and declares a dependency on the container build task via `run_deps.sh`.

Build tasks use `RUN_SPEC=$BUILD_FOLDER`, which gives them a single named run folder. The `BUILD_FOLDER` variable enables running tasks independently on multiple devices. You can override it via `run_tasks.sh` KEY=VALUE pairs (e.g. `BUILD_FOLDER=gpu2080`). This creates separate run folders per device (e.g. `gpu2080/`, `gpu4090/`) so results stay isolated. The plot task aggregates across all `*-run*` folders, so plots can include all devices.

### Debug build (DISABLED)

The `tasks/build/debug/` task compiles the baseline matmul binary with debug symbols (`-O0 -g`) for troubleshooting. It is disabled by default because it is not part of the main artifact pipeline. To run it when needed, use:

```bash
./run_tasks.sh --run-disabled tasks/build/debug
```

### Experiment Tasks (`tasks/experiment/`)

The experiment tasks form a three-level hierarchy: routine, input size, and variant. Each level contributes configuration: the root `tasks/experiment/task_meta.sh` sets `RUN_SPEC` for repeated runs; the routine level (`MatMul/task_meta.sh`) sets a routine identifier used in paths; the input-size level (`IS1/`, `IS2/`) sets input parameters; and the variant level (`baseline/`, `optimized/`) sets competitor name and container.

Data generation tasks (`*/data/`) live within input-size groups. They override `RUN_SPEC` to a single run, since data only needs to be generated once. They depend on the container and the compiled data binary.

### Experiment Variant Tasks

The `baseline/` and `optimized/` variants share the same `run.sh` -- a one-liner that calls a shared helper. Variant identity is set purely through `task_meta.sh` (`COMPETITOR=baseline` vs `COMPETITOR=optimized`). Each variant depends on the container, the compiled variant binary, and the generated data.

### Plot Task (`tasks/plot/`)

The plot task is a single leaf task with its own container. It has a wildcard dependency on all experiment results. It passes `$TASKS/experiment` to the plot asset, which discovers results by walking the directory structure. The asset is explicitly not aware of the task structure; it simply expects results in a nested directory layout that happens to share the same structure with task run outputs.

## Hierarchical Configuration

The framework sources `task_meta.sh` files from root to leaf, and each level can add variables. `BUILD_FOLDER` is set once at the root (`tasks/task_meta.sh`) and propagated everywhere. Intermediate variables such as `ROUTINE`, `INPUT_SIZE`, and `COMPETITOR` compose the paths used in `run_env.sh` and `run_deps.sh`.

## Shared Run Logic via `run_env.sh`

The file `tasks/experiment/MatMul/run_env.sh` defines helper functions `create_data()` and `run_experiment()`. These functions use variables from the `task_meta.sh` chain: `ROUTINE`, `INPUT_SIZE`, `COMPETITOR`, and `BUILD_FOLDER`. The variable `$RUN_ID` is also available in `run.sh` (it holds the run folder name, e.g. `assets-run3`). As a result, leaf `run.sh` files reduce to a single function call.

## Dependencies

`run_deps.sh` files are hierarchical: they are sourced root-to-leaf and append to `DEPENDENCIES` via `+=`. Build tasks depend on their container build. Data tasks depend on the container and the compiled data binary. Experiment tasks depend on the container, the compiled variant binary, and the generated data for their input size. The plot task depends on the plot container and all experiment runs, using the glob-style spec `:*-run*` to match any run of any device. Dependency paths use variables (`$COMPETITOR`, `$ROUTINE`, `$INPUT_SIZE`, `$BUILD_FOLDER`) so they stay generic across the hierarchy.

## RUN_SPEC Patterns

Build tasks use `$BUILD_FOLDER` for a single run, so the folder is named after the `BUILD_FOLDER` variable. Experiment tasks default to `$BUILD_FOLDER-run:1:10`, giving ten repeated runs with the `$BUILD_FOLDER` prefix keeping each device's runs independent. Data tasks override this to `$BUILD_FOLDER` for a single run per device. The plot task uses `assets` -- a fixed name for a single combined run that can include all devices.

## Running the Example

Run the workflow in order: build, create data, run experiments, then plot. Because dependencies are declared in `run_deps.sh` and `RUN_SPEC` patterns in `task_meta.sh`, you can also submit the full workflow in a single command. For parallel execution on a cluster, pass `--workload-manager` (e.g. `workload_managers/palmaII-skylake.sh`). To remove task output, use `--clean`.

**Step-by-step:**

```bash
# 1. Build data and experiment binaries
./run_tasks.sh tasks/build/

# 2. Create data used for experiments
./run_tasks.sh tasks/experiment/*/*/data

# 3. Run all experiment tasks (except data generation) 10 times
./run_tasks.sh "tasks/experiment/*/*/!(data):run:1:10"

# 4. Generate plots from experiment results
./run_tasks.sh tasks/plot/

# 5. Clean task data
./run_tasks.sh --clean tasks/
```

**Single command (dependencies resolved automatically):**

```bash
./run_tasks.sh
```

**With a workload manager (parallel submission):**

```bash
./run_tasks.sh --workload-manager=workload_managers/palmaII-skylake.sh
```
