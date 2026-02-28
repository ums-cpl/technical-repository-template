#!/usr/bin/env bash
g++ "$ASSETS/experiments/baseline/matmul.cpp" -I"$ASSETS/data" -O0 -g -o matmul
