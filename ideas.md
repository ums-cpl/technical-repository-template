# Ideas

## Task dependencies / multi-step workflows

**Current situation:** When a workflow requires multiple steps with dependencies (e.g., build → generate data → experiment → analyse), the user has to submit multiple `run_tasks.sh` calls. With a workload manager, each step must complete before the next can be submitted, so the user has to wait and manually chain the runs.

**Idea:** Let tasks define their dependencies (e.g., in `env.sh`). `run_tasks.sh` could then create multiple jobs with dependencies among them, so the workload manager handles the chaining automatically.


