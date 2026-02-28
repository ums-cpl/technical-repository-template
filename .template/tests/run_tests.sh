#!/usr/bin/env bash
# Run manifest tests: for each case file, run_tasks.sh --dry-run <args> and diff stdout to expected manifest.
# Usage: run_tests.sh [TEST ...]
#   No args: run all case files under .template/tests/cases/ recursively.
#   TEST: path relative to cwd (or absolute) — a case file, a directory (all case files under it), or a wildcard.
# Run from repository root: ./.template/tests/run_tests.sh [TEST ...]

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
CASES_DIR="$TESTS_DIR/cases"

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

if [[ ! -f "$REPOSITORY_ROOT/run_tasks.sh" ]]; then
  echo "Error: run_tasks.sh not found at $REPOSITORY_ROOT" >&2
  exit 1
fi
if [[ ! -d "$REPOSITORY_ROOT/tasks" ]]; then
  echo "Error: tasks/ not found at $REPOSITORY_ROOT" >&2
  exit 1
fi

# Resolve case file list: collect case files (must have .expected suffix). No args = all under CASES_DIR.
# With args = resolve each TEST relative to cwd (or absolute); expand wildcards; files and dirs (recurse).
collect_case_files() {
  local case_files=()
  if [[ $# -eq 0 ]]; then
    while IFS= read -r -d '' f; do
      case_files+=("$f")
    done < <(find "$CASES_DIR" -type f -name '*.expected' -print0 2>/dev/null | sort -z)
  else
    shopt -s nullglob
    shopt -s globstar 2>/dev/null || true
    local arg path
    for arg in "$@"; do
      if [[ -f "$arg" ]]; then
        [[ "$arg" != *.expected ]] && continue
        case_files+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
      elif [[ -d "$arg" ]]; then
        while IFS= read -r -d '' f; do
          case_files+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")
        done < <(find "$arg" -type f -name '*.expected' -print0 2>/dev/null)
      else
        for path in $arg; do
          if [[ -f "$path" ]]; then
            [[ "$path" != *.expected ]] && continue
            case_files+=("$(cd "$(dirname "$path")" && pwd)/$(basename "$path")")
          elif [[ -d "$path" ]]; then
            while IFS= read -r -d '' f; do
              case_files+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")
            done < <(find "$path" -type f -name '*.expected' -print0 2>/dev/null)
          fi
        done
      fi
    done
    printf '%s\n' "${case_files[@]}" | sort -u
    return
  fi
  printf '%s\n' "${case_files[@]}" | sort -u
}

run_one_case() {
  local case_file="$1"
  local args_line expected_file actual_file stripped_file
  stripped_file="${TMPDIR:-/tmp}/run_tests_stripped_$$"
  grep -v '^[[:space:]]*#' "$case_file" > "$stripped_file"
  args_line=$(sed -n '1p' "$stripped_file")
  if [[ "$(sed -n '2p' "$stripped_file")" != "---" ]]; then
    rm -f "$stripped_file"
    echo -e "${RED}FAIL${RESET} $case_file (invalid: after skipping comments, second line must be ---)"
    return 1
  fi
  expected_file="${TMPDIR:-/tmp}/run_tests_expected_$$"
  tail -n +3 "$stripped_file" > "$expected_file"
  rm -f "$stripped_file"
  actual_file="${TMPDIR:-/tmp}/run_tests_actual_$$"
  if ! ( set -- $args_line; "$REPOSITORY_ROOT/run_tasks.sh" --dry-run "$@" ) > "$actual_file" 2>/dev/null; then
    rm -f "$expected_file" "$actual_file"
    echo -e "${RED}FAIL${RESET} $case_file (run_tasks.sh failed)"
    return 1
  fi
  if ! diff -q "$expected_file" "$actual_file" >/dev/null 2>&1; then
    actual_saved="${case_file%.expected}.actual"
    { echo "$args_line"; echo "---"; cat "$actual_file"; } > "$actual_saved"
    rm -f "$expected_file" "$actual_file"
    echo -e "${RED}FAIL${RESET} $case_file (manifest diff; actual saved to $actual_saved)"
    return 1
  fi
  rm -f "$expected_file" "$actual_file"
  echo -e "${GREEN}PASS${RESET} $case_file"
  return 0
}

case_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && case_files+=("$f")
done < <(collect_case_files "$@")

if [[ ${#case_files[@]} -eq 0 ]]; then
  echo "Error: No case files found." >&2
  exit 1
fi

passed=0
failed=0
failed_list=()
for cf in "${case_files[@]}"; do
  if run_one_case "$cf"; then
    ((passed++)) || true
  else
    ((failed++)) || true
    failed_list+=("$cf")
  fi
done

total=$((passed + failed))
echo ""
echo "Total: $total, Passed: $passed, Failed: $failed"
if [[ $failed -gt 0 ]]; then
  echo "Failed:"
  printf '  %s\n' "${failed_list[@]}"
  exit 1
fi
exit 0
