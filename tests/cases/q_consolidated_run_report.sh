#!/usr/bin/env bash
# Section 23.Q - consolidated end-of-run report (Issue #27).
#
# Every assertion uses the public top-level CLI and the console output. No test
# reads an internal run_batch.sh bookkeeping file or calls a private function.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# ---- helpers -----------------------------------------------------------------

# make_report_master <dir> - five stage scripts that write a stage summary, that
# can wait, and that can fail. Each script reads one control directory, so a
# scenario decides the stage result and the summary content.
make_report_master() {
    local dir="$1" name stage summary
    mkdir -p -- "$dir"

    for name in setup_cases.sh run_mesh_cases.sh run_flow_cases.sh \
                run_transport_cases.sh run_post_processing_cases.sh; do
        case "$name" in
            setup_cases.sh) stage=setup; summary=setup_cases_summary.csv ;;
            run_mesh_cases.sh) stage=mesh; summary=run_mesh_cases_summary.csv ;;
            run_flow_cases.sh) stage=flow; summary=run_flow_cases_summary.csv ;;
            run_transport_cases.sh) stage=transport; summary=run_transport_cases_summary.csv ;;
            *) stage=post; summary=run_post_processing_cases_summary.csv ;;
        esac

        cat > "${dir}/${name}" <<STAGE
#!/usr/bin/env bash
set -u
report_stage="${stage}"
report_summary="${summary}"
report_batch="\${BATCH_NUMBER:-none}"
report_ctrl="\${REPORT_CTRL_DIR:?REPORT_CTRL_DIR must be set}"
report_prefix="\${report_ctrl}/\${report_stage}.\${report_batch}"

if [[ -f "\${report_prefix}.delay" ]]; then
    sleep "\$(cat "\${report_prefix}.delay")"
fi

if [[ -f "\${report_prefix}.summary" ]]; then
    cp -f -- "\${report_prefix}.summary" "\$report_summary"
fi

printf 'report stage %s ran for batch %s\n' "\$report_stage" "\$report_batch"

if [[ -f "\${report_prefix}.fail" ]]; then
    printf 'report stage %s: forced failure for batch %s\n' \\
        "\$report_stage" "\$report_batch" >&2
    exit 3
fi
exit 0
STAGE
        chmod +x "${dir}/${name}"
    done
}

# stage_row <stage> <row_number> <case_id> <status> [<message>] - one summary
# data row with the exact column count of that stage summary.
stage_row() {
    local stage="$1" row_no="$2" case_id="$3" status="$4" message="${5:-}"
    case "$stage" in
        setup)
            printf '"in.csv","%s","%s","%s","270.000","3.5","3.5","/w/%s","%s","%s"' \
                "$row_no" "$case_id" "$case_id" "$case_id" "$status" "$message" ;;
        mesh|flow)
            printf '"in.csv","%s","%s","%s","/w/%s","%s","%s"' \
                "$row_no" "$case_id" "$case_id" "$case_id" "$status" "$message" ;;
        transport)
            printf '"in.csv","%s","%s","%s|%s","/w/%s","%s","%s"' \
                "$row_no" "$case_id" "$case_id" "$case_id" "$case_id" "$status" "$message" ;;
        post)
            printf '"%s","/w/%s","%s","%s"' "$case_id" "$case_id" "$status" "$message" ;;
    esac
}

# report_summary <ctrl_dir> <stage> <batch> [<row> ...] - the summary that the
# stage script writes into the Batch Workspace.
report_summary() {
    local ctrl="$1" stage="$2" batch="$3" header path row
    shift 3

    case "$stage" in
        setup) header='csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message' ;;
        mesh|flow) header='csv_file,row_number,case_id,case_name,case_dir,status,message' ;;
        transport) header='csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message' ;;
        *) header='case_id,case_dir,status,message' ;;
    esac

    mkdir -p -- "$ctrl"
    path="${ctrl}/${stage}.${batch}.summary"
    printf '%s\n' "$header" > "$path"
    for row in "$@"; do
        printf '%s\n' "$row" >> "$path"
    done
}

