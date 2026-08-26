#!/usr/bin/env bash
# Section 23.A - Bash syntax for all six batch-runner scripts.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every scenario runs in its own new temporary workspace, including this
# read-only scenario. The workspace also isolates any tool side effects.
workspace="$(new_workspace syntax)"
cd "$workspace"

scripts=(
    "$RUN_BATCH"
    "$SETUP_SCRIPT"
    "$MESH_SCRIPT"
    "$FLOW_SCRIPT"
    "$TRANSPORT_SCRIPT"
    "$POST_SCRIPT"
)

assert_eq 6 "${#scripts[@]}" "Section 23.A covers exactly six scripts"

for script in "${scripts[@]}"; do
    assert_file_exists "$script" "batch-runner script is present"
    output="$(bash -n "$script" 2>&1)" && status=0 || status=$?
    assert_status 0 "$status" "bash -n must exit 0 for ${script##*/}: $output"
done
