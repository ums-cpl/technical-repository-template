# Tips and Tricks

Short practical advice for using this template effectively.

---

## Before running tasks, do a dry run

Before running tasks (especially large or long-running workflows), it is advisable to do a dry run. Use the `--dry-run` option so that the runner builds the execution manifest and prints what would be run, without actually submitting or executing anything. This helps you verify task selection, dependency order, and paths before committing to a full run.

**Example:**

```bash
./run_tasks.sh --dry-run tasks/experiment/
```

See [Template Reference](template-reference.md) for more on `--dry-run`.