# report_payload <output> - the report lines without the timestamp and level
# prefix. The stable contract is the message payload.
report_payload() {
    printf '%s\n' "$1" |
        sed -n 's/^\[[0-9][0-9-]* [0-9][0-9:]*\] [A-Z][A-Z]*  *//p' |
        grep '^Run report' || true
}

# ---- successful single batch -------------------------------------------------

workspace="$(new_workspace success_single)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0

report_summary "$ctrl" setup 1 \
    "$(stage_row setup 2 case_0 created 'flow case created')" \
    "$(stage_row setup 3 case_1 created 'flow case created')" \
    "$(stage_row setup 4 case_2 skipped 'flow case already exists')"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"
expected="Run report begin
Run report batch: batch_1 result=succeeded
Run report stage: batch=batch_1 stage=setup result=succeeded summary=available total=3 succeeded=2 skipped=1 failed=0 other=0
Run report total: requested=1 attempted=1 succeeded=1 failed=0 not_started=0
Run report end"

assert_status 0 "$status" "a successful run keeps exit status 0"
assert_eq "$expected" "$payload" "the successful single-batch report payload is exact"
assert_contains "$out" "All requested batches and stages finished successfully." \
    "the existing overall success diagnostic stays present"

# ---- failed stage, failed cases, and a later stage that never starts ---------

workspace="$(new_workspace failed_stage)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0

report_summary "$ctrl" setup 1 \
    "$(stage_row setup 2 case_0 created 'flow case created')" \
    "$(stage_row setup 3 case_1 created 'flow case created')"
report_summary "$ctrl" mesh 1 \
    "$(stage_row mesh 2 case_0 meshed 'mesh complete')" \
    "$(stage_row mesh 3 case_1 failed 'see log: /w/logs/case_1.log')" \
    "$(stage_row mesh 4 case_2 failed 'mesh precondition not satisfied')"
: > "${ctrl}/mesh.1.fail"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup,mesh,flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"
expected="Run report begin
Run report batch: batch_1 result=failed
Run report stage: batch=batch_1 stage=setup result=succeeded summary=available total=2 succeeded=2 skipped=0 failed=0 other=0
Run report stage: batch=batch_1 stage=mesh result=failed summary=available total=3 succeeded=1 skipped=0 failed=2 other=0
Run report failure: batch=batch_1 stage=mesh case=case_1 log=/w/logs/case_1.log
Run report failure: batch=batch_1 stage=mesh case=case_2 log=unavailable
Run report stage: batch=batch_1 stage=flow result=not_attempted summary=unavailable total=unknown succeeded=unknown skipped=unknown failed=unknown other=unknown
Run report total: requested=1 attempted=1 succeeded=0 failed=1 not_started=0
Run report end"

assert_failure "$status" "a failed stage keeps a non-zero final status"
assert_eq "$expected" "$payload" "the failed-stage report payload is exact"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the existing stage failure diagnostic stays present"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "a failed run must not report overall success"

# ---- a failed stage without a usable summary --------------------------------

workspace="$(new_workspace failed_no_summary)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0

# The stage fails and writes no summary.
: > "${ctrl}/setup.1.fail"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"
expected="Run report begin
Run report batch: batch_1 result=failed
Run report stage: batch=batch_1 stage=setup result=failed summary=unavailable total=unknown succeeded=unknown skipped=unknown failed=unknown other=unknown
Run report total: requested=1 attempted=1 succeeded=0 failed=1 not_started=0
Run report end"

assert_failure "$status" "a failed stage without a summary keeps a non-zero status"
assert_eq "$expected" "$payload" \
    "an unusable summary gives unknown counts and no invented case line"
assert_not_contains "$payload" "Run report failure:" \
    "the report invents no failed case line"

# ---- sequential multi-batch scheduling --------------------------------------

# build_three_batches <name> - three batches that share one report master.
build_three_batches() {
    local batch
    workspace="$(new_workspace "$1")"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    ctrl="${workspace}/ctrl"
    make_report_master "$master"
    mkdir -p "$output" "$ctrl"
    for batch in 1 2 3; do
        make_csv "${workspace}/output_batch_${batch}.csv" 0
        report_summary "$ctrl" setup "$batch" \
            "$(stage_row setup 2 "case_${batch}" created 'flow case created')"
    done
    batch_csvs=(
        "${workspace}/output_batch_1.csv"
        "${workspace}/output_batch_2.csv"
        "${workspace}/output_batch_3.csv"
    )
}

