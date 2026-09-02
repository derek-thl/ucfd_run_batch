#!/usr/bin/env bash
# Section 23.P - failure propagation.
#
# Includes the Issue #9 restorations: a failed required OpenFOAM command
# inside the mesh or flow stage fails the case and the stage (v4 Sections
# 15.5, 16.6, and 23.P).
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# assert_file_bytes_exact <path> <expected> <label>
# The comparison appends one literal X to each side, so a trailing newline byte
# stays significant inside command substitution.
assert_file_bytes_exact() {
    assert_file_exists "$1" "${3}: the file exists"
    assert_eq "${2}X" "$(cat -- "$1"; printf X)" "${3}: the exact bytes"
}

# ---- top level: a failed stage fails the batch -------------------------------

build_two_batches() {
    workspace="$(new_workspace "$1")"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    mkdir -p "$output"
    make_csv "${workspace}/output_batch_1.csv" 0
    make_csv "${workspace}/output_batch_2.csv" 0
}

build_two_batches stopfirst

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed stage must fail the run"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" "the failed stage is named"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"
assert_contains "$out" "Stop after first failed batch" \
    "the run stops before launching more batches"

# The child exit status is preserved through the stage report.
assert_contains "$out" "exit=3" "the original stage exit status is preserved"

stub_ran mesh 1 || _fail "the mesh stage ran for batch_1"
if stub_ran setup 2; then
    _fail "batch_2 must not start without --keep-going"
fi

# ---- --keep-going attempts the other batches ---------------------------------

build_two_batches keepgoing

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh --keep-going \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--keep-going must still report a final failure"
assert_contains "$out" "1 batch(es) failed." "the final report counts the failure"
stub_ran mesh 2 || _fail "--keep-going attempts batch_2"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "a failed batch must not report overall success"

# ---- a stage-script failure in any selected stage stops the batch ------------

build_two_batches poststage

out="$(STUB_FAIL_STAGES="post" bash "$RUN_BATCH" \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed post stage must fail the run"
assert_contains "$out" "Stage failed  : run_post_processing_cases.sh" \
    "the failed post stage is named"
stub_ran transport 1 || _fail "the earlier stages ran before the post failure"

# ---- stage level: post-processing conversion failure -------------------------

workspace="$(new_workspace postcase)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
mkdir -p "${workspace}/case_0/trd/300"
printf 'FoamFile { object T; }\n' > "${workspace}/case_0/trd/300/T"

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="foamToVTK" \
        bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed conversion must fail the post stage"
assert_eq 1 "$(summary_status_count "${workspace}/run_post_processing_cases_summary.csv" failed 3)" \
    "the post summary records the failed case"
assert_contains "$out" "One or more post-processing jobs failed" \
    "the post stage reports the failure"

# ---- stage level: transport precondition failure -----------------------------

workspace="$(new_workspace transportcase)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
# endTime 100 cannot cover the requested save time 300.
make_transport_case "${workspace}/case_0/trd" 2 T 100

out="$(cd "$workspace" && bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a transport precondition failure must fail the stage"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "the transport summary records the failed case"
assert_contains "$out" "One or more transport jobs failed" \
    "the transport stage reports the failure"

# ---- stage level: every required fresh-mesh command failure (Issue #9) -----------

# make_mesh_fixture <name> - one unmeshed flow case ready for a fresh mesh run.
make_mesh_fixture() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
}

for failing_command in surfaceFeatureExtract blockMesh decomposePar \
                       snappyHexMesh reconstructParMesh checkMesh; do
    make_mesh_fixture "meshfail_${failing_command}"

    out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="$failing_command" \
            bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_failure "$status" \
        "a failed ${failing_command} must make the mesh stage non-zero"
    summary="${workspace}/run_mesh_cases_summary.csv"
    assert_eq 1 "$(summary_status_count "$summary" failed)" \
        "a failed ${failing_command} produces a failed mesh summary row"
    assert_eq 0 "$(summary_status_count "$summary" meshed)" \
        "no success summary state is written after a failed ${failing_command}"
    assert_contains "$(cat "${workspace}/.run_mesh_cases_failed")" "case_0/flow" \
        "the mesh failure artifact identifies the affected case"
    assert_file_missing "${workspace}/case_0/flow/restart.marker" \
        "no restart marker is written after a failed ${failing_command}"
    assert_contains "$(case_log "$workspace" _mesh_logs case_0_flow)" \
        "Required mesh command failed" \
        "the case log names the failed required command (${failing_command})"
done

# ---- stage level: every required fresh-flow command failure (Issue #9) -----------

# make_flow_fixture <name> <with_walldistance> - one meshed flow case.
make_flow_fixture() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
    make_flow_mesh "${workspace}/case_0/flow"
    if [[ "$2" == "yes" ]]; then
        printf 'FoamFile { object wallDistance; }\n' \
            > "${workspace}/case_0/flow/0/wallDistance"
    fi
}

# RECONSTRUCT_MODE stays at the default (latest), so reconstructPar is a
# required command. checkMesh is required only on the wallDistance-fallback
# path, so that scenario starts without 0/wallDistance.
for failing_command in decomposePar renumberMesh simpleFoam reconstructPar checkMesh; do
    with_walldistance="yes"
    [[ "$failing_command" == "checkMesh" ]] && with_walldistance="no"
    make_flow_fixture "flowfail_${failing_command}" "$with_walldistance"

    out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="$failing_command" \
            bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_failure "$status" \
        "a failed ${failing_command} must make the flow stage non-zero"
    summary="${workspace}/run_flow_cases_summary.csv"
    assert_eq 1 "$(summary_status_count "$summary" failed)" \
        "a failed ${failing_command} produces a failed flow summary row"
    assert_eq 0 "$(summary_status_count "$summary" solved)" \
        "no success summary state is written after a failed ${failing_command}"
    assert_contains "$(cat "${workspace}/.run_flow_cases_failed")" "case_0/flow" \
        "the flow failure artifact identifies the affected case"
    assert_file_missing "${workspace}/case_0/flow/flow.marker" \
        "no flow marker is written after a failed ${failing_command}"
    assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
        "Required flow command failed" \
        "the case log names the failed required command (${failing_command})"
