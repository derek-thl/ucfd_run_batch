#!/usr/bin/env bash
# Section 23.T - explicit Stage Runner output-directory forwarding (Issue #33).
#
# Every assertion uses the public top-level CLI, the recorded Stage Runner
# argument vector, the recorded working directory, and the recorded environment.
# No test calls a private shell function and no test reads an internal array.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# ---- helpers -----------------------------------------------------------------

# batch_workspace <output> <batch> - the canonical Batch Workspace path that the
# Orchestrator uses.
batch_workspace() {
    realpath -m -- "${1}/batch_${2}"
}

# count_option <stage> <batch> <option> - how often the option token appears in
# the recorded argument vector.
count_option() {
    local token count=0
    while IFS= read -r token; do
        [[ "$token" == "$3" ]] && count=$(( count + 1 ))
    done < <(stub_argv "$1" "$2")
    printf '%s\n' "$count"
}

# make_reuse_workspace <name> - a reusable Batch Workspace with stage stubs.
make_reuse_workspace() {
    workspace="$(new_workspace "$1")"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    use_stub_records "$workspace"
    make_csv "${workspace}/output_batch_1.csv" case_0
    mkdir -p "${output}/batch_1"
    cp -f -- "${workspace}/output_batch_1.csv" \
        "${output}/batch_1/output_batch_1.csv"
}

# ---- one selected stage receives the explicit output directory ---------------

make_reuse_workspace mesh_only

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"

assert_status 0 "$status" "the mesh run keeps exit status 0"
assert_eq 1 "$(count_option mesh 1 -O)" \
    "the mesh stage runner receives -O exactly once"
assert_eq "$expected_dir" "$(stub_arg_after mesh 1 -O)" \
    "the -O value is the absolute Batch Workspace path"
assert_eq "$(argv_line -i "${expected_dir}/output_batch_1.csv" -O "$expected_dir")" \
    "$(stub_argv_joined mesh 1)" \
    "the mesh argument vector is exactly -i <csv> -O <batch workspace>"

# ---- every selected stage receives the same argument contract ---------------

workspace="$(new_workspace full_pipeline)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" -j 4 \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"
expected_csv="${expected_dir}/output_batch_1.csv"

assert_status 0 "$status" "the full pipeline keeps exit status 0"

for stage in setup mesh flow post; do
    assert_eq 1 "$(count_option "$stage" 1 -O)" \
        "the ${stage} stage runner receives -O exactly once"
    assert_eq "$(argv_line -i "$expected_csv" -O "$expected_dir" -j 4)" \
        "$(stub_argv_joined "$stage" 1)" \
        "the ${stage} argument vector keeps the required order"
done

assert_eq 1 "$(count_option transport 1 -O)" \
    "the transport stage runner receives -O exactly once"
assert_eq "$(argv_line -i "$expected_csv" -O "$expected_dir" -j 4 --save-times 60,120,300)" \
    "$(stub_argv_joined transport 1)" \
    "transport keeps --save-times after the job argument"

# The -O value equals BATCH_DIR and the stage runner working directory.
for stage in setup mesh flow transport post; do
    assert_eq "$expected_dir" "$(stub_env "$stage" 1 BATCH_DIR)" \
        "the ${stage} -O value equals the exported BATCH_DIR"
    assert_eq "$expected_dir" "$(stub_env "$stage" 1 cwd)" \
        "the ${stage} stage runner still runs in the Batch Workspace"
    assert_eq "$(stub_env "$stage" 1 cwd)" "$(stub_arg_after "$stage" 1 -O)" \
        "the ${stage} -O value equals its working directory"
done

# ---- the contract holds without a job argument ------------------------------

make_reuse_workspace no_jobs

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"

assert_status 0 "$status" "the no-job run keeps exit status 0"
assert_eq "$(argv_line -i "${expected_dir}/output_batch_1.csv" -O "$expected_dir")" \
    "$(stub_argv_joined flow 1)" \
    "-O stays present when the Orchestrator forwards no job argument"

# ---- a Batch Workspace path with spaces and shell metacharacters ------------

workspace="$(new_workspace odd_path)"
master="${workspace}/master_batch"
output="${workspace}/out dir & meta;\$x"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"

assert_status 0 "$status" "an unusual Batch Workspace path keeps exit status 0"
assert_eq 1 "$(count_option setup 1 -O)" \
    "an unusual path still gives exactly one -O"
assert_eq "$expected_dir" "$(stub_arg_after setup 1 -O)" \
    "a path with spaces and metacharacters stays one exact argument"
assert_eq "$(argv_line -i "${expected_dir}/output_batch_1.csv" -O "$expected_dir")" \
    "$(stub_argv_joined setup 1)" \
    "an unusual path does not split the argument vector"
assert_not_contains "$(stub_arg_after setup 1 -O)" "\\" \
    "the real argument carries no display-escaping backslash"

# ---- each batch receives its own Batch Workspace ----------------------------

