#!/usr/bin/env bash
# Section 23.AC - flow-only post-processing readiness (Issue #83).
#
# Transport conversion is required only for a prepared transport subcase. The
# subcase is prepared when case_<Case>/trd/constant/polyMesh exists. Flow
# conversion stays required for every Case.
#
# Every observation uses the direct post-processing Stage Runner CLI, the
# process status, the console output, the exact summary bytes, the completion
# marker, the Batch Workspace file tree, and the recorded foamToVTK argument
# vectors. No observation calls a private production helper.
#
# Every expected value is an independent literal from Specification Section 18
# and Section 23.AC. No expected value comes from Stage Runner output.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# The fake commands join each recorded argument with this separator.
US=$'\x1f'

# ---- exact contract literals -------------------------------------------------

COMPLETED_FLOW_ONLY='flow VTU files created; transport conversion skipped because the transport subcase is not prepared'
SKIPPED_FLOW_ONLY='flow VTU files reused; transport conversion skipped because the transport subcase is not prepared'
CONSOLE_SKIP='transport conversion skipped because the transport subcase is not prepared'
COMPLETED_PREPARED='flow and transport VTU files created'
SKIPPED_PREPARED='source results unchanged; existing VTU outputs reused'
SUMMARY_HEADER='case_id,case_dir,status,message'

# ---- fixtures ----------------------------------------------------------------

# new_post_workspace <name> - one Batch Workspace with one flow Case that holds
# time 0 and a converged time 3000. The transport subcase is absent.
new_post_workspace() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    flow_dir="${workspace}/case_0/flow"
    trd_dir="${workspace}/case_0/trd"
    vtk_dir="${workspace}/case_0/vtk"
    marker="${vtk_dir}/post_processing.complete"
    summary="${workspace}/run_post_processing_cases_summary.csv"
    fail_file="${workspace}/.run_post_processing_cases_failed"
    make_flow_case "$flow_dir" 2
    make_flow_result "$flow_dir" 3000
}

# run_post [VAR=value ...] - run the Stage Runner in the current workspace.
run_post() {
    ( cd "$workspace" && env "$@" bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
}

# ---- record queries ----------------------------------------------------------

# summary_row <status> <message> - the exact expected data row for case_0.
summary_row() {
    printf '"case_0","%s","%s","%s"' "${workspace}/case_0" "$1" "$2"
}

# assert_summary_bytes <status> <message> <label> - the summary holds exactly
# the header and one row. One literal X keeps the final newline significant.
assert_summary_bytes() {
    local expected
    expected="${SUMMARY_HEADER}"$'\n'"$(summary_row "$1" "$2")"$'\n'
    assert_file_exists "$summary" "${3}: the summary exists"
    assert_eq "${expected}X" "$(cat -- "$summary"; printf X)" \
        "${3}: the summary holds the exact expected bytes"
}

# signature_value <key> - the value of one completion-marker line.
signature_value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
        "$marker"
}

# signature_line_number <key> - the marker line that holds <key>.
signature_line_number() {
    awk -F= -v key="$1" '$1 == key { print NR; exit }' "$marker"
}

# trd_vtu_count - transport VTU files in the vtk directory.
trd_vtu_count() {
    find "$vtk_dir" -maxdepth 1 -type f -name 'trd_*.vtu' 2>/dev/null | wc -l
}

# argv_count_with <token> - recorded foamToVTK calls that hold <token>.
argv_count_with() {
    fake_argvs foamToVTK | awk -v want="$1" -v sep="$US" '
        {
            n = split($0, a, sep)
            for (i = 1; i <= n; i++) {
                if (a[i] == want) { count++; break }
            }
        }
        END { print count + 0 }'
}

# argv_fields_count <list> - recorded foamToVTK calls whose -fields value is
# the exact string <list>.
argv_fields_count() {
    fake_argvs foamToVTK | awk -v want="$1" -v sep="$US" '
        {
            n = split($0, a, sep)
            for (i = 1; i < n; i++) {
                if (a[i] == "-fields" && a[i + 1] == want) { count++; break }
            }
        }
        END { print count + 0 }'
}