done

# ---- stage level: a failed setup row fails the setup stage (Issue #24) -----------

# make_setup_workspace <name> - a workspace with both setup base folders.
make_setup_workspace() {
    workspace="$(new_workspace "$1")"
    mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
}

# write_setup_csv <path> [<row> ...] - a DOE Batch CSV with explicit row text.
write_setup_csv() {
    local path="$1" row
    shift
    printf 'Case,WS,WD\n' > "$path"
    for row in "$@"; do
        printf '%s\n' "$row" >> "$path"
    done
}

make_setup_workspace setup_mixed
write_setup_csv "${workspace}/output_batch_1.csv" \
    "good_1,3.5,270.0" \
    "bad_1,not_a_number,270.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

summary="${workspace}/setup_cases_summary.csv"

assert_failure "$status" "a failed setup row must make the setup stage non-zero"
assert_eq 1 "$(summary_status_count "$summary" failed 9)" \
    "the setup summary records the failed row"
assert_eq 2 "$(summary_status_count "$summary" dry_run 9)" \
    "the successful row keeps its flow and transport summary records"
assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,3" \
    "the setup failure artifact identifies the failed row"
assert_contains "$out" "Some rows failed. Check:" "the setup stage prints the warning"
assert_contains "$out" "Summary: ${workspace}/setup_cases_summary.csv" \
    "the setup stage prints the summary path before the non-zero return"

# A setup invocation without a failed row keeps the current success behavior.

make_setup_workspace setup_allgood
write_setup_csv "${workspace}/output_batch_1.csv" \
    "good_1,3.5,270.0" \
    "good_2,4.5,90.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a setup dry-run with valid rows must exit 0"
assert_eq 0 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "a valid setup dry-run records no failed row"
assert_contains "$out" "Done." "the setup stage keeps the success diagnostic"

# An empty DOE Batch CSV with a valid header must not create a false failure.

make_setup_workspace setup_empty
write_setup_csv "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an empty DOE Batch CSV must exit 0"
assert_eq 0 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "an empty DOE Batch CSV records no failed row"

# A skipped row must not make the setup stage non-zero.

make_setup_workspace setup_skipped
write_setup_csv "${workspace}/output_batch_1.csv" \
    "zero_1,0,270.0" \
    "good_1,3.5,90.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --zero-ws-mode skip --dry-run 2>&1)" && status=0 || status=$?

summary="${workspace}/setup_cases_summary.csv"

assert_status 0 "$status" "a skipped row must not make the setup stage non-zero"
assert_eq 1 "$(summary_status_count "$summary" skipped 9)" \
    "the skipped row keeps the skipped summary state"
assert_eq 0 "$(summary_status_count "$summary" failed 9)" \
    "a skipped row is not a failed row"

# An invalid WS row and an invalid WD row produce the same failure signals.

for bad_row in "bad_ws,not_a_number,270.0" "bad_wd,3.5,not_a_number"; do
    make_setup_workspace "setup_${bad_row%%,*}"
    write_setup_csv "${workspace}/output_batch_1.csv" "$bad_row"

    out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 \
            --dry-run 2>&1)" && status=0 || status=$?

    assert_failure "$status" "row '${bad_row}' must make the setup stage non-zero"
    assert_eq 1 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
        "row '${bad_row}' produces a failed summary row"
    assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,2" \
        "row '${bad_row}' is identified in the setup failure artifact"
    assert_contains "$out" "Some rows failed. Check:" \
        "row '${bad_row}' keeps the existing warning"
done

# Concurrent failed rows aggregate into one non-zero setup status.

make_setup_workspace setup_concurrent
write_setup_csv "${workspace}/output_batch_1.csv" \
    "bad_1,not_a_number,270.0" \
    "bad_2,also_not_a_number,90.0" \
    "good_1,3.5,180.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 2 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "two concurrent failed rows must make the setup stage non-zero"
assert_eq 2 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "both concurrent failures reach the setup summary"
assert_eq 2 "$(grep -c . "${workspace}/.setup_cases_failed")" \
    "both concurrent failures reach the setup failure artifact"
assert_eq 2 "$(summary_status_count "${workspace}/setup_cases_summary.csv" dry_run 9)" \
    "the successful row of a concurrent invocation keeps its summary records"

# A failure-artifact write failure must not produce setup success.

make_setup_workspace setup_failfile
write_setup_csv "${workspace}/output_batch_1.csv" "good_1,3.5,270.0"
mkdir -p "${workspace}/.setup_cases_failed"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "an unwritable failure artifact must make the setup stage non-zero"

# A missing required CSV column stays a fatal validation failure.

make_setup_workspace setup_missingcolumn
printf 'Case,WD\ngood_1,270.0\n' > "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a missing required CSV column must stay non-zero"
assert_contains "$out" "Required column not found" "the missing column is named"

# A missing required command stays a fatal command-validation failure.

make_setup_workspace setup_missingcommand
write_setup_csv "${workspace}/output_batch_1.csv" "good_1,3.5,270.0"
mkdir -p "${workspace}/_setup_bin"
for command_name in surfaceTransformPoints foamDictionary; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${workspace}/_setup_bin/${command_name}"
    chmod +x "${workspace}/_setup_bin/${command_name}"
done

# surfaceCheck is intentionally absent. Prove that the scenario is not vacuous.
setup_path="${workspace}/_setup_bin:/usr/bin:/bin"
if ( PATH="$setup_path"; command -v surfaceCheck >/dev/null 2>&1 ); then
    _fail "the missing-command scenario needs a PATH without surfaceCheck"
fi

out="$(cd "$workspace" && PATH="$setup_path" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_failure "$status" "a missing required command must stay non-zero"
assert_contains "$out" "'surfaceCheck' not found in PATH" "the missing command is named"

