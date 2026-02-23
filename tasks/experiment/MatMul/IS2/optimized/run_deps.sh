export DEPENDENCIES+=(
    tasks/build/containers/gcc:$BUILD_FOLDER
    tasks/build/$COMPETITOR:$BUILD_FOLDER
    tasks/experiment/$ROUTINE/$INPUT_SIZE/data:$BUILD_FOLDER
)
