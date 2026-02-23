#!/usr/bin/env bash
g++ "$ASSETS/experiments/optimized/matmul.cpp" -I"$ASSETS/data" -O3 -o matmul