# A failure-artifact append failure must not produce setup success.
#
# `.setup_cases_failed` points at /dev/full. The stage runner can create and
# truncate the artifact, but every append fails, and the artifact stays empty.
# The final status must not come from the artifact size alone.

make_setup_workspace setup_appendfail
write_setup_csv "${workspace}/output_batch_1.csv" "bad_1,not_a_number,270.0"
ln -s /dev/full "${workspace}/.setup_cases_failed"

# Prove that the scenario is not vacuous.
( : > "${workspace}/.setup_cases_failed" ) ||
    _fail "the append-failure scenario needs a truncatable /dev/full artifact"
if ( echo probe >> "${workspace}/.setup_cases_failed" ) 2>/dev/null; then
    _fail "the append-failure scenario needs an append that fails"
fi
if [[ -s "${workspace}/.setup_cases_failed" ]]; then
    _fail "the append-failure scenario needs an artifact that stays empty"
fi

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" \
    "a failed setup row must stay non-zero when the failure artifact append fails"
assert_eq 1 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "the setup summary still records the failed row"

# ---- stage level: a mixed non-dry-run setup invocation (Issue #24) ---------------

# make_setup_bases <workspace> - flow and transport base folders that the setup
# stage runner can copy and prepare without an OpenFOAM installation.
make_setup_bases() {
    local root="$1" flow="${1}/simpleFoam_files" transport="${1}/scalarTransportDeffFoam_files"
    local field

    mkdir -p "${flow}/0" "${flow}/system" "${flow}/constant/triSurface"
    for field in U p k nut epsilon; do
        printf 'FoamFile { object %s; }\n' "$field" > "${flow}/0/${field}"
    done

    cat > "${flow}/system/controlDict" <<'DICT'
FoamFile { version 2.0; format ascii; class dictionary; object controlDict; }
application     simpleFoam;
endTime         3000;
DICT

    cat > "${flow}/constant/turbulenceProperties" <<'DICT'
FoamFile { version 2.0; format ascii; class dictionary; object turbulenceProperties; }
simulationType      RAS;
DICT

    cat > "${flow}/system/blockMeshDict" <<'DICT'
FoamFile { version 2.0; format ascii; class dictionary; object blockMeshDict; }
vertices ( <xMin> <yMin> <zMin> <xMax> <yMax> <zMax> );
blocks   ( hex ( <nx> <ny> <nz> ) );
DICT

    printf 'FoamFile { object snappyHexMeshDict; }\nsnap <snap_ctrl>;\n' \
        > "${flow}/system/snappyHexMeshDict"
    printf 'solid f18p2\nendsolid f18p2\n' > "${flow}/constant/triSurface/f18p2_all.stl"

    mkdir -p "${transport}/0" "${transport}/system"
    printf 'FoamFile { object T; }\n' > "${transport}/0/T"
    printf 'FoamFile { object controlDict; }\napplication scalarTransportDeffFoam;\n' \
        > "${transport}/system/controlDict"

    : "$root"
}

# make_setup_command_stubs <workspace> - the OpenFOAM commands that the setup
# stage runner requires. The stubs give the exact log text that the stage runner
# parses. The stubs never need an OpenFOAM installation.
make_setup_command_stubs() {
    local bin_dir="${1}/_setup_bin"
    mkdir -p "$bin_dir"

    cat > "${bin_dir}/surfaceTransformPoints" <<'STUB'
#!/usr/bin/env bash
echo "Set centre of rotation to (100 200 0)"
exit 0
STUB

    cat > "${bin_dir}/surfaceCheck" <<'STUB'
#!/usr/bin/env bash
echo "Overall bounds (0 0 0) (10 10 10)"
exit 0
STUB

    cat > "${bin_dir}/foamDictionary" <<'STUB'
#!/usr/bin/env bash
entry=""; file=""; previous=""
for arg in "$@"; do
    case "$previous" in
        -entry) entry="$arg" ;;
        -value) file="$arg" ;;
    esac
    previous="$arg"
done
if [[ -n "$file" && -f "$file" ]]; then
    awk -v key="${entry##*.}" '
        $1 == key {
            line = $0
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
            gsub(/;/, "", line)
            print line
            exit
        }' "$file"
fi
exit 0
STUB

    chmod +x "${bin_dir}/surfaceTransformPoints" "${bin_dir}/surfaceCheck" \
        "${bin_dir}/foamDictionary"
    setup_path="${bin_dir}:${PATH}"
}

workspace="$(new_workspace setup_mixed_real)"
make_setup_bases "$workspace"
make_setup_command_stubs "$workspace"
write_setup_csv "${workspace}/output_batch_1.csv" \
    "good_1,3.5,270.0" \
    "bad_1,not_a_number,90.0"

out="$(cd "$workspace" && PATH="$setup_path" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

summary="${workspace}/setup_cases_summary.csv"

assert_failure "$status" \
    "a failed row must make a mixed non-dry-run setup invocation non-zero"
assert_eq 1 "$(summary_status_count "$summary" failed 9)" \
    "the mixed non-dry-run invocation records the failed row"
assert_eq 2 "$(summary_status_count "$summary" created 9)" \
    "the successful row keeps its flow and transport summary records"

# The successful row keeps its Case output artifacts.
assert_dir_exists "${workspace}/case_good_1/flow" \
    "the successful row keeps its flow Case directory"
assert_file_exists "${workspace}/case_good_1/flow/doe_row.csv" \
    "the successful row keeps its flow doe_row.csv"
assert_file_exists "${workspace}/case_good_1/flow/setup_metadata.env" \
    "the successful row keeps its flow setup metadata"
assert_file_exists "${workspace}/case_good_1/flow/0/U" \
    "the successful row keeps its prepared flow field"
assert_dir_exists "${workspace}/case_good_1/trd" \
    "the successful row keeps its transport Case directory"
assert_file_exists "${workspace}/case_good_1/trd/doe_row.csv" \
    "the successful row keeps its transport doe_row.csv"
