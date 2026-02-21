TASK_DEPENDS+=(
    "tasks/build/containers/plot"
    "tasks/experiment/*/*/!(data):run*"
)