# A sequential successful run prints every batch in input order.

build_three_batches sequential_success

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${batch_csvs[@]}" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"
expected="Run report begin
Run report batch: batch_1 result=succeeded
Run report stage: batch=batch_1 stage=setup result=succeeded summary=available total=1 succeeded=1 skipped=0 failed=0 other=0
Run report batch: batch_2 result=succeeded
Run report stage: batch=batch_2 stage=setup result=succeeded summary=available total=1 succeeded=1 skipped=0 failed=0 other=0
Run report batch: batch_3 result=succeeded
Run report stage: batch=batch_3 stage=setup result=succeeded summary=available total=1 succeeded=1 skipped=0 failed=0 other=0
Run report total: requested=3 attempted=3 succeeded=3 failed=0 not_started=0
Run report end"

assert_status 0 "$status" "a sequential successful run keeps exit status 0"
assert_eq "$expected" "$payload" "the sequential success report uses input-batch order"

# Sequential stop-first omits the batch that never started.

build_three_batches sequential_stopfirst
: > "${ctrl}/setup.2.fail"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${batch_csvs[@]}" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"

assert_failure "$status" "a sequential stop-first run stays non-zero"
assert_contains "$payload" "Run report batch: batch_1 result=succeeded" \
    "the first attempted batch is present"
assert_contains "$payload" "Run report batch: batch_2 result=failed" \
    "the failed batch is present"
assert_not_contains "$payload" "batch_3" \
    "a batch that never started has no report section"
assert_contains "$payload" \
    "Run report total: requested=3 attempted=2 succeeded=1 failed=1 not_started=1" \
    "the run total counts the batch that never started"

# --keep-going attempts every batch and stays non-zero.

build_three_batches sequential_keepgoing
: > "${ctrl}/setup.2.fail"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup --keep-going \
        -m "$master" -o "$output" "${batch_csvs[@]}" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"

assert_failure "$status" "--keep-going stays non-zero after a failed batch"
assert_contains "$payload" "Run report batch: batch_3 result=succeeded" \
    "--keep-going attempts the later batch"
assert_contains "$payload" \
    "Run report total: requested=3 attempted=3 succeeded=2 failed=1 not_started=0" \
    "--keep-going reports every attempted batch"

# ---- parallel batch scheduling ----------------------------------------------

# The completion order is deliberately the reverse of the input order.

build_three_batches parallel_order
printf '0.9\n' > "${ctrl}/setup.1.delay"
printf '0.5\n' > "${ctrl}/setup.2.delay"
printf '0.1\n' > "${ctrl}/setup.3.delay"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup -B 3 \
        -m "$master" -o "$output" "${batch_csvs[@]}" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"
completion_order="$(printf '%s\n' "$out" |
    grep -o 'Batch finished  : batch_[0-9]*' | grep -o 'batch_[0-9]*' | tr '\n' ' ')"

assert_status 0 "$status" "a parallel successful run keeps exit status 0"
assert_eq "batch_3 batch_2 batch_1 " "$completion_order" \
    "the scenario really reverses the batch completion order"
assert_contains "$payload" "Run report batch: batch_1 result=succeeded" \
    "the parallel report contains the first batch"
assert_eq "batch_1 batch_2 batch_3 " \
    "$(printf '%s\n' "$payload" | grep -o '^Run report batch: batch_[0-9]*' |
        grep -o 'batch_[0-9]*' | tr '\n' ' ')" \
    "the parallel report keeps input-batch order"
assert_contains "$payload" \
    "Run report total: requested=3 attempted=3 succeeded=3 failed=0 not_started=0" \
    "the parallel run total counts every attempted batch"

# Parallel stop-first keeps already-running batches and omits unlaunched ones.

build_three_batches parallel_stopfirst
: > "${ctrl}/setup.1.fail"
printf '0.5\n' > "${ctrl}/setup.2.delay"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup -B 2 \
        -m "$master" -o "$output" "${batch_csvs[@]}" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"

assert_failure "$status" "a parallel stop-first run stays non-zero"
assert_contains "$payload" "Run report batch: batch_1 result=failed" \
    "the failed batch is present"