assert_file_exists "${workspace}/case_good_1/trd/setup_metadata.env" \
    "the successful row keeps its transport setup metadata"
assert_file_exists "${workspace}/_setup_logs/case_good_1.log" \
    "the successful row keeps its case log"

# The failed row leaves the failure signals.
assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,3" \
    "the failed row of the mixed invocation reaches the failure artifact"
assert_dir_missing "${workspace}/case_bad_1" \
    "the failed row creates no Case directory"

# ---- top level: a failed setup row marks the batch failed (Issue #24) ------------

# build_setup_batches <name> - two batches that use the real setup stage runner
# and a mesh stage stub. Batch 1 holds one invalid row. Batch 2 is empty.
build_setup_batches() {
    workspace="$(new_workspace "$1")"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    cp -f -- "$SETUP_SCRIPT" "${master}/setup_cases.sh"
    cp -f -- "${MASTER_SRC_DIR}/lib_batch_stage.sh" "${master}/lib_batch_stage.sh"
    mkdir -p "${master}/simpleFoam_files" "${master}/scalarTransportDeffFoam_files"
    mkdir -p "$output" "${workspace}/_setup_bin"

    local command_name
    for command_name in surfaceCheck surfaceTransformPoints foamDictionary; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "${workspace}/_setup_bin/${command_name}"
        chmod +x "${workspace}/_setup_bin/${command_name}"
    done
    setup_path="${workspace}/_setup_bin:${PATH}"

    write_setup_csv "${workspace}/output_batch_1.csv" "bad_1,not_a_number,270.0"
    write_setup_csv "${workspace}/output_batch_2.csv"
}

build_setup_batches setupfail_stopfirst

out="$(cd "$workspace" && PATH="$setup_path" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed setup row must fail the top-level run"
assert_contains "$out" "Stage failed  : setup_cases.sh" "the failed setup stage is named"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"
assert_contains "$out" "Stop after first failed batch" \
    "the run stops before launching more batches"
assert_file_exists "${output}/batch_1/.setup_cases_failed" \
    "the batch workspace keeps the setup failure artifact"

if stub_ran mesh 1; then
    _fail "mesh must not start after a failed setup stage in the same batch"
fi
if stub_ran mesh 2; then
    _fail "batch_2 must not start without --keep-going"
fi

# --keep-going attempts the later batch and keeps the final status non-zero.

build_setup_batches setupfail_keepgoing

out="$(cd "$workspace" && PATH="$setup_path" bash "$RUN_BATCH" --stage setup,mesh \
        --keep-going -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--keep-going must still report a final failure"
assert_contains "$out" "1 batch(es) failed." "the final report counts the setup failure"
stub_ran mesh 2 || _fail "--keep-going attempts batch_2 after a failed setup batch"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "a failed setup batch must not report overall success"

# ---- top level: a mesh command failure marks the batch failed (Issue #9) ---------

workspace="$(new_workspace meshfail_top)"
install_fakes "$workspace"
assert_fakes_active
output="${workspace}/out"
mkdir -p "${output}/batch_1"
make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"
make_flow_case "${output}/batch_1/case_0/flow" 2

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="snappyHexMesh" \
        bash "$RUN_BATCH" --stage mesh -m "$MASTER_SRC_DIR" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a mesh command failure must fail the top-level run"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the top level names the failed mesh stage"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"

# ---- stage level: a non-zero summary lock release fails the Stage (Issue #47) ----
#
# A test-local rmdir wrapper delegates the exact summary lock removal to the
# real rmdir and then returns control status 23. The append therefore succeeds
# and the lock release reports a non-zero status. This regression holds the
# current behavior: the summary append path must not replace a non-zero release
# status with append status 0.

# make_lock_release_control <workspace> <summary-lock-path>
# The helper sets release_control_bin and release_control_record.
make_lock_release_control() {
    local ws="$1" lock="$2"
    local bin="${ws}/_release_bin" dir="${ws}/_release_control" real_rmdir
    mkdir -p "$bin" "$dir"

    # Resolve the real rmdir before the wrapper directory enters PATH.
    real_rmdir="$(command -v rmdir)"
    assert_ne "${bin}/rmdir" "$real_rmdir" \
        "the lock-release control resolves the real rmdir first"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'control_lock=%q\n' "$lock"
        printf 'control_dir=%q\n' "$dir"
        printf 'real_rmdir=%q\n' "$real_rmdir"
        cat <<'WRAPPER'
# Only the exact summary lock path activates the control, and only once. Every
# other call and argument vector reaches the real rmdir unchanged.
if [[ "$1" == "$control_lock" ]] && mkdir "${control_dir}/once" 2>/dev/null; then
    "$real_rmdir" "$@"
    delegated=$?
    removed=1
    if [[ -e "$control_lock" ]]; then
        removed=0
    fi
    printf 'activated=1\ndelegated=%s\nremoved=%s\nreturned=23\n' \
        "$delegated" "$removed" > "${control_dir}/record"
    exit 23
fi
exec "$real_rmdir" "$@"
WRAPPER
    } > "${bin}/rmdir"
    chmod +x "${bin}/rmdir"

    release_control_bin="$bin"
    release_control_record="${dir}/record"
}

# assert_lock_release_control <label>
assert_lock_release_control() {
    assert_file_exists "$release_control_record" \
        "${1}: the lock-release control ran for the exact summary lock"
    assert_eq "activated=1
delegated=0
removed=1
returned=23" "$(cat "$release_control_record")" \
        "${1}: the real rmdir removed the exact summary lock before status 23"
}

# ---- mesh ----
make_mesh_fixture release_mesh
make_lock_release_control "$workspace" "${workspace}/run_mesh_cases_summary.csv.lockdir"
release_saved_path="$PATH"
PATH="${release_control_bin}:${PATH}"
out="$(cd "$workspace" && timeout 120 bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?
PATH="$release_saved_path"

