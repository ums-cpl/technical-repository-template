#include "data_helper.h"
#include <iostream>
#include <random>
#include <cstdlib>

void matmul_gold(
    const std::vector<float>& A, // I x K
    const std::vector<float>& B, // K x J
    std::vector<float>& C,       // I x J, output
    int I, int J, int K
) {
    for (int i = 0; i < I; ++i) {
        for (int j = 0; j < J; ++j) {
            float sum = 0.0f;
            for (int k = 0; k < K; ++k) {
                sum += A[i * K + k] * B[k * J + j];
            }
            C[i * J + j] = sum;
        }
    }
}

int main(int argc, char* argv[]) {
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " I J K" << std::endl;
        return 1;
    }
    int I = std::atoi(argv[1]);
    int J = std::atoi(argv[2]);
    int K = std::atoi(argv[3]);

    std::vector<float> A(I * K);
    std::vector<float> B(K * J);
    std::vector<float> C(I * J, 0.0f);

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> dist(0.0f, 1.0f);

    for (auto& a : A) a = dist(gen);
    for (auto& b : B) b = dist(gen);

    std::vector<float> initial_C(I * J, 0.0f);
    if (!write_matrix("input_C.txt", initial_C, {I, J})) {
        std::cerr << "Failed to write input_C.txt" << std::endl;
        return 2;
    }

    matmul_gold(A, B, C, I, J, K);

    if (!write_matrix("input_A.txt", A, {I, K})) {
        std::cerr << "Failed to write input_A.txt" << std::endl;
        return 2;
    }
    if (!write_matrix("input_B.txt", B, {K, J})) {
        std::cerr << "Failed to write input_B.txt" << std::endl;
        return 2;
    }
    if (!write_matrix("output_C.txt", C, {I, J})) {
        std::cerr << "Failed to write output_C.txt" << std::endl;
        return 2;
    }

    std::cout << "Wrote A (" << I << "x" << K << ") to input_A.txt\n";
    std::cout << "Wrote B (" << K << "x" << J << ") to input_B.txt\n";
    std::cout << "Wrote initial C (" << I << "x" << J << ") to input_C.txt\n";
    std::cout << "Wrote expected C (" << I << "x" << J << ") to output_C.txt\n";

    return 0;
}
