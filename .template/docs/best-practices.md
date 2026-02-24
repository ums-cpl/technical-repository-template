## Best Practices

- **Assets:** Write them as if tasks don't exist—executable by themselves, not reading the `tasks/` folder directly. Accept paths to files/folders (that may be in `tasks/`) as arguments instead.
- **Tasks:** Keep `run.sh` short and simple; do task-related processing in asset files. Use `task_meta.sh` for shared metadata across a subtree and `run_env.sh` for setting up the environment in which the task is run. Use `TASK_DISABLED=true` in `task_meta.sh` to temporarily exclude tasks (e.g. broken or slow variants); run them with `--run-disabled` when needed.
- **Containers:** Avoid unnecessary bloat to keep image sizes small.
- **Documentation:** Describe the available tasks and how they are expected to run. For each task (or task group), document its purpose, prerequisites, inputs, outputs, and exact call to `run_tasks.sh` (e.g., via a README).