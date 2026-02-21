TASK_DEPENDS+=(
    tasks/build/containers/gcc
    tasks/build/baseline:$BUILD_FOLDER
    tasks/experiment/MatMul/IS2/data:assets
)