assert_lock_release_control "mesh"
assert_ne 124 "$status" "the mesh lock-release run completes without an external kill"
assert_failure "$status" "a non-zero mesh summary lock release fails the Stage"
assert_not_contains "$out" "All mesh jobs finished." \
    "the mesh Stage does not report success after a non-zero lock release"
assert_contains "$out" "One or more mesh jobs failed." \
    "the mesh Stage keeps its existing failure message"
assert_eq 1 "$(summary_status_count "${workspace}/run_mesh_cases_summary.csv" meshed)" \
    "the successful mesh summary row stays present"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the mesh lock-release run leaves no lock directory"
assert_file_exists "${workspace}/case_0/flow/restart.marker" \
    "completed mesh Case work stays present"

# ---- flow ----
make_flow_fixture release_flow yes
make_lock_release_control "$workspace" "${workspace}/run_flow_cases_summary.csv.lockdir"
release_saved_path="$PATH"
PATH="${release_control_bin}:${PATH}"
out="$(cd "$workspace" && timeout 120 bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?
PATH="$release_saved_path"

assert_lock_release_control "flow"
assert_ne 124 "$status" "the flow lock-release run completes without an external kill"
assert_failure "$status" "a non-zero flow summary lock release fails the Stage"
assert_not_contains "$out" "All flow jobs finished." \
    "the flow Stage does not report success after a non-zero lock release"
assert_contains "$out" "One or more flow jobs failed." \
    "the flow Stage keeps its existing failure message"
assert_eq 1 "$(summary_status_count "${workspace}/run_flow_cases_summary.csv" solved)" \
    "the successful flow summary row stays present"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the flow lock-release run leaves no lock directory"
assert_file_exists "${workspace}/case_0/flow/flow.marker" \
    "completed flow Case work stays present"

# ---- transport ----
# make_transport_success_fixture <name> - one solvable transport Case.
make_transport_success_fixture() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
    make_flow_mesh "${workspace}/case_0/flow"
    make_flow_result "${workspace}/case_0/flow" 3000
    make_transport_case "${workspace}/case_0/trd" 2 T 300
}

make_transport_success_fixture release_transport
make_lock_release_control "$workspace" "${workspace}/run_transport_cases_summary.csv.lockdir"
release_saved_path="$PATH"
PATH="${release_control_bin}:${PATH}"
out="$(cd "$workspace" && timeout 120 bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" && status=0 || status=$?
PATH="$release_saved_path"

assert_lock_release_control "transport"
assert_ne 124 "$status" "the transport lock-release run completes without an external kill"
assert_failure "$status" "a non-zero transport summary lock release fails the Stage"
assert_not_contains "$out" "All transport jobs finished." \
    "the transport Stage does not report success after a non-zero lock release"
assert_contains "$out" "One or more transport jobs failed." \
    "the transport Stage keeps its existing failure message"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" solved)" \
    "the successful transport summary row stays present"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the transport lock-release run leaves no lock directory"
assert_file_exists "${workspace}/case_0/trd/transport.marker" \
    "completed transport Case work stays present"

# ---- stage level: a failed summary row append fails the Stage (Issue #47) ----
#
# The control replaces the initialized summary with a symbolic link to
# /proc/version after the last required Case command and before the Case result
# append. /proc/version is readable and finite, it reports size zero, and it
# rejects an append, so the append fails promptly and a later summary reader
# neither hangs nor fails.

assert_file_exists /proc/version "the append control target exists"
assert_eq 0 "$(stat -c '%s' /proc/version)" \
    "the append control target reports file size zero"
assert_ne 0 "$(wc -c < /proc/version)" \
    "the append control target has a finite non-empty read"
control_probe="$( ( LC_ALL=C printf 'x' >> /proc/version ) 2>&1 )" \
    && control_probe_status=0 || control_probe_status=$?
assert_ne 0 "$control_probe_status" "the append control target rejects an append"
assert_contains "$control_probe" "Permission denied" \
    "the append control target gives the selected LC_ALL=C append diagnostic"

# make_append_failure_control <workspace> <command> <summary> [<failure-artifact>]
# The helper sets append_control_bin, append_control_dir, and
# append_control_marker.
make_append_failure_control() {
    local ws="$1" command_name="$2" summary="$3" fail_file="${4:-}"
    local bin="${ws}/_append_bin" dir="${ws}/_append_control" real_command
    mkdir -p "$bin" "$dir"

    real_command="$(command -v "$command_name")"
    assert_eq "${FAKE_BIN_DIR}/${command_name}" "$real_command" \
        "the append control delegates to the fake ${command_name}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'control_dir=%q\n' "$dir"
        printf 'control_summary=%q\n' "$summary"
        printf 'control_fail_file=%q\n' "$fail_file"
        printf 'real_command=%q\n' "$real_command"
        cat <<'WRAPPER'
# The control runs exactly once, after the last required Case command and
# before the Case result append.
if mkdir "${control_dir}/once" 2>/dev/null; then
    if [[ -f "$control_summary" ]]; then
        mv -- "$control_summary" "${control_dir}/summary_before_append.csv"
        ln -s /proc/version "$control_summary"
        printf 'summary=1\n' >> "${control_dir}/marker"
    fi
    if [[ -n "$control_fail_file" && -f "$control_fail_file" ]]; then
        mv -- "$control_fail_file" "${control_dir}/fail_before_append"
        ln -s /proc/version "$control_fail_file"
        printf 'fail_file=1\n' >> "${control_dir}/marker"
    fi
fi
exec "$real_command" "$@"
WRAPPER
    } > "${bin}/${command_name}"
    chmod +x "${bin}/${command_name}"

    append_control_bin="$bin"
    append_control_dir="$dir"
    append_control_marker="${dir}/marker"
}

# ---- mesh: the summary append fails ----
make_mesh_fixture append_mesh
make_append_failure_control "$workspace" checkMesh \
    "${workspace}/run_mesh_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
assert_eq "${append_control_bin}/checkMesh" "$(command -v checkMesh)" \
    "the mesh append control resolves before the fake checkMesh"