# assert_flow_only_completed <label> <status> <out> - the complete flow-only
# rebuild result of Section 23.AC observations 1, 2, 4, and 7.
assert_flow_only_completed() {
    local label="$1" status="$2" out="$3"

    assert_status 0 "$status" "${label}: the Stage returns status 0: $out"
    assert_eq 2 "$(fake_call_count foamToVTK)" \
        "${label}: the run makes exactly the two required flow conversions"
    assert_file_exists "${vtk_dir}/flow_0.vtu" "${label}: flow_0.vtu exists"
    assert_file_exists "${vtk_dir}/flow_latest_3000.vtu" \
        "${label}: flow_latest_3000.vtu exists"
    assert_file_exists "${vtk_dir}/flow_latest_time.txt" \
        "${label}: flow_latest_time.txt exists"
    assert_eq 3000 "$(cat "${vtk_dir}/flow_latest_time.txt")" \
        "${label}: flow_latest_time.txt records the latest flow time"
    assert_eq 0 "$(trd_vtu_count)" "${label}: no transport VTU file exists"
    assert_file_missing "$fail_file" "${label}: no Failure Artifact entry exists"
    assert_file_exists "$marker" "${label}: the completion marker exists"
    assert_eq 0 "$(signature_value transport_ready)" \
        "${label}: the signature records transport_ready=0"
    assert_eq "" "$(signature_value transport_times)" \
        "${label}: the signature records an empty transport-time list"
    assert_eq 1 "$(( $(signature_line_number transport_ready) < $(signature_line_number transport_times) ? 1 : 0 ))" \
        "${label}: the signature records transport_ready before transport_times"
    assert_summary_bytes completed "$COMPLETED_FLOW_ONLY" "$label"
    assert_contains "$out" "$CONSOLE_SKIP" \
        "${label}: the console reports the transport skip"
    assert_eq 0 "$(argv_count_with -no-point-data)" \
        "${label}: no recorded foamToVTK call passes -no-point-data"
    assert_eq 1 "$(argv_fields_count '(U p wallDistance)')" \
        "${label}: the flow zero-time field selection stays (U p wallDistance)"
    assert_eq 1 "$(argv_fields_count '(U p)')" \
        "${label}: the flow result field selection stays (U p)"
    assert_eq 0 "$(argv_fields_count '(T)')" \
        "${label}: no transport field selection is requested"
}

# ---- observation 1: an absent transport subcase gives a flow-only result -----

new_post_workspace absent_trd
assert_dir_missing "$trd_dir" "observation 1: the transport subcase is absent"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_flow_only_completed "observation 1" "$status" "$out"

# ---- observation 2: a present trd/ without constant/polyMesh is not prepared --
#
# This Batch Workspace then moves through observations 3 to 7 in order.

new_post_workspace unprepared_trd
make_transport_case "$trd_dir" 2 T 300
mkdir -p "${trd_dir}/300"
printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"
assert_dir_exists "${trd_dir}/0" "observation 2: the transport subcase holds time 0"
assert_dir_missing "${trd_dir}/constant/polyMesh" \
    "observation 2: the transport subcase has no constant/polyMesh"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_flow_only_completed "observation 2" "$status" "$out"

# ---- observation 3: a second unchanged flow-only run reuses the outputs ------

signature_before="$(cat "$marker")"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 3: the Stage returns status 0: $out"
assert_summary_bytes skipped "$SKIPPED_FLOW_ONLY" "observation 3"
assert_eq 0 "$(fake_call_count foamToVTK)" \
    "observation 3: the unchanged flow-only run makes no conversion"
assert_eq "$signature_before" "$(cat "$marker")" \
    "observation 3: the readiness signature is unchanged"
assert_eq 0 "$(signature_value transport_ready)" \
    "observation 3: the signature keeps transport_ready=0"
assert_file_exists "${vtk_dir}/flow_0.vtu" "observation 3: flow_0.vtu is kept"
assert_file_exists "${vtk_dir}/flow_latest_3000.vtu" \
    "observation 3: flow_latest_3000.vtu is kept"
assert_eq 0 "$(trd_vtu_count)" "observation 3: no transport VTU file exists"
assert_contains "$out" "post-processing outputs are current" \
    "observation 3: the console explains the reuse"

# ---- observation 4: FORCE_POST=1 rebuilds the current flow-only Case ---------

reset_fake_records
out="$(run_post FORCE_POST=1)" && status=0 || status=$?
assert_flow_only_completed "observation 4" "$status" "$out"

# ---- observation 5: readiness changes from 0 to 1 ---------------------------
#
# The transport Stage creates constant/polyMesh. The subcase already holds time
# 0 and time 300, so the next run converts flow time 0, flow time 3000,
# transport time 0, and transport time 300.

