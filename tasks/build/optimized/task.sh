#!/usr/bin/env bash
g++ "$REPOSITORY_ROOT/assets/experiments/optimized/matmul.cpp" -I"$REPOSITORY_ROOT/assets/data" -O3 -o matmul

