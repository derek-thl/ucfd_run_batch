#!/usr/bin/env bash
# Section 23.M - fresh transport preparation and solve.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace fresh)"
install_fakes "$workspace"
assert_fakes_active

make_csv "${workspace}/output_batch_1.csv" 0
flow_dir="${workspace}/case_0/flow"
trd_dir="${workspace}/case_0/trd"

make_flow_case "$flow_dir" 2
make_flow_mesh "$flow_dir"
make_flow_result "$flow_dir" 3000
make_transport_case "$trd_dir" 2 T 300

# Distinguishable payloads prove that the fresh path copies from flow.
printf 'flow-mesh-points\n' > "${flow_dir}/constant/polyMesh/points"
printf 'flow-U-at-3000\n' > "${flow_dir}/3000/U"
printf 'flow-nut-at-3000\n' > "${flow_dir}/3000/nut"
printf 'flow-phi-at-3000\n' > "${flow_dir}/3000/phi"

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the fresh transport stage must succeed: $out"

case_output="$(case_log "$workspace" _transport_logs case_0_trd)"

# The requested save times are validated against controlDict endTime.
assert_contains "$case_output" "endTime check   : 300 >= 300" \
    "transport validates the requested save times against endTime"

# The flow mesh is copied into the transport case.
assert_file_exists "${trd_dir}/constant/polyMesh/points" \
    "fresh transport copies the flow mesh"
assert_eq "flow-mesh-points" "$(cat "${trd_dir}/constant/polyMesh/points")" \
    "the copied transport mesh comes from the flow case"

# The latest flow U and the optional nut and phi are synchronized.
assert_eq "flow-U-at-3000" "$(cat "${trd_dir}/0/U")" \
    "fresh transport copies the latest flow U"
assert_eq "flow-nut-at-3000" "$(cat "${trd_dir}/0/nut")" \
    "fresh transport copies the optional flow nut"
assert_eq "flow-phi-at-3000" "$(cat "${trd_dir}/0/phi")" \
    "fresh transport copies the optional flow phi"
assert_contains "$case_output" "Prepared transport case using flow latest time: 3000" \
    "transport reports the flow latest time"

# The solver runs in parallel from inside the transport directory.
assert_eq 1 "$(fake_call_count scalarTransportDeffFoam)" "the transport solver runs once"
assert_eq "$(argv_line -parallel)" "$(fake_argvs scalarTransportDeffFoam)" \
    "the transport solver runs with -parallel"
assert_eq "$trd_dir" "$(fake_cwds scalarTransportDeffFoam)" \
    "the transport solver runs inside the transport directory"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" solved)" \
    "the transport summary records one solved case"

# ---- optional fields are removed when flow does not provide them --------------

workspace="$(new_workspace optional)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
flow_dir="${workspace}/case_0/flow"
trd_dir="${workspace}/case_0/trd"

make_flow_case "$flow_dir" 2
make_flow_mesh "$flow_dir"
mkdir -p "${flow_dir}/3000"
printf 'flow-U\n' > "${flow_dir}/3000/U"   # no nut and no phi
make_transport_case "$trd_dir" 2 T 300
printf 'stale-nut\n' > "${trd_dir}/0/nut"
printf 'stale-phi\n' > "${trd_dir}/0/phi"

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "transport must succeed without optional flow fields: $out"
assert_file_missing "${trd_dir}/0/nut" \
    "a stale nut is removed when flow does not provide nut (Section 17.6.11)"
assert_file_missing "${trd_dir}/0/phi" \
    "a stale phi is removed when flow does not provide phi (Section 17.6.11)"

# ---- endTime must cover the largest requested save time ----------------------

workspace="$(new_workspace endtime)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
flow_dir="${workspace}/case_0/flow"
trd_dir="${workspace}/case_0/trd"

make_flow_case "$flow_dir" 2
make_flow_mesh "$flow_dir"
make_flow_result "$flow_dir" 3000
make_transport_case "$trd_dir" 2 T 100

out="$(cd "$workspace" && bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_failure "$status" "an endTime below the largest save time must fail"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "the transport summary records the endTime failure"
