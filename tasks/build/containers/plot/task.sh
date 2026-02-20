#!/usr/bin/env bash
apptainer build --force "$REPOSITORY_ROOT/containers/plot.sif" "$REPOSITORY_ROOT/containers/plot.def"
