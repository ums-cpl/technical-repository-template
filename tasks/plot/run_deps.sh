export DEPENDENCIES+=(
    "tasks/build/containers/plot:$BUILD_FOLDER"
    "tasks/experiment/*/*/!(data):*-run*"
)