export CONTAINER=$REPOSITORY_ROOT/containers/plot.sif
export TASK_DEPENDS=(tasks/experiment)

plot_runtimes() {
    python3 "$REPOSITORY_ROOT/assets/plots/runtimes.py" "$REPOSITORY_ROOT/tasks/experiment/$ROUTINE"
}
