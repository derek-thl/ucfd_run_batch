#!/usr/bin/env bash
# Section 23.N - transport continuation keeps the existing mesh and state.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

build_continuation_case() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active

    make_csv "${workspace}/output_batch_1.csv" 0
    flow_dir="${workspace}/case_0/flow"
    trd_dir="${workspace}/case_0/trd"

    make_flow_case "$flow_dir" 2
    make_flow_mesh "$flow_dir"
    make_flow_result "$flow_dir" 3000
    printf 'flow-mesh-points\n' > "${flow_dir}/constant/polyMesh/points"
    printf 'flow-U-at-3000\n' > "${flow_dir}/3000/U"
    printf 'flow-nut-at-3000\n' > "${flow_dir}/3000/nut"
    printf 'flow-phi-at-3000\n' > "${flow_dir}/3000/phi"

    make_transport_case "$trd_dir" 2 T 300

    # Existing transport mesh and initial state that a continuation must keep.
    mkdir -p "${trd_dir}/constant/polyMesh"
    local name
    for name in points boundary faces owner neighbour; do
        printf 'transport-mesh-%s\n' "$name" > "${trd_dir}/constant/polyMesh/${name}"
    done
    printf 'transport-U\n' > "${trd_dir}/0/U"
    printf 'transport-nut\n' > "${trd_dir}/0/nut"
    printf 'transport-phi\n' > "${trd_dir}/0/phi"
}

# ---- restart evidence: the transport marker ---------------------------------

build_continuation_case marker
printf 'done\n' > "${trd_dir}/transport.marker"

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the transport continuation must succeed: $out"
case_output="$(case_log "$workspace" _transport_logs case_0_trd)"

# Continuation is detected before preparation.
assert_contains "$case_output" \
    "Continue mode detected before preparation; skip flow mesh/field recopy." \
    "transport detects continuation before preparation"
assert_not_contains "$case_output" "Prepared transport case using flow latest time" \
    "a continuation does not prepare the case from flow"
assert_contains "$case_output" "Run mode       : continue" \
    "the transport run mode is continue"

# The existing mesh is not replaced.
assert_eq "transport-mesh-points" "$(cat "${trd_dir}/constant/polyMesh/points")" \
    "a continuation keeps constant/polyMesh"

# The existing initial fields are not overwritten from flow.
assert_eq "transport-U" "$(cat "${trd_dir}/0/U")" "a continuation keeps 0/U"
assert_eq "transport-nut" "$(cat "${trd_dir}/0/nut")" "a continuation keeps 0/nut"
assert_eq "transport-phi" "$(cat "${trd_dir}/0/phi")" "a continuation keeps 0/phi"

# The solver runs from inside the transport directory.
assert_eq "$trd_dir" "$(fake_cwds scalarTransportDeffFoam)" \
    "the solver runs inside the transport directory"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" continued)" \
    "the transport summary records one continued case"

# ---- restart evidence: an existing nonzero time directory -------------------

build_continuation_case timedir
mkdir -p "${trd_dir}/120"
printf 'existing-T\n' > "${trd_dir}/120/T"

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "a nonzero time directory must select continuation: $out"
case_output="$(case_log "$workspace" _transport_logs case_0_trd)"
assert_contains "$case_output" "Continue mode detected before preparation" \
    "an existing nonzero time directory is restart evidence"
assert_eq "transport-mesh-points" "$(cat "${trd_dir}/constant/polyMesh/points")" \
    "a continuation from a time directory keeps constant/polyMesh"

# ---- FORCE_TRANSPORT=1 returns to the fresh path ----------------------------

build_continuation_case forced
printf 'done\n' > "${trd_dir}/transport.marker"

out="$(cd "$workspace" && FORCE_TRANSPORT=1 FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "FORCE_TRANSPORT=1 must succeed: $out"
case_output="$(case_log "$workspace" _transport_logs case_0_trd)"
assert_contains "$case_output" "Run mode       : fresh" \
    "FORCE_TRANSPORT=1 returns to the fresh run mode"
assert_contains "$case_output" "Prepared transport case using flow latest time: 3000" \
    "FORCE_TRANSPORT=1 returns to fresh preparation"
assert_eq "flow-mesh-points" "$(cat "${trd_dir}/constant/polyMesh/points")" \
    "the forced fresh path copies the flow mesh"
assert_eq "flow-U-at-3000" "$(cat "${trd_dir}/0/U")" \
    "the forced fresh path copies the latest flow U"
