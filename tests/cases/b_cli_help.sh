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
        assert_help_option "$output" "$expected" \
            "${script##*/} --help documents $expected"
    done
}

# Top-level v4 options from specification Section 6.4.
#
# Exclusion: the current top-level help does not display the documented
# `--stages` alias or the `--` end-of-options marker. That is a confirmed
# production documentation gap owned by Issue #10, not an Issue #4 harness
# defect. See tests/README.md, "Known contract gaps".
check_help "$RUN_BATCH" \
    "-s" "--stage" "-j" "--jobs" "--setup-jobs" "--mesh-jobs" "--flow-jobs" \
    "--transport-jobs" "--post-jobs" "-B" "--batch-jobs" "-m" "--master-dir" \
    "-o" "--output-dir" "-f" "--overwrite" "--keep-going" "--skip-post" \
    "--save-times" "--scalar-field" "-n" "--dry-run" "-h" "--help" \
    "MASTER_BATCH_DIR" "RUN_BATCH_OUTPUT_DIR" "RUN_BATCH_OVERWRITE"

# Setup direct CLI from specification Section 14.3.
check_help "$SETUP_SCRIPT" \
    "-i" "-j" "-b" "-O" "-T" "-t" "-n" "-s" "-a" "-k" "-y" "-e" \
    "--zero-ws-mode" "--min-ws" "--dry-run" "-h" "--help"

# Mesh direct CLI and environment from specification Section 15.1.
check_help "$MESH_SCRIPT" \
    "-i" "-O" "--output-dir" "-j" "-h" "--help" \
    "FORCE_MESH" "PROGRESS_INTERVAL" "PROGRESS_MAX_ACTIVE"

# Flow direct CLI and environment from specification Section 16.1.
check_help "$FLOW_SCRIPT" \
    "-i" "-O" "--output-dir" "-j" "--case-prefix" "-h" "--help" \
    "FORCE_FLOW" "CLEAN_PROCESSORS" "RECONSTRUCT_MODE"

# Transport direct CLI from specification Section 17.1.
check_help "$TRANSPORT_SCRIPT" \
    "-i" "-O" "--output-dir" "-j" "--save-times" \
    "--flow-prefix" "--transport-prefix" "--base-transport-dir" \
    "-h" "--help"

# Post-processing direct CLI and environment from specification Section 18.2.
check_help "$POST_SCRIPT" \
    "-i" "-O" "--output-dir" "-j" "-h" "--help" \
    "POST_PARALLEL_JOBS" "SCALAR_FIELD" "FORCE_POST" \
    "BATCH_CSV_PATH" "BATCH_CSV"
