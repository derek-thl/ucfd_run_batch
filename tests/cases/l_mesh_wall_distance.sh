#!/usr/bin/env bash
# Section 23.L - fresh mesh command sequence and the flow wallDistance rule.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# ---- fresh mesh --------------------------------------------------------------

workspace="$(new_workspace mesh)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2

out="$(cd "$workspace" && bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the fresh mesh stage must succeed: $out"

case_dir="${workspace}/case_0/flow"

# The v4 fresh mesh command sequence.
assert_eq 1 "$(fake_call_count surfaceFeatureExtract)" "surfaceFeatureExtract runs once"
assert_eq 1 "$(fake_call_count blockMesh)" "blockMesh runs once"
assert_eq 1 "$(fake_call_count snappyHexMesh)" "snappyHexMesh runs once"
assert_eq 1 "$(fake_call_count reconstructParMesh)" "reconstructParMesh runs once"
assert_eq 1 "$(fake_call_count checkMesh)" "checkMesh runs once"

assert_eq "$(argv_line -force)" "$(fake_argvs decomposePar)" \
    "decomposePar uses -force"
assert_eq "$(argv_line -constant)" "$(fake_argvs reconstructParMesh)" \
    "reconstructParMesh uses -constant"

# The exact wallDistance-generating command from the specification.
assert_eq \
    "$(argv_line -allGeometry -allTopology -writeAllFields -time 0)" \
    "$(fake_argvs checkMesh)" \
    "checkMesh -allGeometry -allTopology -writeAllFields -time 0"

# Parallel meshing uses the decomposeParDict subdomain count.
assert_eq \
    "$(argv_line -np 2 snappyHexMesh -parallel -overwrite)" \
    "$(fake_argvs mpirun)" \
    "snappyHexMesh runs in parallel with np from decomposeParDict"
assert_eq "$(argv_line -parallel -overwrite)" "$(fake_argvs snappyHexMesh)" \
    "snappyHexMesh receives -parallel -overwrite"

# Every mesh command runs inside the case directory.
assert_eq "$case_dir" "$(fake_cwds checkMesh)" "checkMesh runs in the case directory"
assert_eq "$case_dir" "$(fake_cwds blockMesh)" "blockMesh runs in the case directory"

# Required artifacts.
assert_file_exists "${case_dir}/0/wallDistance" "the mesh stage writes 0/wallDistance"
assert_file_exists "${case_dir}/restart.marker" "the mesh stage writes the restart marker"
assert_eq 1 "$(summary_status_count "${workspace}/run_mesh_cases_summary.csv" meshed)" \
    "the mesh summary records one meshed case"

# ---- flow skips the fallback when wallDistance exists -------------------------

workspace="$(new_workspace flowskip)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${workspace}/case_0/flow/0/wallDistance"

out="$(cd "$workspace" && bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the flow stage must succeed with an existing wallDistance: $out"
assert_eq 0 "$(fake_call_count checkMesh)" \
    "flow skips the checkMesh fallback when 0/wallDistance exists"

# ---- flow runs the fallback when wallDistance is missing ----------------------

workspace="$(new_workspace flowfallback)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
assert_file_missing "${workspace}/case_0/flow/0/wallDistance" \
    "the fallback fixture starts without wallDistance"

out="$(cd "$workspace" && bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the flow stage must succeed without wallDistance: $out"
assert_eq 1 "$(fake_call_count checkMesh)" \
    "flow runs the checkMesh fallback when 0/wallDistance is missing"
assert_eq "$(argv_line -writeAllFields -time 0)" "$(fake_argvs checkMesh)" \
    "the flow fallback uses checkMesh -writeAllFields -time 0"
assert_file_exists "${workspace}/case_0/flow/0/wallDistance" \
    "the fallback creates 0/wallDistance"
