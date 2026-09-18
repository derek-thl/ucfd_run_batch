#!/usr/bin/env bash
# Section 23.AA - the post-processing Stage writes VTK point data.
#
# The scenario makes two required observations.
#
# Observation 1: the point-data policy.
# The Stage Runner MUST NOT pass `-no-point-data` to `foamToVTK`. Each recorded
# argument vector MUST still hold `-time`, `-no-boundary`, and `-fields`. The
# field selections MUST stay unchanged: `(U p wallDistance)` for the flow zero
# time, `(U p)` for the flow result time, and the value of `SCALAR_FIELD` for
# each transport time.
#
# Observation 2: the completion-marker migration.
# A completion marker that does not record the VTU point-data policy is not
# current. The Stage MUST rebuild that Case one time. The rebuild MUST write a
# current marker. A second run with an unchanged source MUST then report
# `skipped` and MUST call `foamToVTK` zero times. `FORCE_POST=1` MUST still
# rebuild a current Case.
#
# The scenario builds the pre-change marker from a real run. The scenario then
# removes the `vtu_point_data` line. The remaining file is the exact marker that
# a pre-change runner writes.
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
log_dir="${vtk_dir}/logs"
marker="${vtk_dir}/post_processing.complete"
summary="${workspace}/run_post_processing_cases_summary.csv"

make_flow_case "$flow_dir" 2
make_flow_result "$flow_dir" 3000
make_transport_case "$trd_dir" 2 T 300
make_flow_mesh "$trd_dir"
mkdir -p "${trd_dir}/300"
printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"

run_post() {
    ( cd "$workspace" && env "$@" bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
}

# The fake commands join each recorded argument with this separator.
US=$'\x1f'

# argv_count_with <token> - recorded foamToVTK calls that hold the exact
# argument <token>.
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

# ---- observation 1: the point-data policy ------------------------------------

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the first post run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "the first run records one completed case"

assert_file_exists "${vtk_dir}/flow_0.vtu" "the first run writes flow_0.vtu"
assert_file_exists "${vtk_dir}/flow_latest_3000.vtu" \
    "the first run writes flow_latest_3000.vtu"
assert_file_exists "${vtk_dir}/trd_0.vtu" "the first run writes trd_0.vtu"
assert_file_exists "${vtk_dir}/trd_300.vtu" "the first run writes trd_300.vtu"
assert_file_exists "$marker" "the first run writes the completion marker"

calls="$(fake_call_count foamToVTK)"
assert_eq 4 "$calls" "the first run converts the four required times"

assert_eq 0 "$(argv_count_with -no-point-data)" \
    "no recorded foamToVTK call passes -no-point-data"
assert_eq "$calls" "$(argv_count_with -time)" \
    "every recorded foamToVTK call keeps -time"
assert_eq "$calls" "$(argv_count_with -no-boundary)" \
    "every recorded foamToVTK call keeps -no-boundary"
assert_eq "$calls" "$(argv_count_with -fields)" \
    "every recorded foamToVTK call keeps -fields"

assert_eq 1 "$(argv_fields_count '(U p wallDistance)')" \
    "the flow zero-time field selection stays (U p wallDistance)"
assert_eq 1 "$(argv_fields_count '(U p)')" \
    "the flow result field selection stays (U p)"
assert_eq 2 "$(argv_fields_count '(T)')" \
    "each transport conversion uses the SCALAR_FIELD selection (T)"

# The echo trace MUST match the executed argument vector.
flow_zero_log="$(cat "${log_dir}/flow_0.log")"
assert_not_contains "$flow_zero_log" "-no-point-data" \
    "the flow_0 conversion trace names no -no-point-data argument"
assert_contains "$flow_zero_log" "foamToVTK -time 0 -no-boundary -fields" \
    "the flow_0 conversion trace names the required arguments"

# ---- observation 2: the completion-marker migration --------------------------

assert_contains "$(cat "$marker")" "vtu_point_data=included" \
    "the new marker records the VTU point-data policy"

# Build the exact pre-change marker: the same signature without the policy line.
grep -v '^vtu_point_data=' "$marker" > "${marker}.legacy"
mv -f "${marker}.legacy" "$marker"
assert_not_contains "$(cat "$marker")" "vtu_point_data" \
    "the test marker is now a pre-change marker"

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the migration run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "a pre-change marker rebuilds the case one time"
assert_eq 4 "$(fake_call_count foamToVTK)" \
    "the migration run converts every required time again"
assert_eq 0 "$(argv_count_with -no-point-data)" \
    "the rebuilt outputs also carry point data"
assert_contains "$(cat "$marker")" "vtu_point_data=included" \
    "the rebuild writes a current marker"

# ---- the rebuilt case is current --------------------------------------------

reset_fake_records
out="$(run_post FORCE_POST=0)" && status=0 || status=$?
assert_status 0 "$status" "the confirming run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" skipped 3)" \
    "the case is current after the one rebuild"
assert_eq 0 "$(fake_call_count foamToVTK)" \
    "the confirming run runs no conversion"

# ---- FORCE_POST=1 still rebuilds a current case ------------------------------

reset_fake_records
out="$(run_post FORCE_POST=1)" && status=0 || status=$?
assert_status 0 "$status" "the forced run must succeed: $out"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "FORCE_POST=1 rebuilds a current case"
assert_eq 4 "$(fake_call_count foamToVTK)" "the forced run converts every time"
assert_eq 0 "$(argv_count_with -no-point-data)" \
    "the forced rebuild also writes point data"

# ---- the transport field selection follows SCALAR_FIELD ----------------------

mkdir -p "${trd_dir}/0"
printf 'FoamFile { object C; }\n' > "${trd_dir}/0/C"
printf 'FoamFile { object C; }\n' > "${trd_dir}/300/C"

reset_fake_records
out="$(run_post FORCE_POST=1 SCALAR_FIELD=C)" && status=0 || status=$?
assert_status 0 "$status" "the SCALAR_FIELD run must succeed: $out"
assert_eq 2 "$(argv_fields_count '(C)')" \
    "each transport conversion follows the SCALAR_FIELD value"
assert_eq 0 "$(argv_count_with -no-point-data)" \
    "the SCALAR_FIELD run also writes point data"
