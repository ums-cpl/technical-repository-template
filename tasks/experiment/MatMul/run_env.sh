create_data() {
    if [[ -z "${I:-}" || -z "${J:-}" || -z "${K:-}" ]]; then
        echo "Error: I, J, K must be set." >&2
        return 1
    fi
    "$TASKS/build/data/$BUILD_FOLDER/matmul" "$I" "$J" "$K"
}

run_experiment() {
    "$TASKS/build/$COMPETITOR/$BUILD_FOLDER/matmul" \
        "$TASKS/experiment/$ROUTINE/$INPUT_SIZE/data/$BUILD_FOLDER/input_A.txt" \
        "$TASKS/experiment/$ROUTINE/$INPUT_SIZE/data/$BUILD_FOLDER/input_B.txt" \
        "$TASKS/experiment/$ROUTINE/$INPUT_SIZE/data/$BUILD_FOLDER/input_C.txt" \
        "$TASKS/experiment/$ROUTINE/$INPUT_SIZE/data/$BUILD_FOLDER/output_C.txt"
}