out="$(cd "$workspace" && LC_ALL=C timeout 120 bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n' \
    "the mesh append control ran exactly once"
assert_ne 124 "$status" "the mesh append-failure run completes without an external kill"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n' \
    "the mesh summary evidence keeps its exact header bytes"
assert_eq "/proc/version" "$(readlink "${workspace}/run_mesh_cases_summary.csv")" \
    "the mesh summary path is the control symbolic link"
mesh_case_log="$(case_log "$workspace" _mesh_logs case_0_flow)"
assert_contains "$mesh_case_log" "run_mesh_cases_summary.csv" \
    "the mesh Case log names the summary path"
assert_contains "$mesh_case_log" "Permission denied" \
    "the mesh Case log keeps the append failure diagnostic"
assert_failure "$status" "a failed mesh summary row append fails the mesh Stage"
assert_contains "$out" "One or more mesh jobs failed." \
    "the mesh Stage keeps its existing failure message"
assert_not_contains "$out" "All mesh jobs finished." \
    "the mesh Stage does not report success after a failed append"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the mesh append-failure run leaves no lock directory"
assert_contains "$(cat "${workspace}/.run_mesh_cases_failed")" "case_0/flow" \
    "the mesh Failure Artifact identifies the affected Case"
assert_file_exists "${workspace}/case_0/flow/restart.marker" \
    "completed mesh Case work stays present after a failed append"
assert_ne 0 "$(fake_call_count checkMesh)" \
    "the command record proves that mesh Case work completed"

# ---- flow: the summary append fails ----
make_flow_fixture append_flow yes
make_append_failure_control "$workspace" reconstructPar \
    "${workspace}/run_flow_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
assert_eq "${append_control_bin}/reconstructPar" "$(command -v reconstructPar)" \
    "the flow append control resolves before the fake reconstructPar"
out="$(cd "$workspace" && LC_ALL=C timeout 120 bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n' \
    "the flow append control ran exactly once"
assert_ne 124 "$status" "the flow append-failure run completes without an external kill"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n' \
    "the flow summary evidence keeps its exact header bytes"
assert_eq "/proc/version" "$(readlink "${workspace}/run_flow_cases_summary.csv")" \
    "the flow summary path is the control symbolic link"
flow_case_log="$(case_log "$workspace" _flow_logs case_0_flow)"
assert_contains "$flow_case_log" "run_flow_cases_summary.csv" \
    "the flow Case log names the summary path"
assert_contains "$flow_case_log" "Permission denied" \
    "the flow Case log keeps the append failure diagnostic"
assert_failure "$status" "a failed flow summary row append fails the flow Stage"
assert_contains "$out" "One or more flow jobs failed." \
    "the flow Stage keeps its existing failure message"
assert_not_contains "$out" "All flow jobs finished." \
    "the flow Stage does not report success after a failed append"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the flow append-failure run leaves no lock directory"
assert_contains "$(cat "${workspace}/.run_flow_cases_failed")" "case_0/flow" \
    "the flow Failure Artifact identifies the affected Case"
assert_file_exists "${workspace}/case_0/flow/flow.marker" \
    "completed flow Case work stays present after a failed append"
assert_ne 0 "$(fake_call_count reconstructPar)" \
    "the command record proves that flow Case work completed"

# ---- transport: the summary append fails ----
make_transport_success_fixture append_transport
make_append_failure_control "$workspace" reconstructPar \
    "${workspace}/run_transport_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
assert_eq "${append_control_bin}/reconstructPar" "$(command -v reconstructPar)" \
    "the transport append control resolves before the fake reconstructPar"
out="$(cd "$workspace" && LC_ALL=C timeout 120 bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n' \
    "the transport append control ran exactly once"
assert_ne 124 "$status" \
    "the transport append-failure run completes without an external kill"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n' \
    "the transport summary evidence keeps its exact header bytes"
assert_eq "/proc/version" \
    "$(readlink "${workspace}/run_transport_cases_summary.csv")" \
    "the transport summary path is the control symbolic link"
transport_case_log="$(case_log "$workspace" _transport_logs case_0_trd)"
assert_contains "$transport_case_log" "run_transport_cases_summary.csv" \
    "the transport Case log names the summary path"
assert_contains "$transport_case_log" "Permission denied" \
    "the transport Case log keeps the append failure diagnostic"
assert_failure "$status" \
    "a failed transport summary row append fails the transport Stage"
assert_contains "$out" "One or more transport jobs failed." \
    "the transport Stage keeps its existing failure message"
assert_not_contains "$out" "All transport jobs finished." \
    "the transport Stage does not report success after a failed append"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the transport append-failure run leaves no lock directory"
assert_contains "$(cat "${workspace}/.run_transport_cases_failed")" "case_0/trd" \
    "the transport Failure Artifact identifies the affected Case"
assert_file_exists "${workspace}/case_0/trd/transport.marker" \
    "completed transport Case work stays present after a failed append"
assert_eq 1 "$(fake_call_count reconstructPar)" \
    "the selected transport control command runs exactly once"

# ---- Orchestrator: a failed summary append fails the batch (Issue #47) ------

# build_orchestrated_stage <name> <stage-runner-path> <runner-file-name>
# The helper sets workspace, master, output, and the Batch Workspace layout.
build_orchestrated_stage() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    cp -f -- "$2" "${master}/${3}"
    cp -f -- "${MASTER_SRC_DIR}/lib_batch_stage.sh" "${master}/lib_batch_stage.sh"
    mkdir -p "$output" "${output}/batch_1"
    make_csv "${workspace}/output_batch_1.csv" 0
    cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"
}

# ---- Orchestrator: mesh ----
build_orchestrated_stage orch_mesh "$MESH_SCRIPT" run_mesh_cases.sh
make_flow_case "${output}/batch_1/case_0/flow" 2
make_append_failure_control "$workspace" checkMesh \
    "${output}/batch_1/run_mesh_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C timeout 180 bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