# make_two_batches <name> [<extra_setup>]
make_two_batches() {
    local batch
    workspace="$(new_workspace "$1")"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    use_stub_records "$workspace"
    mkdir -p "$output"
    for batch in 1 2; do
        make_csv "${workspace}/output_batch_${batch}.csv" "case_${batch}"
    done
}

assert_batch_paths() {
    local batch expected
    for batch in 1 2; do
        expected="$(batch_workspace "$output" "$batch")"
        assert_eq "$expected" "$(stub_arg_after setup "$batch" -O)" \
            "batch_${batch} receives its own Batch Workspace path ($1)"
        assert_eq "$expected" "$(stub_env setup "$batch" cwd)" \
            "batch_${batch} still runs in its own Batch Workspace ($1)"
    done
}

make_two_batches sequential_batches

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a sequential two-batch run keeps exit status 0"
assert_batch_paths sequential

make_two_batches parallel_batches

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup -B 2 \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a parallel two-batch run keeps exit status 0"
assert_batch_paths parallel

# ---- dry-run commands show the same contract --------------------------------

workspace="$(new_workspace dryrun)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run -j 4 \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"
expected_csv="${expected_dir}/output_batch_1.csv"

assert_status 0 "$status" "the dry-run keeps exit status 0"
assert_contains "$out" "DRY-RUN complete. No simulations were run." \
    "the dry-run keeps its current output"

for stage_script in setup_cases.sh run_mesh_cases.sh run_flow_cases.sh \
                    run_post_processing_cases.sh; do
    assert_contains "$out" \
        "$(printf '%q ' bash "${master}/${stage_script}" -i "$expected_csv" -O "$expected_dir" -j 4)" \
        "the dry-run ${stage_script} command shows the required argument order"
done

assert_contains "$out" \
    "$(printf '%q ' bash "${master}/run_transport_cases.sh" -i "$expected_csv" \
        -O "$expected_dir" -j 4 --save-times 60,120,300)" \
    "the dry-run transport command keeps --save-times after the job argument"

if stub_ran setup 1; then
    _fail "a dry-run must not run a stage runner"
fi

# ---- batch-local stage runner resolution uses the same contract -------------

workspace="$(new_workspace batch_local)"
output="${workspace}/out"
use_stub_records "$workspace"
make_csv "${workspace}/output_batch_1.csv" case_0
mkdir -p "${output}/batch_1"
cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"
make_stub_master "${output}/batch_1" batch

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "${workspace}/absent_master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

expected_dir="$(batch_workspace "$output" 1)"

assert_status 0 "$status" "a batch-local stage runner keeps exit status 0"
assert_eq batch "$(stub_origin mesh 1)" "the batch-local stage runner ran"
assert_eq "$(argv_line -i "${expected_dir}/output_batch_1.csv" -O "$expected_dir")" \
    "$(stub_argv_joined mesh 1)" \
    "a batch-local stage runner receives the same argument contract"

# ---- a forced stage failure keeps its exact status --------------------------

make_reuse_workspace forced_failure

out="$(cd "$workspace" && STUB_FAIL_STAGES="mesh" bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 3 "$status" "the forced stage exit status stays the final status"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the existing stage failure diagnostic stays unchanged"
assert_contains "$out" "Run report batch: batch_1 result=failed" \
    "the consolidated report keeps its failed batch line"

# ---- the advisory and the consolidated report stay unchanged ----------------

workspace="$(new_workspace regressions)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --stage setup,flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the advisory regression dry-run keeps exit status 0"
assert_contains "$out" \
    "Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_0 application=undetected" \
    "the selected-Stage advisory output stays unchanged"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the consolidated report regression keeps exit status 0"
assert_contains "$out" "Run report begin" "the consolidated report stays present"
assert_contains "$out" "Run report batch: batch_1 result=succeeded" \
    "the consolidated report keeps its batch line"
assert_contains "$out" "All requested batches and stages finished successfully." \
    "the overall success diagnostic stays present"

# ---- read-only status mode still runs no stage runner -----------------------

make_reuse_workspace status_mode

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "status mode keeps exit status 0"
assert_contains "$out" "Status report end" "status mode keeps its report"
for stage in setup mesh flow transport post; do
    if stub_ran "$stage" 1; then
        _fail "status mode must run no stage runner (${stage})"
    fi
done

# ---- an optional missing post-processing stage stays skipped ----------------

workspace="$(new_workspace optional_post)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
rm -f -- "${master}/run_post_processing_cases.sh"
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$RUN_BATCH" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "a missing optional post-processing stage keeps status 0"
assert_contains "$out" "No post-processing script found in batch directory. Skip." \
    "the optional post-processing stage keeps its skip diagnostic"
if stub_ran post 1; then
    _fail "the Orchestrator must invent no command for a skipped stage"
fi

# ---- a direct stage runner keeps its own default output directory -----------

workspace="$(new_workspace direct_default)"
mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
make_csv "${workspace}/output_batch_1.csv" case_0

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv --dry-run 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the direct stage runner keeps exit status 0"
assert_file_exists "${workspace}/setup_cases_summary.csv" \
    "a direct stage runner without -O keeps its current default output directory"