make_flow_mesh "$trd_dir"
assert_dir_exists "${trd_dir}/constant/polyMesh" \
    "observation 5: the transport subcase is now prepared"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 5: the Stage returns status 0: $out"
assert_summary_bytes completed "$COMPLETED_PREPARED" "observation 5"
assert_eq 4 "$(fake_call_count foamToVTK)" \
    "observation 5: the run converts the four required times"
assert_file_exists "${vtk_dir}/flow_0.vtu" "observation 5: flow_0.vtu exists"
assert_file_exists "${vtk_dir}/flow_latest_3000.vtu" \
    "observation 5: flow_latest_3000.vtu exists"
assert_file_exists "${vtk_dir}/trd_0.vtu" "observation 5: trd_0.vtu exists"
assert_file_exists "${vtk_dir}/trd_300.vtu" "observation 5: trd_300.vtu exists"
assert_eq 2 "$(trd_vtu_count)" "observation 5: exactly two transport VTU files exist"
assert_file_missing "$fail_file" "observation 5: no Failure Artifact entry exists"
assert_eq 1 "$(signature_value transport_ready)" \
    "observation 5: the signature records transport_ready=1"
assert_eq "0,300" "$(signature_value transport_times)" \
    "observation 5: the signature records the transport-time list"
assert_eq 1 "$(( $(signature_line_number transport_ready) < $(signature_line_number transport_times) ? 1 : 0 ))" \
    "observation 5: the signature records transport_ready before transport_times"
assert_not_contains "$out" "$CONSOLE_SKIP" \
    "observation 5: the console reports no transport skip"
assert_eq 2 "$(argv_fields_count '(T)')" \
    "observation 5: each transport conversion uses the SCALAR_FIELD selection (T)"

# ---- observation 6: a second unchanged prepared run keeps the prepared reuse -

signature_before="$(cat "$marker")"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 6: the Stage returns status 0: $out"
assert_summary_bytes skipped "$SKIPPED_PREPARED" "observation 6"
assert_eq 0 "$(fake_call_count foamToVTK)" \
    "observation 6: the unchanged prepared run makes no conversion"
assert_eq "$signature_before" "$(cat "$marker")" \
    "observation 6: the prepared signature is unchanged"
assert_eq 2 "$(trd_vtu_count)" "observation 6: both transport VTU files are kept"

# ---- observation 7: readiness changes from 1 to 0 ---------------------------
#
# The transport mesh disappears after a prepared successful run. The stale
# transport VTU files must not survive the flow-only rebuild.

rm -rf "${trd_dir}/constant/polyMesh"
assert_dir_missing "${trd_dir}/constant/polyMesh" \
    "observation 7: the transport subcase is no longer prepared"
assert_file_exists "${vtk_dir}/trd_0.vtu" \
    "observation 7: a stale trd_0.vtu exists before the run"
assert_file_exists "${vtk_dir}/trd_300.vtu" \
    "observation 7: a stale trd_300.vtu exists before the run"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_flow_only_completed "observation 7" "$status" "$out"
assert_file_missing "${vtk_dir}/trd_0.vtu" \
    "observation 7: the stale trd_0.vtu is removed"
assert_file_missing "${vtk_dir}/trd_300.vtu" \
    "observation 7: the stale trd_300.vtu is removed"

# ---- observation 8: a prepared subcase without trd/0 stays a Case failure ----

new_post_workspace prepared_no_time_zero
make_transport_case "$trd_dir" 2 T 300
make_flow_mesh "$trd_dir"
rm -rf "${trd_dir}/0"
mkdir -p "${trd_dir}/300"
printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"
assert_dir_exists "${trd_dir}/constant/polyMesh" \
    "observation 8: the transport subcase is prepared"
assert_dir_missing "${trd_dir}/0" "observation 8: the transport subcase has no time 0"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_failure "$status" "observation 8: the Stage returns a non-zero status"
assert_eq 2 "$(fake_call_count foamToVTK)" \
    "observation 8: the two required flow conversions run before the failure"
assert_file_exists "${vtk_dir}/flow_0.vtu" \
    "observation 8: the flow conversion completed before the failure"