PATH="$append_saved_path"

assert_ne 124 "$status" "the orchestrated mesh run completes without an external kill"
assert_failure "$status" "a failed mesh summary append fails the orchestrated run"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the Orchestrator names the failed mesh Stage"
assert_contains "$out" "Batch failed: batch_1" \
    "the Orchestrator marks the batch failed after a failed mesh append"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "the Orchestrator does not report overall success"

# ---- Orchestrator: flow ----
build_orchestrated_stage orch_flow "$FLOW_SCRIPT" run_flow_cases.sh
make_flow_case "${output}/batch_1/case_0/flow" 2
make_flow_mesh "${output}/batch_1/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' \
    > "${output}/batch_1/case_0/flow/0/wallDistance"
make_append_failure_control "$workspace" reconstructPar \
    "${output}/batch_1/run_flow_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C timeout 180 bash "$RUN_BATCH" --stage flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
PATH="$append_saved_path"

assert_ne 124 "$status" "the orchestrated flow run completes without an external kill"
assert_failure "$status" "a failed flow summary append fails the orchestrated run"
assert_contains "$out" "Stage failed  : run_flow_cases.sh" \
    "the Orchestrator names the failed flow Stage"
assert_contains "$out" "Batch failed: batch_1" \
    "the Orchestrator marks the batch failed after a failed flow append"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "the Orchestrator does not report overall success after a flow append failure"

# ---- Orchestrator: transport ----
build_orchestrated_stage orch_transport "$TRANSPORT_SCRIPT" run_transport_cases.sh
make_flow_case "${output}/batch_1/case_0/flow" 2
make_flow_mesh "${output}/batch_1/case_0/flow"
make_flow_result "${output}/batch_1/case_0/flow" 3000
make_transport_case "${output}/batch_1/case_0/trd" 2 T 300
make_append_failure_control "$workspace" reconstructPar \
    "${output}/batch_1/run_transport_cases_summary.csv"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C timeout 180 bash "$RUN_BATCH" --stage transport \
        --save-times 300 -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
PATH="$append_saved_path"

assert_ne 124 "$status" \
    "the orchestrated transport run completes without an external kill"
assert_failure "$status" "a failed transport summary append fails the orchestrated run"
assert_contains "$out" "Stage failed  : run_transport_cases.sh" \
    "the Orchestrator names the failed transport Stage"
assert_contains "$out" "Batch failed: batch_1" \
    "the Orchestrator marks the batch failed after a failed transport append"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "the Orchestrator does not report overall success after a transport append failure"

# ---- both the summary and the Failure Artifact append fail (Issue #47) ------
#
# Neither the summary nor the Failure Artifact can record the failure. Only the
# private Case completion record keeps the Stage result non-zero. Each run uses
# a test-local TMPDIR, so the scenario can prove that the private accounting
# directory is removed.

# assert_private_accounting_removed <tmpdir> <label>
assert_private_accounting_removed() {
    assert_dir_exists "$1" "${2}: the test-local TMPDIR exists"
    assert_eq "" "$(find "$1" -mindepth 1 | sort | tr '\n' ' ')" \
        "${2}: the private accounting directory is removed"
}

# ---- mesh dual failure ----
make_mesh_fixture dual_mesh
dual_tmpdir="${workspace}/_tmp"
mkdir -p "$dual_tmpdir"
make_append_failure_control "$workspace" checkMesh \
    "${workspace}/run_mesh_cases_summary.csv" "${workspace}/.run_mesh_cases_failed"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$dual_tmpdir" timeout 120 \
        bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n'"fail_file=1"$'\n' \
    "the mesh dual control replaced both artifacts exactly once"
assert_ne 124 "$status" "the mesh dual-failure run completes without an external kill"
assert_failure "$status" \
    "the private mesh Case completion record alone keeps the Stage non-zero"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n' \
    "the mesh summary evidence keeps its exact header bytes"
assert_file_bytes_exact "${append_control_dir}/fail_before_append" "" \
    "the mesh Failure Artifact evidence keeps its exact pre-append bytes"
assert_eq "/proc/version" "$(readlink "${workspace}/run_mesh_cases_summary.csv")" \
    "no failed mesh summary row is available to the final gate"
assert_eq "/proc/version" "$(readlink "${workspace}/.run_mesh_cases_failed")" \
    "no mesh Failure Artifact record is available to the final gate"
assert_contains "$(case_log "$workspace" _mesh_logs case_0_flow)" "Permission denied" \
    "the mesh Case log keeps the summary append diagnostic"
assert_contains "$out" "Permission denied" \
    "the mesh Stage output keeps the Failure Artifact append diagnostic"
assert_contains "$out" "One or more mesh jobs failed." \
    "the mesh dual-failure run keeps its existing failure message"
assert_not_contains "$out" "All mesh jobs finished." \
    "the mesh dual-failure run does not report success"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the mesh dual-failure run leaves no lock directory"
assert_private_accounting_removed "$dual_tmpdir" "mesh"

# ---- flow dual failure ----
make_flow_fixture dual_flow yes
dual_tmpdir="${workspace}/_tmp"
mkdir -p "$dual_tmpdir"
make_append_failure_control "$workspace" reconstructPar \
    "${workspace}/run_flow_cases_summary.csv" "${workspace}/.run_flow_cases_failed"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$dual_tmpdir" timeout 120 \
        bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n'"fail_file=1"$'\n' \
    "the flow dual control replaced both artifacts exactly once"
assert_ne 124 "$status" "the flow dual-failure run completes without an external kill"
assert_failure "$status" \
    "the private flow Case completion record alone keeps the Stage non-zero"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n' \
    "the flow summary evidence keeps its exact header bytes"
assert_file_bytes_exact "${append_control_dir}/fail_before_append" "" \
    "the flow Failure Artifact evidence keeps its exact pre-append bytes"
assert_eq "/proc/version" "$(readlink "${workspace}/run_flow_cases_summary.csv")" \
    "no failed flow summary row is available to the final gate"
