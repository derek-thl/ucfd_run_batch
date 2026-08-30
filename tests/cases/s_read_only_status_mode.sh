#!/usr/bin/env bash
# Section 23.S - read-only status mode (Issue #31).
#
# Every assertion uses the public top-level CLI and its console output. No test
# calls a private shell function and no test reads an internal shell variable.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# ---- helpers -----------------------------------------------------------------

# status_payload <output> - the status lines without the timestamp and the level
# prefix. The stable contract is the message payload.
status_payload() {
    printf '%s\n' "$1" |
        sed -n 's/^\[[0-9][0-9-]* [0-9][0-9:]*\] [A-Z][A-Z]*  *//p' |
        grep '^Status report' || true
}

# status_case_line <batch> <case_id> <case_dir> <mesh> <flow> <transport> <post>
status_case_line() {
    printf 'Status report case: batch=batch_%s case=%s case_dir=%s mesh_restart_marker=%s flow_marker=%s transport_marker=%s post_signature=%s' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# make_status_batch <workspace> <output> <batch> [<case_id> ...] - a reusable
# Batch Workspace that holds its own DOE Batch CSV copy.
make_status_batch() {
    local workspace="$1" output="$2" batch="$3"
    shift 3
    make_csv "${workspace}/output_batch_${batch}.csv" "$@"
    mkdir -p "${output}/batch_${batch}"
    cp -f -- "${workspace}/output_batch_${batch}.csv" \
        "${output}/batch_${batch}/output_batch_${batch}.csv"
}

# ---- one case with no Case directory and no marker --------------------------

workspace="$(new_workspace status_absent)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

payload="$(status_payload "$out")"
expected="Status report begin
$(status_case_line 1 case_0 absent absent absent absent absent)
Status report total: batches=1 cases=1
Status report end"

assert_status 0 "$status" "status mode returns 0 when a Case directory is absent"
assert_eq "$expected" "$payload" "the all-absent status payload is exact"

# ---- help lists the status mode ---------------------------------------------

help_text="$(bash "$RUN_BATCH" --help 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "--help keeps exit status 0"
assert_help_option "$help_text" "--status" "the help output lists --status"
assert_contains "$help_text" "Read-only status mode:" \
    "the help output explains the read-only status mode"
assert_contains "$help_text" "-s, --stage, --stages <STAGE>" \
    "the help output keeps its existing entries"

# ---- one marker at a time ---------------------------------------------------

workspace="$(new_workspace status_markers)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0
case_root="${output}/batch_1/case_0"
mkdir -p "${case_root}/flow"

run_status() {
    out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
            "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
    payload="$(status_payload "$out")"
}

run_status
assert_status 0 "$status" "a present Case directory keeps status 0"
assert_contains "$payload" "$(status_case_line 1 case_0 present absent absent absent absent)" \
    "a present Case directory changes only case_dir"

printf 'done\n' > "${case_root}/flow/restart.marker"
run_status
assert_contains "$payload" "$(status_case_line 1 case_0 present present absent absent absent)" \
    "restart.marker changes only mesh_restart_marker"

printf 'done\n' > "${case_root}/flow/flow.marker"
run_status
assert_contains "$payload" "$(status_case_line 1 case_0 present present present absent absent)" \
    "flow.marker changes only flow_marker"

mkdir -p "${case_root}/trd"
printf 'done\n' > "${case_root}/trd/transport.marker"
run_status
assert_contains "$payload" "$(status_case_line 1 case_0 present present present present absent)" \
    "transport.marker changes only transport_marker"

mkdir -p "${case_root}/vtk"
printf 'signature\n' > "${case_root}/vtk/post_processing.complete"
run_status
assert_contains "$payload" "$(status_case_line 1 case_0 present present present present present)" \
    "post_processing.complete changes only post_signature"

# ---- other Case content is not marker evidence ------------------------------

workspace="$(new_workspace status_not_markers)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0
case_root="${output}/batch_1/case_0"
mkdir -p "${case_root}/flow/constant/polyMesh" "${case_root}/flow/3000" \
    "${case_root}/_mesh_logs" "${case_root}/trd/300" "${case_root}/vtk"
for name in points boundary faces owner neighbour; do
    printf 'FoamFile { object %s; }\n' "$name" > "${case_root}/flow/constant/polyMesh/${name}"
done
printf 'FoamFile { object U; }\n' > "${case_root}/flow/3000/U"
printf '' > "${case_root}/flow/case.foam"
printf 'csv_file,row_number,case_id,case_name,case_dir,status,message\n' \
    > "${case_root}/run_mesh_cases_summary.csv"
printf 'case_0/flow\n' > "${case_root}/.run_mesh_cases_failed"
printf 'log text\n' > "${case_root}/_mesh_logs/case_0_flow.log"

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "other Case content keeps status 0"
assert_contains "$(status_payload "$out")" \
    "$(status_case_line 1 case_0 present absent absent absent absent)" \
    "a time directory, a mesh, case.foam, a summary, an artifact, and a log are not markers"

# ---- Case normalization, ignored rows, duplicates, and order ----------------

workspace="$(new_workspace status_cases)"
output="${workspace}/out"
mkdir -p "${output}/batch_1"
{
    printf 'Case,met__WS_mps,met__WD_deg\n'
    printf 'wind 01,3.5,270.0\n'
    printf ',3.5,270.0\n'
    printf 'NA,3.5,270.0\n'
    printf 'case_two,3.5,270.0\n'
    printf 'wind 01,4.5,90.0\n'
} > "${workspace}/output_batch_1.csv"
cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

payload="$(status_payload "$out")"
expected="Status report begin
$(status_case_line 1 case_wind_01 absent absent absent absent absent)
$(status_case_line 1 case_two absent absent absent absent absent)
Status report total: batches=1 cases=2
Status report end"

assert_status 0 "$status" "the Case normalization scenario keeps status 0"
assert_eq "$expected" "$payload" \
    "normalization, ignored rows, duplicate rows, and row order are exact"

# A DOE Batch CSV with a valid Case column and no data row emits no Case line.

workspace="$(new_workspace status_empty_csv)"
output="${workspace}/out"
mkdir -p "${output}/batch_1"
printf 'Case,met__WS_mps,met__WD_deg\n' > "${workspace}/output_batch_1.csv"
cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "an empty DOE Batch CSV keeps status 0"
assert_eq "Status report begin
Status report total: batches=1 cases=0
Status report end" "$(status_payload "$out")" \
    "an empty DOE Batch CSV emits no Case line"

# Multiple batches follow DOE Batch CSV argument order.

workspace="$(new_workspace status_multi_batch)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0
make_status_batch "$workspace" "$output" 2 case_1 case_2
mkdir -p "${output}/batch_2/case_2/flow"
printf 'done\n' > "${output}/batch_2/case_2/flow/flow.marker"

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_2.csv" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(status_payload "$out")"
expected="Status report begin
$(status_case_line 2 case_1 absent absent absent absent absent)
$(status_case_line 2 case_2 present absent present absent absent)
$(status_case_line 1 case_0 absent absent absent absent absent)
Status report total: batches=2 cases=3
Status report end"

assert_status 0 "$status" "a multi-batch status run keeps status 0"
assert_eq "$expected" "$payload" \
    "batch sections follow DOE Batch CSV argument order and the totals are exact"

# ---- validation failures print no status report -----------------------------

workspace="$(new_workspace status_validation)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0

# assert_status_failure <message> <argument> [<argument> ...]
assert_status_failure() {
    local message="$1"
    shift
    local failure_out failure_status=0

    failure_out="$(cd "$workspace" && bash "$RUN_BATCH" "$@" 2>&1)" || failure_status=$?

    assert_failure "$failure_status" "$message"
    assert_eq "" "$(status_payload "$failure_out")" \
        "${message}: no status report block is printed"
    printf '%s' "$failure_out"
}

# No DOE Batch CSV argument.
assert_status_failure "status mode needs a DOE Batch CSV" --status -o "$output" >/dev/null

# A missing DOE Batch CSV.
out="$(assert_status_failure "a missing DOE Batch CSV fails" --status -o "$output" \
    "${workspace}/output_batch_9.csv")"
assert_contains "$out" "Batch CSV not found" "the missing CSV keeps its existing diagnostic"

# A missing Batch Workspace.
out="$(assert_status_failure "a missing Batch Workspace fails" --status \
    -o "${workspace}/missing_root" "${workspace}/output_batch_1.csv")"
assert_contains "$out" "Existing batch directory required for --status" \
    "the missing Batch Workspace names the status requirement"
assert_dir_missing "${workspace}/missing_root" \
    "status mode creates no output root"

# An empty Batch Workspace.
mkdir -p "${output}/batch_5"
make_csv "${workspace}/output_batch_5.csv" case_0
out="$(assert_status_failure "an empty Batch Workspace fails" --status -o "$output" \
    "${workspace}/output_batch_5.csv")"
assert_contains "$out" "Existing batch directory is empty" \
    "the empty Batch Workspace keeps its existing diagnostic"

# Duplicate Batch IDs.
cp -f -- "${workspace}/output_batch_1.csv" "${workspace}/copy_batch_1.csv"
out="$(assert_status_failure "duplicate Batch IDs fail" --status -o "$output" \
    "${workspace}/output_batch_1.csv" "${workspace}/copy_batch_1.csv")"
assert_contains "$out" "Duplicate batch destination detected" \
    "the duplicate Batch ID keeps its existing diagnostic"

# A mismatched Batch Workspace CSV.
make_csv "${workspace}/mismatch/output_batch_1.csv" case_9
out="$(assert_status_failure "a mismatched Batch Workspace CSV fails" --status -o "$output" \
    "${workspace}/mismatch/output_batch_1.csv")"
assert_contains "$out" "CSV mismatch for existing batch_1" \
    "the CSV mismatch keeps its existing diagnostic"

# A missing Case column.
mkdir -p "${output}/batch_7"
printf 'name,met__WS_mps,met__WD_deg\nrow_a,3.5,270.0\n' \
    > "${workspace}/output_batch_7.csv"
cp -f -- "${workspace}/output_batch_7.csv" "${output}/batch_7/output_batch_7.csv"
out="$(assert_status_failure "a missing Case column fails" --status -o "$output" \
    "${workspace}/output_batch_7.csv")"
assert_contains "$out" "Required column not found" \
    "the missing Case column gives an explicit diagnostic"

# ---- execution options conflict with --status -------------------------------

conflict_options=(
    "-s:setup" "--stage:setup" "--stages:setup"
    "-j:2" "--jobs:2" "--setup-jobs:2" "--mesh-jobs:2" "--flow-jobs:2"
    "--transport-jobs:2" "--post-jobs:2" "-B:2" "--batch-jobs:2"
    "-m:${workspace}" "--master-dir:${workspace}"
    "--save-times:60" "--scalar-field:T"
    "-f:" "--overwrite:" "--keep-going:" "--skip-post:" "-n:" "--dry-run:"
)

for entry in "${conflict_options[@]}"; do
    option="${entry%%:*}"
    value="${entry#*:}"

    conflict_args=(--status -o "$output")
    if [[ -n "$value" ]]; then
        conflict_args+=("$option" "$value")
    else
        conflict_args+=("$option")
    fi
    conflict_args+=("${workspace}/output_batch_1.csv")

    out="$(cd "$workspace" && bash "$RUN_BATCH" "${conflict_args[@]}" 2>&1)" \
        && status=0 || status=$?

    assert_failure "$status" "--status with ${option} must fail"
    assert_contains "$out" "--status cannot be combined with ${option}." \
        "the conflict names --status and ${option}"
    assert_eq "" "$(status_payload "$out")" \
        "--status with ${option} prints no status report block"
done

# The option order does not change the conflict.
out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a conflicting option before --status must fail"
assert_contains "$out" "--status cannot be combined with --dry-run." \
    "the conflict is independent of the option order"

# Environment values do not create a conflict.
out="$(cd "$workspace" && MASTER_BATCH_DIR="${workspace}/anywhere" \
        RUN_BATCH_OVERWRITE=1 bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "environment values do not create a status conflict"
assert_contains "$(status_payload "$out")" "Status report end" \
    "the status report still completes with environment values set"
assert_dir_missing "${workspace}/anywhere" \
    "an environment master directory value causes no write"

# ---- status mode writes nothing and runs nothing ----------------------------

workspace="$(new_workspace status_readonly)"
output="${workspace}/out"
make_status_batch "$workspace" "$output" 1 case_0
case_root="${output}/batch_1/case_0"
mkdir -p "${case_root}/flow" "${case_root}/trd" "${case_root}/vtk"
printf 'done\n' > "${case_root}/flow/flow.marker"

# Poison commands record every invocation. Status mode must invoke none of them.
poison_bin="${workspace}/_poison_bin"
poison_log="${workspace}/_poison.log"
mkdir -p "$poison_bin"
for command_name in surfaceCheck surfaceTransformPoints foamDictionary \
                    surfaceFeatureExtract blockMesh decomposePar mpirun \
                    snappyHexMesh reconstructParMesh reconstructPar checkMesh \
                    renumberMesh simpleFoam scalarTransportDeffFoam foamToVTK \
                    foamListTimes; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "%s"\nexit 0\n' \
        "$poison_log" > "${poison_bin}/${command_name}"
    chmod +x "${poison_bin}/${command_name}"
done

# A poison master template records any stage-script resolution or execution.
poison_master="${workspace}/poison_master"
mkdir -p "$poison_master"
for name in setup_cases.sh run_mesh_cases.sh run_flow_cases.sh \
            run_transport_cases.sh run_post_processing_cases.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 0\n' \
        "$name" "$poison_log" > "${poison_master}/${name}"
    chmod +x "${poison_master}/${name}"
done
cp -f -- "${poison_master}"/*.sh "${output}/batch_1/"

before="$(find "$output" | sort)"
before_content="$(find "$output" -type f -exec cksum {} \; | sort)"

out="$(cd "$workspace" && PATH="${poison_bin}:${PATH}" \
        MASTER_BATCH_DIR="$poison_master" bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the read-only scenario keeps status 0"
assert_contains "$(status_payload "$out")" \
    "$(status_case_line 1 case_0 present absent present absent absent)" \
    "the read-only scenario reports the existing marker state"

assert_file_missing "$poison_log" \
    "status mode runs no OpenFOAM command and no stage script"
assert_eq "$before" "$(find "$output" | sort)" \
    "status mode creates and removes no path in a Batch Workspace"
assert_eq "$before_content" "$(find "$output" -type f -exec cksum {} \; | sort)" \
    "status mode changes no Batch Workspace file"

# Status mode prints no execution-mode diagnostic.
for forbidden in "Preflight PASS" "Selected-Stage tool advisory" "Stage start" \
                 "Run report begin" "DRY-RUN" \
                 "All requested batches and stages finished successfully."; do
    assert_not_contains "$out" "$forbidden" \
        "status mode prints no '${forbidden}' line"
done

# ---- execution modes stay unchanged -----------------------------------------

workspace="$(new_workspace status_regression)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output" "${master}/simpleFoam_files/system"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the existing dry-run keeps status 0"
assert_contains "$out" "Preflight PASS" "the dry-run keeps its preflight line"
assert_contains "$out" "DRY-RUN complete. No simulations were run." \
    "the dry-run keeps its current output"
assert_eq "" "$(status_payload "$out")" "the dry-run prints no status report block"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the existing execution keeps status 0"
stub_ran setup 1 || _fail "the existing execution still runs the stage script"
assert_contains "$out" "Stage start   : setup_cases.sh" \
    "the existing execution keeps its stage diagnostics"
assert_contains "$out" "Run report begin" \
    "the existing execution keeps the consolidated report"
assert_contains "$out" "All requested batches and stages finished successfully." \
    "the existing execution keeps its overall success diagnostic"
assert_eq "" "$(status_payload "$out")" "an execution run prints no status report block"
