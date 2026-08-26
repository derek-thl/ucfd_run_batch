#!/usr/bin/env bash
# Section 23.O - post-processing is incremental and idempotent.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace post)"
install_fakes "$workspace"
assert_fakes_active

make_csv "${workspace}/output_batch_1.csv" 0
flow_dir="${workspace}/case_0/flow"
trd_dir="${workspace}/case_0/trd"
vtk_dir="${workspace}/case_0/vtk"
summary="${workspace}/run_post_processing_cases_summary.csv"

make_flow_case "$flow_dir" 2
make_flow_result "$flow_dir" 3000
make_transport_case "$trd_dir" 2 T 300
mkdir -p "${trd_dir}/300"
printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"

run_post() {
    ( cd "$workspace" && env "$@" bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
}

# ---- first run builds the outputs --------------------------------------------

out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the first post run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "the first run records one completed case"
assert_file_exists "${vtk_dir}/flow_0.vtu" "the first run writes flow_0.vtu"
assert_file_exists "${vtk_dir}/flow_latest_3000.vtu" "the first run writes flow_latest_3000.vtu"
assert_file_exists "${vtk_dir}/trd_0.vtu" "the first run writes trd_0.vtu"
assert_file_exists "${vtk_dir}/trd_300.vtu" "the first run writes trd_300.vtu"
assert_file_exists "${vtk_dir}/post_processing.complete" "the first run writes the marker"

# ---- second run skips unchanged sources --------------------------------------

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the second post run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" skipped 3)" \
    "the second run records one skipped case"
assert_eq 0 "$(fake_call_count foamToVTK)" \
    "the second run runs no conversion when the sources are unchanged"
assert_contains "$out" "post-processing outputs are current" \
    "the second run explains the skip"

# ---- a new source result time forces a rebuild -------------------------------

mkdir -p "${trd_dir}/600"
printf 'FoamFile { object T; }\n' > "${trd_dir}/600/T"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the rebuild run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "a changed source result rebuilds the case"
assert_ne 0 "$(fake_call_count foamToVTK)" "the rebuild runs the conversion"
assert_file_exists "${vtk_dir}/trd_600.vtu" "the rebuild writes the new transport time"

# ---- FORCE_POST=1 rebuilds an unchanged case ---------------------------------

reset_fake_records
out="$(run_post FORCE_POST=1)" && status=0 || status=$?
assert_status 0 "$status" "the forced run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "FORCE_POST=1 rebuilds an unchanged case"
assert_ne 0 "$(fake_call_count foamToVTK)" "FORCE_POST=1 runs the conversion again"

# A confirming skip proves that the forced rebuild restored a current signature.
reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the confirming run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" skipped 3)" \
    "the case is current again after a forced rebuild"