assert_contains "$payload" "Run report batch: batch_2 result=succeeded" \
    "an already-running batch stays attempted"
assert_not_contains "$payload" "batch_3" \
    "a batch that was never launched has no report section"
assert_contains "$payload" \
    "Run report total: requested=3 attempted=2 succeeded=1 failed=1 not_started=1" \
    "the parallel stop-first run total counts the unlaunched batch"

# ---- canonical stage order --------------------------------------------------

workspace="$(new_workspace stage_order)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0
report_summary "$ctrl" setup 1 "$(stage_row setup 2 case_0 created 'created')"
report_summary "$ctrl" mesh 1 "$(stage_row mesh 2 case_0 meshed 'meshed')"
report_summary "$ctrl" flow 1 "$(stage_row flow 2 case_0 solved 'solved')"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage flow,setup,mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"

assert_status 0 "$status" "a non-canonical stage selection keeps exit status 0"
assert_eq "setup mesh flow " \
    "$(printf '%s\n' "$payload" | grep -o 'stage=[a-z-]* result' |
        sed -e 's/^stage=//' -e 's/ result$//' | tr '\n' ' ')" \
    "the report prints stage lines in canonical order"

# ---- a stale summary is not execution evidence ------------------------------

workspace="$(new_workspace stale_summary)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0

# A reused Batch Workspace that already holds an old flow summary.
mkdir -p "${output}/batch_1"
cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"
report_summary "$ctrl" flow stale \
    "$(stage_row flow 2 old_case_0 solved 'old run')" \
    "$(stage_row flow 3 old_case_1 failed 'see log: /old/logs/old_case_1.log')"
cp -f -- "${ctrl}/flow.stale.summary" "${output}/batch_1/run_flow_cases_summary.csv"

report_summary "$ctrl" mesh 1 "$(stage_row mesh 2 case_0 failed 'see log: /w/logs/case_0.log')"
: > "${ctrl}/mesh.1.fail"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage mesh,flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(report_payload "$out")"

assert_failure "$status" "the stale-summary run stays non-zero"
assert_contains "$payload" \
    "Run report stage: batch=batch_1 stage=flow result=not_attempted summary=unavailable total=unknown succeeded=unknown skipped=unknown failed=unknown other=unknown" \
    "a stale summary does not make a stage look attempted"
assert_not_contains "$payload" "old_case_1" \
    "the report counts no row of a stale summary"

# ---- dry-run and preflight failure print no report --------------------------

workspace="$(new_workspace dryrun)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --dry-run --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a dry-run keeps exit status 0"
assert_contains "$out" "DRY-RUN complete. No simulations were run." \
    "the dry-run keeps its current output"
assert_eq "" "$(report_payload "$out")" "a dry-run prints no report block"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_missing.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a preflight failure stays non-zero"
assert_eq "" "$(report_payload "$out")" "a preflight failure prints no report block"

# ---- the report adds no persistent artifact ---------------------------------

workspace="$(new_workspace no_artifact)"
master="${workspace}/master_batch"
output="${workspace}/out"
ctrl="${workspace}/ctrl"
make_report_master "$master"
mkdir -p "$output" "$ctrl"
make_csv "${workspace}/output_batch_1.csv" 0
report_summary "$ctrl" setup 1 \
    "$(stage_row setup 2 case_0 created 'flow case created')"

before="$(find "${ctrl}" -type f | sort)"

out="$(REPORT_CTRL_DIR="$ctrl" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the no-artifact run keeps exit status 0"
assert_eq "" "$(find "${output}" -iname '*run_report*' -o -iname '*report*bookkeeping*' | sort)" \
    "no report artifact stays in a Batch Workspace"
assert_eq "$before" "$(find "${ctrl}" -type f | sort)" \
    "report generation adds no control-directory file"

# The stage summary is byte-for-byte unchanged by report generation.
cmp -s -- "${ctrl}/setup.1.summary" "${output}/batch_1/setup_cases_summary.csv" ||
    _fail "report generation changed the stage summary"

# No temporary run-report directory survives the Orchestrator.
assert_eq "" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'run_batch_report.*' -newer "${ctrl}" 2>/dev/null | sort)" \
    "the temporary run-report directory is removed at exit"
