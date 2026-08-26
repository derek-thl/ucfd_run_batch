#!/usr/bin/env bash
# Section 23.B - --help exits 0 and prints the documented options.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace help)"
cd "$workspace"

check_help() {
    local script="$1"
    shift
    local output status
    output="$(bash "$script" --help 2>&1)" && status=0 || status=$?
    assert_status 0 "$status" "--help must exit 0 for ${script##*/}"
    assert_contains "$output" "Usage:" "${script##*/} --help prints a usage block"

    local expected
    for expected in "$@"; do
        assert_contains "$output" "$expected" \
            "${script##*/} --help documents $expected"
    done
}

# Top-level v4 options from specification Section 6.4.
check_help "$RUN_BATCH" \
    "--stage" "--jobs" "--setup-jobs" "--mesh-jobs" "--flow-jobs" \
    "--transport-jobs" "--post-jobs" "--batch-jobs" "--master-dir" \
    "--output-dir" "--overwrite" "--keep-going" "--skip-post" \
    "--save-times" "--scalar-field" "--dry-run" "--help" \
    "MASTER_BATCH_DIR" "RUN_BATCH_OUTPUT_DIR" "RUN_BATCH_OVERWRITE"

check_help "$SETUP_SCRIPT" "-i"
check_help "$MESH_SCRIPT" "-i" "-j" "FORCE_MESH"
check_help "$FLOW_SCRIPT" "-i" "-j" "FORCE_FLOW" "RECONSTRUCT_MODE"
check_help "$TRANSPORT_SCRIPT" "-i" "-j" "--save-times"
check_help "$POST_SCRIPT" "-i" "-j" "FORCE_POST" "SCALAR_FIELD"
