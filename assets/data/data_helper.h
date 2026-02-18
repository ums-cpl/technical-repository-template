#ifndef DATA_HELPER_H
#define DATA_HELPER_H

#ifndef EPSILON
#define EPSILON 1e-4f
#endif

#include <fstream>
#include <limits>
#include <cmath>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

// Compute total size from dimensions.
inline size_t total_size(const std::vector<int>& dims) {
    size_t n = 1;
    for (int d : dims) n *= static_cast<size_t>(d);
    return n;
}

// Compute linear index from multidimensional index (row-major).
inline size_t index_to_linear(const std::vector<int>& idx, const std::vector<int>& dims) {
    size_t linear = 0;
    size_t stride = 1;
    for (int i = static_cast<int>(dims.size()) - 1; i >= 0; --i) {
        linear += static_cast<size_t>(idx[i]) * stride;
        stride *= static_cast<size_t>(dims[i]);
    }
    return linear;
}

// Compute multidimensional index from linear index.
inline std::vector<int> linear_to_index(size_t linear, const std::vector<int>& dims) {
    std::vector<int> idx(dims.size());
    for (int i = static_cast<int>(dims.size()) - 1; i >= 0; --i) {
        idx[i] = static_cast<int>(linear % static_cast<size_t>(dims[i]));
        linear /= static_cast<size_t>(dims[i]);
    }
    return idx;
}

// Read a tensor from text file: first line lists dimensions, then values in row-major order.
// Format: "d0 d1 d2 ..." on first line, then lines of space-separated values (last dim per line).
inline bool read_matrix(const std::string& filename, std::vector<float>& mat, std::vector<int>& dims) {
    std::ifstream ifs(filename);
    if (!ifs) return false;
    std::string line;
    if (!std::getline(ifs, line)) return false;
    std::istringstream iss(line);
    dims.clear();
    int d;
    while (iss >> d) dims.push_back(d);
    if (dims.empty()) return false;

    size_t n = total_size(dims);
    mat.resize(n);

    size_t read = 0;
    int last_dim = dims.back();
    while (read < n && std::getline(ifs, line)) {
        std::istringstream row_stream(line);
        for (int j = 0; j < last_dim && read < n; ++j) {
            if (!(row_stream >> mat[read])) return false;
            ++read;
        }
    }
    return read == n;
}

// Write a tensor to text file: first line dimensions, then values in row-major order.
inline bool write_matrix(const std::string& filename, const std::vector<float>& mat, const std::vector<int>& dims) {
    size_t n = total_size(dims);
    if (mat.size() != n) return false;

    std::ofstream ofs(filename);
    if (!ofs) return false;
    for (size_t i = 0; i < dims.size(); ++i) {
        if (i > 0) ofs << " ";
        ofs << dims[i];
    }
    ofs << "\n";
    ofs << std::setprecision(std::numeric_limits<float>::max_digits10);

    int last_dim = dims.back();
    size_t written = 0;
    while (written < n) {
        for (int j = 0; j < last_dim && written < n; ++j) {
            if (j > 0) ofs << " ";
            ofs << mat[written];
            ++written;
        }
        ofs << "\n";
    }
    return ofs.good();
}

// Compare two tensors for elementwise closeness. Returns true if all elements within eps.
// worst_idx receives the linear index of the worst mismatch.
inline bool compare_matrices(
    const std::vector<float>& a, const std::vector<float>& b,
    const std::vector<int>& dims,
    int& num_mismatches, float& max_diff, size_t& worst_idx,
    float eps = EPSILON
) {
    size_t n = total_size(dims);
    num_mismatches = 0;
    max_diff = 0;
    worst_idx = static_cast<size_t>(-1);

    if (a.size() != n || b.size() != n) return false;

    for (size_t i = 0; i < n; ++i) {
        float diff = std::fabs(a[i] - b[i]);
        if (diff > eps) {
            ++num_mismatches;
            if (diff > max_diff) {
                max_diff = diff;
                worst_idx = i;
            }
        }
    }
    return num_mismatches == 0;
}

#endif /* DATA_HELPER_H */
