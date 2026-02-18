#include "data_helper.h"
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstdlib>
#include <limits>
#include <iomanip>
#include <cmath>
#include <algorithm>
#include <chrono>

#ifndef TILE_I
#define TILE_I 32
#endif

#ifndef TILE_J
#define TILE_J 32
#endif

#ifndef TILE_K
#define TILE_K 32
#endif

#ifndef WARMUP_RUNS
#define WARMUP_RUNS 3
#endif

#ifndef EVAL_RUNS
#define EVAL_RUNS 5
#endif

void matmul(
    const std::vector<float>& A, // I x K
    const std::vector<float>& B, // K x J
    std::vector<float>& C,       // I x J, output
    int I, int J, int K
) {
    for (int ii = 0; ii < I; ii += TILE_I) {
        int i_max = std::min(ii + TILE_I, I);
        for (int jj = 0; jj < J; jj += TILE_J) {
            int j_max = std::min(jj + TILE_J, J);
            for (int kk = 0; kk < K; kk += TILE_K) {
                int k_max = std::min(kk + TILE_K, K);
                for (int i = ii; i < i_max; ++i) {
                    for (int j = jj; j < j_max; ++j) {
                        float sum = (kk == 0) ? 0.0f : C[i * J + j];
                        for (int k = kk; k < k_max; ++k) {
                            sum += A[i * K + k] * B[k * J + j];
                        }
                        C[i * J + j] = sum;
                    }
                }
            }
        }
    }
}

int main(int argc, char* argv[]) {
    if (argc < 5) {
        std::cerr << "Usage: " << argv[0] << " <input_A.txt> <input_B.txt> <input_C.txt> <output_C.txt>" << std::endl;
        return 1;
    }

    std::string file_A = argv[1];
    std::string file_B = argv[2];
    std::string file_init_C = argv[3];
    std::string file_expected_C = argv[4];

    std::vector<float> A;
    std::vector<int> dim_A;
    if (!read_matrix(file_A, A, dim_A)) {
        std::cerr << "Failed to read " << file_A << std::endl;
        return 2;
    }
    if (dim_A.size() != 2) {
        std::cerr << "Expected 2D matrix in " << file_A << std::endl;
        return 2;
    }
    int I = dim_A[0], K = dim_A[1];

    std::vector<float> B;
    std::vector<int> dim_B;
    if (!read_matrix(file_B, B, dim_B)) {
        std::cerr << "Failed to read " << file_B << std::endl;
        return 2;
    }
    if (dim_B.size() != 2 || dim_B[0] != K) {
        std::cerr << "Mismatched K dimension between " << file_A << " (" << K << ") and " << file_B << "\n";
        return 2;
    }
    int J = dim_B[1];

    // Read initial C
    std::vector<float> init_C;
    std::vector<int> dim_init_C;
    if (!read_matrix(file_init_C, init_C, dim_init_C)) {
        std::cerr << "Failed to read " << file_init_C << std::endl;
        return 2;
    }
    if (dim_init_C.size() != 2 || dim_init_C[0] != I || dim_init_C[1] != J) {
        std::cerr << "Initial C dims don't match input dims " << I << "x" << J << std::endl;
        return 2;
    }

    std::vector<float> expected_C;
    std::vector<int> dim_C;
    if (!read_matrix(file_expected_C, expected_C, dim_C)) {
        std::cerr << "Failed to read " << file_expected_C << std::endl;
        return 2;
    }
    if (dim_C.size() != 2 || dim_C[0] != I || dim_C[1] != J) {
        std::cerr << "Expected output C dims don't match input dims " << I << "x" << J << std::endl;
        return 2;
    }

    constexpr int num_warmup = WARMUP_RUNS;
    constexpr int num_evals = EVAL_RUNS;
    std::vector<float> calc_C(I * J, 0.0f);
    std::vector<int64_t> warmup_times_ns;

    for (int w = 0; w < num_warmup; ++w) {
        std::copy(init_C.begin(), init_C.end(), calc_C.begin());
        auto start = std::chrono::high_resolution_clock::now();
        matmul(A, B, calc_C, I, J, K);
        auto end = std::chrono::high_resolution_clock::now();
        int64_t duration_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
        warmup_times_ns.push_back(duration_ns);
    }

    std::vector<int64_t> eval_times_ns;
    int64_t total_time_ns = 0;
    int64_t min_time_ns = std::numeric_limits<int64_t>::max();
    int64_t max_time_ns = 0;
    for (int t = 0; t < num_evals; ++t) {
        std::copy(init_C.begin(), init_C.end(), calc_C.begin());
        auto start = std::chrono::high_resolution_clock::now();
        matmul(A, B, calc_C, I, J, K);
        auto end = std::chrono::high_resolution_clock::now();
        int64_t duration_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
        eval_times_ns.push_back(duration_ns);
        total_time_ns += duration_ns;
        if (duration_ns < min_time_ns) min_time_ns = duration_ns;
        if (duration_ns > max_time_ns) max_time_ns = duration_ns;
    }
    double avg_time_ns = static_cast<double>(total_time_ns) / num_evals;

    int num_mismatches = 0;
    float max_diff = 0;
    size_t worst_idx = static_cast<size_t>(-1);

    bool equal = compare_matrices(calc_C, expected_C, dim_C, num_mismatches, max_diff, worst_idx);

    std::ofstream logfs("comparison.log");
    logfs << std::setprecision(std::numeric_limits<float>::max_digits10);

    if (equal) {
        logfs << "PASS: Calculated C matches expected output (" << I << "x" << J << ").\n";
        logfs << "Max diff: " << max_diff << "\n";
        std::cout << "PASS: Calculated C matches expected output (" << I << "x" << J << ")." << std::endl;
        std::cout << "Max diff: " << max_diff << std::endl;
    } else {
        std::vector<int> worst_idx_vec = linear_to_index(worst_idx, dim_C);
        logfs << "FAIL: " << num_mismatches << " element(s) mismatched (max diff = " << max_diff << ").\n";
        logfs << "Max diff: " << max_diff << " at index ";
        for (size_t i = 0; i < worst_idx_vec.size(); ++i) logfs << (i ? "," : "") << worst_idx_vec[i];
        logfs << "\n";
        logfs << "Max diff sample: calc_C = " << calc_C[worst_idx] << ", expected_C = " << expected_C[worst_idx] << '\n';
        std::cout << "FAIL: See comparison.log for details" << std::endl;
        std::cout << "Max diff: " << max_diff << std::endl;
    }

    logfs.close();

    std::ofstream ofs_eval("runtimes");
    for (int64_t t : eval_times_ns) {
        ofs_eval << t << "\n";
    }
    ofs_eval.close();

    std::ofstream ofs_warmup("runtimes_warmup");
    for (int64_t t : warmup_times_ns) {
        ofs_warmup << t << "\n";
    }
    ofs_warmup.close();

    std::cout << "Timing (ns): avg = " << static_cast<int64_t>(avg_time_ns)
              << ", min = " << min_time_ns
              << ", max = " << max_time_ns << std::endl;
    std::cout << "MatMul (" << I << "x" << K << ") x (" << K << "x" << J << "): "
              << num_evals << " evals, " << num_warmup << " warmups\n";
    return equal ? 0 : 1;
}