assert_eq "/proc/version" "$(readlink "${workspace}/.run_flow_cases_failed")" \
    "no flow Failure Artifact record is available to the final gate"
assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" "Permission denied" \
    "the flow Case log keeps the summary append diagnostic"
assert_contains "$out" "Permission denied" \
    "the flow Stage output keeps the Failure Artifact append diagnostic"
assert_contains "$out" "One or more flow jobs failed." \
    "the flow dual-failure run keeps its existing failure message"
assert_not_contains "$out" "All flow jobs finished." \
    "the flow dual-failure run does not report success"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the flow dual-failure run leaves no lock directory"
assert_private_accounting_removed "$dual_tmpdir" "flow"

# ---- transport dual failure ----
make_transport_success_fixture dual_transport
dual_tmpdir="${workspace}/_tmp"
mkdir -p "$dual_tmpdir"
make_append_failure_control "$workspace" reconstructPar \
    "${workspace}/run_transport_cases_summary.csv" \
    "${workspace}/.run_transport_cases_failed"
append_saved_path="$PATH"
PATH="${append_control_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$dual_tmpdir" timeout 120 \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" \
    && status=0 || status=$?
PATH="$append_saved_path"

assert_file_bytes_exact "$append_control_marker" "summary=1"$'\n'"fail_file=1"$'\n' \
    "the transport dual control replaced both artifacts exactly once"
assert_ne 124 "$status" \
    "the transport dual-failure run completes without an external kill"
assert_failure "$status" \
    "the private transport Case completion record alone keeps the Stage non-zero"
assert_file_bytes_exact "${append_control_dir}/summary_before_append.csv" \
    "csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n' \
    "the transport summary evidence keeps its exact header bytes"
assert_file_bytes_exact "${append_control_dir}/fail_before_append" "" \
    "the transport Failure Artifact evidence keeps its exact pre-append bytes"
assert_eq "/proc/version" \
    "$(readlink "${workspace}/run_transport_cases_summary.csv")" \
    "no failed transport summary row is available to the final gate"
assert_eq "/proc/version" \
    "$(readlink "${workspace}/.run_transport_cases_failed")" \
    "no transport Failure Artifact record is available to the final gate"
assert_contains "$(case_log "$workspace" _transport_logs case_0_trd)" "Permission denied" \
    "the transport Case log keeps the summary append diagnostic"
assert_contains "$out" "Permission denied" \
    "the transport Stage output keeps the Failure Artifact append diagnostic"
assert_contains "$out" "One or more transport jobs failed." \
    "the transport dual-failure run keeps its existing failure message"
assert_not_contains "$out" "All transport jobs finished." \
    "the transport dual-failure run does not report success"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the transport dual-failure run leaves no lock directory"
assert_private_accounting_removed "$dual_tmpdir" "transport"

# ---- the same fixtures without a failure control (Issue #47) ---------------
#
# The correction must keep the exact current successful behavior.

# ---- mesh success ----
make_mesh_fixture success_mesh
success_tmpdir="${workspace}/_tmp"
mkdir -p "$success_tmpdir"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$success_tmpdir" timeout 120 \
        bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the uncontrolled mesh run keeps exit status 0"
assert_file_bytes_exact "${workspace}/run_mesh_cases_summary.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'"\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow\",\"${workspace}/case_0/flow\",\"meshed\",\"OK\""$'\n' \
    "the uncontrolled mesh summary"
assert_contains "$out" "All mesh jobs finished." \
    "the uncontrolled mesh run keeps its success message"
assert_file_missing "${workspace}/.run_mesh_cases_failed" \
    "the uncontrolled mesh run leaves no Failure Artifact"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the uncontrolled mesh run leaves no lock directory"
assert_file_exists "${workspace}/case_0/flow/restart.marker" \
    "the uncontrolled mesh run keeps its Case artifacts"
assert_private_accounting_removed "$success_tmpdir" "uncontrolled mesh"

# ---- flow success ----
make_flow_fixture success_flow yes
success_tmpdir="${workspace}/_tmp"
mkdir -p "$success_tmpdir"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$success_tmpdir" timeout 120 \
        bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the uncontrolled flow run keeps exit status 0"
assert_file_bytes_exact "${workspace}/run_flow_cases_summary.csv" \
    "csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'"\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow\",\"${workspace}/case_0/flow\",\"solved\",\"OK\""$'\n' \
    "the uncontrolled flow summary"
assert_contains "$out" "All flow jobs finished." \
    "the uncontrolled flow run keeps its success message"
assert_file_missing "${workspace}/.run_flow_cases_failed" \
    "the uncontrolled flow run leaves no Failure Artifact"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the uncontrolled flow run leaves no lock directory"
assert_file_exists "${workspace}/case_0/flow/flow.marker" \
    "the uncontrolled flow run keeps its Case artifacts"
assert_private_accounting_removed "$success_tmpdir" "uncontrolled flow"

# ---- transport success ----
make_transport_success_fixture success_transport
success_tmpdir="${workspace}/_tmp"
mkdir -p "$success_tmpdir"
out="$(cd "$workspace" && LC_ALL=C TMPDIR="$success_tmpdir" timeout 120 \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the uncontrolled transport run keeps exit status 0"
assert_file_bytes_exact "${workspace}/run_transport_cases_summary.csv" \
    "csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n'"\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow|case_0/trd\",\"${workspace}/case_0/trd\",\"solved\",\"OK\""$'\n' \
    "the uncontrolled transport summary"
assert_contains "$out" "All transport jobs finished." \
    "the uncontrolled transport run keeps its success message"
assert_file_missing "${workspace}/.run_transport_cases_failed" \
    "the uncontrolled transport run leaves no Failure Artifact"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the uncontrolled transport run leaves no lock directory"
assert_file_exists "${workspace}/case_0/trd/transport.marker" \
    "the uncontrolled transport run keeps its Case artifacts"
assert_private_accounting_removed "$success_tmpdir" "uncontrolled transport"
