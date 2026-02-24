# Artifact Packing

This template simplifies the process of creating an artifact (e.g., a reproducibility artifact for a submission) into the following steps:

1. Gather relevant assets, tasks, containers, workload managers, and `run_tasks.sh` into a new repository.
2. Create high-level scripts that run the necessary tasks via `run_tasks.sh` (typically: build, create data, run experiments, plot results).
3. Create an artifact readme.
4. Distribute:
   - **Mutable on GitHub:** Most up-to-date version (e.g., including bug fixes) with container definition files only.
   - **Immutable on Zenodo (or similar):** For paper reference, with both container definition files and built containers. Artifact readme links to GitHub for the latest version.
   - This separation records the exact environment used for experiments while keeping the GitHub repository small.