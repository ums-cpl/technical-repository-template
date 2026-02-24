# Best Practices

This document describes recommended practices for repositories based on this template. Each practice consists of a **rule** and one or more **examples**. Deviating from these practices is generally not advisable -- they exist to support reproducibility, maintainability, and collaboration. If you must ignore a practice, clearly document the reason (e.g., in the task or step documentation) so future maintainers and reviewers understand why.

---

## Repositories

### Main steps are executable with one command

> The main steps (the sequence of tasks that reach the repository's primary goal) should be runnable with a single invocation of `run_tasks.sh`. All other tasks -- temporary experiments, abandoned directions, or optional variants -- should be disabled by default via `TASK_DISABLED=true` in `task_meta.sh`.

**Examples:**

- A benchmark repository's main goal is to produce plots. Running `./run_tasks.sh tasks/` executes build → data → experiment → plot in dependency order. Exploratory tasks (e.g., a broken alternative implementation) are disabled and can be run with `--run-disabled` when needed.
- A repository with multiple research directions keeps only the published pipeline enabled; exploratory branches are disabled to avoid accidental inclusion in artifact packing.

---

## Documentation

### Documentation is essential

> Documentation is an essential part of a technical repository. It enables reproducibility, onboarding, and artifact evaluation.

### Document each step of the work

> For each step of the workflow, document its purpose, the exact commands to run the relevant tasks, inputs and outputs, other requirements (e.g., hardware, software), and the expected runtime. Use a consistent structure so readers can quickly find what they need.

**Example template for documenting a step of the workflow (copy and fill in):**

```
## <Name>

**Purpose:** <One sentence describing what this step achieves.>

**Commands:**
./run_tasks.sh tasks/<path>

**Inputs:** <What this step expects to exist (e.g., outputs of previous steps).>

**Outputs:** <What is produced and where (e.g., tasks/<path>/<run_folder>/).>

**Requirements:** <e.g., Apptainer, 16 GB RAM, GPU.>

**Expected runtime:** <e.g., ~5 minutes on a typical workstation.>
```

### Document broken, abandoned, or superseded steps

> Document steps (or tasks) that are broken, abandoned, or superseded using the same template as for enabled steps, with two differences: add "(DISABLED)" after the step name, and use the first entry (Purpose) to state the reason why the step is disabled (e.g., that it no longer builds, was discontinued, or was replaced by a better approach). Use `TASK_DISABLED=true` to exclude such steps from normal runs. Keep disabled steps in the repository (and therefore in the documentation) only if they serve a purpose -- for example, to preserve historical context or to allow running them with `--run-disabled` when needed.

**Example template for documenting a disabled step of the workflow (copy and fill in):**

```
## <Name> (DISABLED)

**Disabled because:** <Reason why this step is disabled, e.g., replaced by the optimized variant and no longer maintained.>

**Purpose:** <One sentence describing what this step achieves.>

**Commands:**
./run_tasks.sh tasks/<path>

**Inputs:** <What this step expects to exist (e.g., outputs of previous steps).>

**Outputs:** <What is produced and where (e.g., tasks/<path>/<run_folder>/).>

**Requirements:** <e.g., Apptainer, 16 GB RAM, GPU.>

**Expected runtime:** <e.g., ~5 minutes on a typical workstation.>
```

---

## Tasks

### Keep run.sh very short

> `run.sh` should be minimal: a thin wrapper that invokes assets. All domain logic belongs in assets, not in `run.sh`.

**Examples:**

- Good: `run.sh` contains `run_experiment` or `python3 "$ASSETS/plots/runtimes.py" "$TASKS/experiment"`.
- Avoid: `run.sh` with dozens of lines of argument parsing, path construction, or experiment logic.

### Define dependencies in run_deps.sh

> Declare dependencies in `run_deps.sh` so they match what is documented and so the framework can resolve them automatically (e.g., for workload managers and dependency ordering).

**Example:**

- `run_deps.sh` exports `DEPENDENCIES+=("tasks/build/data:$BUILD_FOLDER" "tasks/experiment/MatMul/IS1/data:$BUILD_FOLDER")`, ensuring the runner verifies these tasks have succeeded before running the current task.

### Structure tasks hierarchically and reuse code

> Organize tasks in a logical hierarchy and reuse shared logic via `run_env.sh`. Use `task_meta.sh` for static configuration and `run_env.sh` for environment setup and helper functions.

**Examples:**

- A hierarchy `tasks/experiment/<routine>/<input_size>/<variant>/` groups related tasks; `run_env.sh` at the routine level defines `create_data()` and `run_experiment()` so leaf `run.sh` files reduce to a single function call.
- Shared variables (`ROUTINE`, `INPUT_SIZE`, `COMPETITOR`) in `task_meta.sh` propagate through the tree and are used in `run_deps.sh` and `run_env.sh`.

---

## Assets

### Write assets out of context of the task mechanism

> Assets should be written as standalone programs that do not depend on the task framework. They should not know about the `tasks/` folder structure or where other runs store their outputs. Instead, they receive such data as input arguments.

**Examples:**

- Good: A plot script accepts `experiment_dir` as an argument and walks it to discover results; it does not hardcode paths like `tasks/experiment/MatMul/IS1/baseline/assets-run3/`.
- Good: An experiment binary accepts input and output file paths as command-line arguments; the task's `run_env.sh` or `run.sh` passes those paths.
- Avoid: An asset that reads `$TASKS` or constructs paths to sibling task outputs; such logic belongs in the task layer.

### Log all measurements from experiments

> Experiments that measure runtimes (or similar) should perform multiple warm-up iterations and multiple evaluation iterations. Log all runtimes from both phases. This allows downstream analysis to inspect warm-up behavior, exclude outliers, or apply custom aggregation.

**Examples:**

- A benchmark runs 3 warm-ups and 10 evaluations; it writes all 3 warm-up runtimes to `runtimes_warmups` and all 10 evaluation runtimes to `runtimes`, one value per line.
- A plotting asset reads `runtimes` for speedup analysis and can optionally use `runtimes_warmups` to diagnose cold-start effects.

---

## Containers

### Avoid unnecessary bloat

> Keep container images small by including only what is needed for the task. Avoid extra tools, debug packages, or large base images when a minimal one suffices.

**Example:**

- Use a minimal base (e.g., `ubuntu:22.04` with only required packages) instead of a full desktop or development stack when the task only needs a compiler and runtime.

### Separate runtime environments for independent assets

> Use separate containers for assets with different runtime requirements (e.g., C++ vs. Python, different toolchains). This keeps each image focused and avoids pulling unnecessary dependencies into unrelated tasks.

**Examples:**

- A C++ experiment uses a GCC container; a Python plotting script uses a separate container with matplotlib and numpy. Each task references only the container it needs.
- Avoid: A single "do everything" container that includes compilers, Python, R, and plotting tools when most tasks use only one of these.
