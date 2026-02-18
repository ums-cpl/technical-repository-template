create_data() {
    if [[ -z "${I:-}" || -z "${J:-}" || -z "${K:-}" ]]; then
        echo "Error: I, J, K must be set." >&2
        return 1
    fi
    "$REPOSITORY_ROOT/tasks/build/data/$BUILD_FOLDER/matmul" "$I" "$J" "$K"
}

run_baseline() {
    "$REPOSITORY_ROOT/tasks/build/baseline/$BUILD_FOLDER/matmul" \
        "$RUN_FOLDER/../../data/assets/input_A.txt" \
        "$RUN_FOLDER/../../data/assets/input_B.txt" \
        "$RUN_FOLDER/../../data/assets/input_C.txt" \
        "$RUN_FOLDER/../../data/assets/output_C.txt"
}

run_optimized() {
    "$REPOSITORY_ROOT/tasks/build/optimized/$BUILD_FOLDER/matmul" \
        "$RUN_FOLDER/../../data/assets/input_A.txt" \
        "$RUN_FOLDER/../../data/assets/input_B.txt" \
        "$RUN_FOLDER/../../data/assets/input_C.txt" \
        "$RUN_FOLDER/../../data/assets/output_C.txt"
}
