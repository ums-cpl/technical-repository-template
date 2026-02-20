#!/usr/bin/env bash
apptainer build --force "$REPOSITORY_ROOT/containers/gcc.sif" "$REPOSITORY_ROOT/containers/gcc.def"