assert_eq 0 "$(trd_vtu_count)" "observation 8: no transport VTU file exists"
assert_summary_bytes failed "VTU conversion failed; see ${vtk_dir}/logs" "observation 8"
assert_file_exists "$fail_file" "observation 8: the Failure Artifact exists"
assert_eq "case_0"$'\n'"X" "$(cat -- "$fail_file"; printf X)" \
    "observation 8: the Failure Artifact names the Case"
assert_file_missing "$marker" "observation 8: no completion marker is written"
assert_contains "$out" "Transport time 0 directory not found" \
    "observation 8: the console names the missing transport time"
assert_contains "$out" "One or more post-processing jobs failed" \
    "observation 8: the Stage reports the failure"
assert_not_contains "$out" "$CONSOLE_SKIP" \
    "observation 8: a prepared subcase is never reported as skipped"

# ---- observation 9: a legacy marker without transport_ready is stale --------
#
# The scenario builds the pre-change marker from a real prepared run and then
# removes the transport_ready line. The remaining file is the exact marker that
# a pre-readiness runner writes.

new_post_workspace legacy_marker
make_transport_case "$trd_dir" 2 T 300
make_flow_mesh "$trd_dir"
mkdir -p "${trd_dir}/300"
printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 9: the first prepared run returns status 0: $out"
assert_summary_bytes completed "$COMPLETED_PREPARED" "observation 9 first run"
assert_eq 1 "$(signature_value transport_ready)" \
    "observation 9: the new marker records transport_ready=1"

grep -v '^transport_ready=' "$marker" > "${marker}.legacy"
mv -f "${marker}.legacy" "$marker"
assert_not_contains "$(cat "$marker")" "transport_ready" \
    "observation 9: the test marker is now a pre-readiness marker"
assert_contains "$(cat "$marker")" "vtu_point_data=included" \
    "observation 9: the pre-readiness marker still records the point-data policy"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 9: the migration run returns status 0: $out"
assert_summary_bytes completed "$COMPLETED_PREPARED" "observation 9 migration run"
assert_eq 4 "$(fake_call_count foamToVTK)" \
    "observation 9: the migration run converts every required time again"
assert_eq 1 "$(signature_value transport_ready)" \
    "observation 9: the rebuild writes a current marker"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "observation 9: the confirming run returns status 0: $out"
assert_summary_bytes skipped "$SKIPPED_PREPARED" "observation 9 confirming run"
assert_eq 0 "$(fake_call_count foamToVTK)" \
    "observation 9: the case is current after the one rebuild"

# ---- observation 10: every argument vector keeps the point-data contract ----

reset_fake_records
out="$(run_post FORCE_POST=1)" && status=0 || status=$?
assert_status 0 "$status" "observation 10: the forced prepared run returns status 0: $out"
calls="$(fake_call_count foamToVTK)"
assert_eq 4 "$calls" "observation 10: the forced prepared run converts the four times"
assert_eq 0 "$(argv_count_with -no-point-data)" \
    "observation 10: no recorded foamToVTK call passes -no-point-data"
assert_eq "$calls" "$(argv_count_with -time)" \
    "observation 10: every recorded foamToVTK call keeps -time"
assert_eq "$calls" "$(argv_count_with -no-boundary)" \
    "observation 10: every recorded foamToVTK call keeps -no-boundary"
assert_eq "$calls" "$(argv_count_with -fields)" \
    "observation 10: every recorded foamToVTK call keeps -fields"

# ---- observation 11: the field lists stay exact -----------------------------
#
# The flow-only field lists are proved inside assert_flow_only_completed for
# observations 1, 2, 4, and 7. The prepared run adds the transport selection.

assert_eq 1 "$(argv_fields_count '(U p wallDistance)')" \
    "observation 11: the flow zero-time field selection stays (U p wallDistance)"
assert_eq 1 "$(argv_fields_count '(U p)')" \
    "observation 11: the flow result field selection stays (U p)"
assert_eq 2 "$(argv_fields_count '(T)')" \
    "observation 11: each transport conversion uses the SCALAR_FIELD selection (T)"

reset_fake_records
out="$(run_post FORCE_POST=1 SCALAR_FIELD=C)" && status=0 || status=$?
assert_status 0 "$status" "observation 11: the SCALAR_FIELD run returns status 0: $out"
assert_eq 2 "$(argv_fields_count '(C)')" \
    "observation 11: each transport conversion follows the SCALAR_FIELD value"
assert_eq 0 "$(argv_count_with -no-point-data)" \
    "observation 11: the SCALAR_FIELD run also writes point data"
