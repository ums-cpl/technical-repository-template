TASK_DEPENDS+=(
    tasks/build/containers/gcc
    tasks/build/optimized:$BUILD_FOLDER
    tasks/experiment/MatMul/IS1/data:assets
)
