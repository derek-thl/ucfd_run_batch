#!/usr/bin/env bash
# Section 23.AD - OpenFOAM version baseline and evidence-workflow contract
# (Issue #82, M1).
#
# The repository holds one machine-readable OpenFOAM baseline in
# `.openfoam-version`. The manual evidence workflow reads that file after
# checkout, validates the exact target, derives the package name and the
# environment file path from it, and fails closed when the loaded environment
# is not the exact target.
#
# The scenario inspects the committed baseline file, the committed evidence
# workflow, the committed batch-contract workflow, the specification, and the
# Scenario map. Two observations execute the extracted baseline-resolution step
# body in an isolated workspace, so the derivation and the fail-closed behavior
# are proved by execution and not by text alone. The scenario installs no
# OpenFOAM package and dispatches no workflow.
#
# Every observation runs in its own child process, so one failure cannot hide a
# later failure. The scenario reports every failing observation and then fails.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

BASELINE_FILE="${REPO_ROOT}/.openfoam-version"
WORKFLOW="${REPO_ROOT}/.github/workflows/openfoam-evidence.yml"
CONTRACT_WORKFLOW="${REPO_ROOT}/.github/workflows/batch-contract.yml"
SPEC="${REPO_ROOT}/docs/RUN_BATCH_HANDOFF_SPEC.md"
TESTS_README="${REPO_ROOT}/tests/README.md"

# The exact accepted target of Issue #82. Every expected value below is an
# independent literal from the M1 contract, not a value read back from the
# repository.
AD_BASELINE="v2512"
AD_RELEASE="2512"
AD_PACKAGE="openfoam2512-default"
AD_BASHRC="/usr/lib/openfoam/openfoam2512/etc/bashrc"

# ---- extraction helpers -----------------------------------------------------

# ad_step_block <step-name> - the exact text of one workflow step.
ad_step_block() {
    awk -v want="      - name: $1" '
        $0 == want { inside = 1; print; next }
        inside && /^      - name: / { exit }
        inside { print }
    ' "$WORKFLOW"
}

# ad_step_run_body <step-name> - the dedented shell body of one workflow step.
# The body is the block under `run: |`, which this workflow indents by ten
# spaces. The extraction ends at the first line that leaves that body.
ad_step_run_body() {
    awk -v want="      - name: $1" '
        $0 == want { found = 1; next }
        found && /^      - name: / { exit }
        found && !inside && /^        run: \|[[:space:]]*$/ { inside = 1; next }
        inside {
            if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            if ($0 !~ /^          /) { exit }
            print substr($0, 11)
        }
    ' "$WORKFLOW"
}

# ad_on_block - the exact text of the workflow trigger block.
ad_on_block() {
    awk '
        /^on:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]]/ { exit }
        inside { print }
    ' "$WORKFLOW"
}

# ad_step_names - every step name of the evidence job, in file order.
ad_step_names() {
    awk '/^      - name: / { print substr($0, 15) }' "$WORKFLOW"
}

# ad_step_index <step-name> - the 1-based position of one step, or 0.
ad_step_index() {
    ad_step_names | awk -v want="$1" '$0 == want { print NR; found = 1; exit }
                                      END { if (!found) print 0 }'
}

# ad_paths_block <event> - the path filter of one batch-contract event.
ad_paths_block() {
    awk -v want="  ${1}:" '
        $0 == want { inside = 1; next }
        inside && /^  [^[:space:]]/ { exit }
        inside { print }
    ' "$CONTRACT_WORKFLOW"
}

# ---- observation 1 ----------------------------------------------------------

o01_baseline_file_exact_bytes() {
    assert_file_exists "$BASELINE_FILE" \
        "observation 1: the repository holds the machine-readable baseline"
    # One literal X keeps the final newline byte significant inside command
    # substitution, so a missing or extra line ending fails this observation.
    assert_eq "${AD_BASELINE}"$'\n'"X" "$(cat -- "$BASELINE_FILE"; printf X)" \
        "observation 1: the baseline holds the exact bytes"
    assert_eq 1 "$(wc -l < "$BASELINE_FILE")" \
        "observation 1: the baseline holds exactly one line"
}

# ---- observations 2, 3, and 7 -----------------------------------------------

# ad_install_step_name - the current name of the installation step.
ad_install_step_name() {
    ad_step_names | awk 'index($0, "Install OpenFOAM") == 1 { print; exit }'
}

# ad_run_baseline_step <mode> <workspace> - execute the extracted
# baseline-resolution step body in an isolated workspace. The mode selects the
# committed-baseline fixture. The run leaves github_env, step.log, and
# step.status in the workspace. The body runs with no OpenFOAM installation and
# dispatches no workflow.
ad_run_baseline_step() {
    local mode="$1" workspace="$2" body="${3:-}" status=0
    mkdir -p -- "$workspace"
    [[ -n "$body" ]] ||
        body="$(ad_step_run_body "Resolve the OpenFOAM baseline")"
    [[ -n "$body" ]] ||
        _fail "the baseline-resolution step body is not extractable from the workflow"
    printf '%s\n' "$body" > "${workspace}/step_body.sh"
    bash -n "${workspace}/step_body.sh" ||
        _fail "the extracted baseline-resolution step body must parse"
    rm -f -- "${workspace}/.openfoam-version"
    case "$mode" in
        valid)      printf 'v2512\n'        > "${workspace}/.openfoam-version" ;;
        absent)     : ;;
        multiline)  printf 'v2512\nv2512\n' > "${workspace}/.openfoam-version" ;;
        mismatch)   printf 'v2506\n'        > "${workspace}/.openfoam-version" ;;
        no_newline) printf 'v2512'          > "${workspace}/.openfoam-version" ;;
        unreadable)
            printf 'v2512\n' > "${workspace}/.openfoam-version"
            chmod 000 -- "${workspace}/.openfoam-version" ;;
        *) _fail "unknown baseline fixture mode: ${mode}" ;;
    esac
    : > "${workspace}/github_env"
    (
        cd -- "$workspace" &&
        GITHUB_WORKSPACE="$workspace" GITHUB_ENV="${workspace}/github_env" \
            bash step_body.sh
    ) > "${workspace}/step.log" 2>&1 || status=$?
    printf '%s\n' "$status" > "${workspace}/step.status"
}

# ad_env_value <workspace> <key> - the last published value of one key.
ad_env_value() {
    awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1) }' \
        "${1}/github_env" | tail -n 1
}

# ad_env_malformed_lines <workspace> - published lines that are not KEY=VALUE.
# A multi-line value would corrupt the environment file, so this count must be
# zero for every fixture.
ad_env_malformed_lines() {
    awk '!/^[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' \
        "${1}/github_env"
}

o02_workflow_reads_baseline_after_checkout() {
    local checkout_index baseline_index install_index block
    checkout_index="$(ad_step_index "Record the checkout phase result")"
    baseline_index="$(ad_step_index "Resolve the OpenFOAM baseline")"
    install_index="$(ad_step_names |
        awk 'index($0, "Install OpenFOAM") == 1 { print NR; found = 1; exit }
             END { if (!found) print 0 }')"

    assert_ne 0 "$baseline_index" \
        "observation 2: the workflow has a baseline-resolution step"
    assert_ne 0 "$checkout_index" \
        "observation 2: the workflow keeps the checkout result step"
    assert_ne 0 "$install_index" \
        "observation 2: the workflow keeps the installation step"
    assert_eq 1 "$(( baseline_index > checkout_index ? 1 : 0 ))" \
        "observation 2: the baseline step follows the checkout result step"
    assert_eq 1 "$(( install_index > baseline_index ? 1 : 0 ))" \
        "observation 2: the installation step follows the baseline step"

    block="$(ad_step_block "Resolve the OpenFOAM baseline")"
    assert_contains "$block" "env.CHECKOUT_RESULT == 'SUCCEEDED'" \
        "observation 2: the baseline step runs only after a successful checkout"
    assert_contains "$block" ".openfoam-version" \
        "observation 2: the baseline step reads the committed baseline file"
}

o03_baseline_derives_package_and_bashrc() {
    local workspace
    workspace="$(new_workspace derive)"
    ad_run_baseline_step valid "$workspace"

    assert_eq 0 "$(cat "${workspace}/step.status")" \
        "observation 3: the baseline step succeeds for the exact target: $(cat "${workspace}/step.log")"
    assert_eq "$AD_BASELINE" "$(ad_env_value "$workspace" OPENFOAM_BASELINE)" \
        "observation 3: the step publishes the validated baseline"
    assert_eq "$AD_RELEASE" "$(ad_env_value "$workspace" OPENFOAM_RELEASE)" \
        "observation 3: the step derives the release token from the baseline"
    assert_eq "$AD_PACKAGE" "$(ad_env_value "$workspace" OPENFOAM_PACKAGE)" \
        "observation 3: the step derives the package name from the baseline"
    assert_eq "$AD_BASHRC" "$(ad_env_value "$workspace" OPENFOAM_BASHRC)" \
        "observation 3: the step derives the environment file path from the baseline"
    assert_eq "SUCCEEDED" "$(ad_env_value "$workspace" BASELINE_RESULT)" \
        "observation 3: the step records the successful baseline phase"
    assert_eq 0 "$(ad_env_malformed_lines "$workspace")" \
        "observation 3: every published line is one KEY=VALUE pair"
}

o07_invalid_baseline_fails_closed() {
    local mode workspace install_block prepare_block orchestrator_block

    for mode in absent multiline mismatch no_newline; do
        workspace="$(new_workspace "invalid_${mode}")"
        ad_run_baseline_step "$mode" "$workspace"

        assert_eq 0 "$(cat "${workspace}/step.status")" \
            "observation 7 (${mode}): the step ends with a recorded result, not an unhandled error"
        assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" BASELINE_RESULT)" \
            "observation 7 (${mode}): the step records the baseline infrastructure failure"
        assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" OVERALL_RESULT)" \
            "observation 7 (${mode}): the step records the overall infrastructure failure"
        assert_eq "false" "$(ad_env_value "$workspace" ORCHESTRATOR_STARTED)" \
            "observation 7 (${mode}): the step prevents the Orchestrator"
        assert_ne "" "$(ad_env_value "$workspace" BASELINE_REASON)" \
            "observation 7 (${mode}): the step records an exact reason"
        assert_ne "$AD_PACKAGE" "$(ad_env_value "$workspace" OPENFOAM_PACKAGE)" \
            "observation 7 (${mode}): the step derives no package from an invalid baseline"
        assert_ne "$AD_BASHRC" "$(ad_env_value "$workspace" OPENFOAM_BASHRC)" \
            "observation 7 (${mode}): the step derives no environment file path from an invalid baseline"
        assert_eq 0 "$(ad_env_malformed_lines "$workspace")" \
            "observation 7 (${mode}): the recorded reason stays one KEY=VALUE line"
    done

    # Installation, preparation, and the Orchestrator are gated, so none of them
    # starts after a baseline infrastructure failure.
    install_block="$(ad_step_block "$(ad_install_step_name)")"
    prepare_block="$(ad_step_block "Prepare the one-Case DOE Batch CSV")"
    orchestrator_block="$(ad_step_block "Run the Orchestrator")"
    assert_contains "$install_block" "env.BASELINE_RESULT == 'SUCCEEDED'" \
        "observation 7: installation starts only after a successful baseline"
    assert_contains "$prepare_block" "env.INSTALL_RESULT == 'SUCCEEDED'" \
        "observation 7: preparation starts only after a successful installation"
    assert_contains "$orchestrator_block" "env.PREPARE_RESULT == 'SUCCEEDED'" \
        "observation 7: the Orchestrator starts only after a successful preparation"
}

# ---- observations 4 and 10 --------------------------------------------------

o04_no_active_v2506_target() {
    local hits
    # The workflow keeps no v2506 reference at all, so no comment, label, or
    # value can reintroduce the superseded target.
    hits="$(grep -n '2506' "$WORKFLOW" || true)"
    assert_eq "" "$hits" \
        "observation 4: the workflow keeps no v2506 reference"
    assert_not_contains "$(cat -- "$WORKFLOW")" "openfoam2506" \
        "observation 4: the workflow names no v2506 package"
    assert_not_contains "$(cat -- "$WORKFLOW")" "openfoam/openfoam2506" \
        "observation 4: the workflow names no v2506 environment file path"
}

o10_version_bearing_labels() {
    local text
    text="$(cat -- "$WORKFLOW")"
    assert_contains "$text" "name: OpenFOAM ${AD_BASELINE} four-Stage evidence" \
        "observation 10: the job label names the accepted target"
    assert_contains "$text" "- name: Install OpenFOAM ${AD_BASELINE}" \
        "observation 10: the installation step label names the accepted target"
    assert_contains "$text" "## OpenFOAM ${AD_BASELINE} evidence run" \
        "observation 10: the job summary heading names the accepted target"
    assert_contains "$text" "name: openfoam-${AD_BASELINE}-evidence" \
        "observation 10: the evidence artifact name says the accepted target"
}

# ---- observations 5, 6, and 8 -----------------------------------------------

# ad_run_version_step <mode> <workspace> - execute the extracted
# environment-record step body against a controlled OpenFOAM environment file.
# The fixture file only exports the version values, so the observation needs no
# OpenFOAM installation. The run leaves github_env, step.log, and step.status
# in the workspace.
ad_run_version_step() {
    local mode="$1" workspace="$2" body bashrc status=0
    mkdir -p -- "${workspace}/evidence"
    body="$(ad_step_run_body "Record the OpenFOAM version")"
    [[ -n "$body" ]] ||
        _fail "the environment-record step body is not extractable from the workflow"
    printf '%s\n' "$body" > "${workspace}/step_body.sh"
    bash -n "${workspace}/step_body.sh" ||
        _fail "the extracted environment-record step body must parse"

    bashrc="${workspace}/fake_bashrc"
    rm -f -- "$bashrc"
    case "$mode" in
        match)
            printf 'export WM_PROJECT_VERSION=%s\nexport WM_OPTIONS=linux64GccDPInt32Opt\n' \
                "$AD_BASELINE" > "$bashrc" ;;
        mismatch)
            printf 'export WM_PROJECT_VERSION=v2506\nexport WM_OPTIONS=linux64GccDPInt32Opt\n' \
                > "$bashrc" ;;
        empty)
            printf 'export WM_PROJECT_VERSION=""\n' > "$bashrc" ;;
        absent)
            : ;;
        *) _fail "unknown environment fixture mode: ${mode}" ;;
    esac

    : > "${workspace}/github_env"
    (
        cd -- "$workspace" &&
        EVIDENCE_DIR="${workspace}/evidence" \
        OPENFOAM_BASHRC="$bashrc" \
        OPENFOAM_BASELINE="$AD_BASELINE" \
        OPENFOAM_PACKAGE="$AD_PACKAGE" \
        GITHUB_ENV="${workspace}/github_env" \
            bash step_body.sh
    ) > "${workspace}/step.log" 2>&1 || status=$?
    printf '%s\n' "$status" > "${workspace}/step.status"
}

o05_environment_step_requires_exact_version() {
    local body
    body="$(ad_step_run_body "Record the OpenFOAM version")"
    assert_ne "" "$body" \
        "observation 5: the environment-record step body is extractable"
    assert_contains "$body" 'source_status != 0' \
        "observation 5: the step requires source status 0"
    assert_contains "$body" '"$version" != "$OPENFOAM_BASELINE"' \
        "observation 5: the step requires the loaded version to equal the validated baseline"
    assert_not_contains "$body" '[[ -z "$version" ]]' \
        "observation 5: the step does not accept any non-empty version"
    assert_contains "$body" "INSTALL_RESULT=INFRASTRUCTURE_FAILURE" \
        "observation 5: a rejected version records an installation infrastructure failure"
    assert_contains "$body" "ORCHESTRATOR_STARTED=false" \
        "observation 5: a rejected version prevents the Orchestrator"
}

o06_orchestrator_step_requires_exact_version() {
    local body
    body="$(ad_step_run_body "Run the Orchestrator")"
    assert_ne "" "$body" \
        "observation 6: the Orchestrator step body is extractable"
    assert_contains "$body" '"${WM_PROJECT_VERSION:-}" != "$OPENFOAM_BASELINE"' \
        "observation 6: the Orchestrator step requires the exact validated baseline"
    assert_not_contains "$body" '[[ -z "${WM_PROJECT_VERSION:-}" ]]' \
        "observation 6: the Orchestrator step does not accept any non-empty version"
    assert_contains "$body" "ORCHESTRATOR_STARTED=false" \
        "observation 6: a rejected version prevents the Orchestrator"
}

o08_mismatched_loaded_version_fails_closed() {
    local mode workspace prepare_block orchestrator_block

    for mode in empty mismatch absent; do
        workspace="$(new_workspace "version_${mode}")"
        ad_run_version_step "$mode" "$workspace"

        assert_eq 0 "$(cat "${workspace}/step.status")" \
            "observation 8 (${mode}): the step ends with a recorded result, not an unhandled error"
        assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" INSTALL_RESULT)" \
            "observation 8 (${mode}): the step records the installation infrastructure failure"
        assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" OVERALL_RESULT)" \
            "observation 8 (${mode}): the step records the overall infrastructure failure"
        assert_eq "false" "$(ad_env_value "$workspace" ORCHESTRATOR_STARTED)" \
            "observation 8 (${mode}): the step prevents the Orchestrator"
        assert_ne "" "$(ad_env_value "$workspace" INSTALL_REASON)" \
            "observation 8 (${mode}): the step records an exact reason"
        assert_eq 0 "$(ad_env_malformed_lines "$workspace")" \
            "observation 8 (${mode}): the recorded reason stays one KEY=VALUE line"
        assert_file_missing "${workspace}/evidence/openfoam-version.txt" \
            "observation 8 (${mode}): the step records no identity for a rejected environment"
    done

    # The accepted version keeps the current successful path.
    workspace="$(new_workspace version_match)"
    ad_run_version_step match "$workspace"
    assert_eq 0 "$(cat "${workspace}/step.status")" \
        "observation 8 (match): the accepted version keeps status 0: $(cat "${workspace}/step.log")"
    # The step publishes OPENFOAM_VERSION only. It must not publish
    # WM_PROJECT_VERSION, because a later step would then inherit that value and
    # a failed environment load could pass the Orchestrator revalidation.
    assert_eq "$AD_BASELINE" "$(ad_env_value "$workspace" OPENFOAM_VERSION)" \
        "observation 8 (match): the step publishes the accepted version"
    assert_eq "" "$(ad_env_value "$workspace" WM_PROJECT_VERSION)" \
        "observation 8 (match): the step publishes no inheritable WM_PROJECT_VERSION"
    assert_eq "" "$(ad_env_value "$workspace" INSTALL_REASON)" \
        "observation 8 (match): the accepted version records no failure reason"

    # Preparation and the Orchestrator are gated on the earlier phase result, so
    # neither starts after this failure.
    prepare_block="$(ad_step_block "Prepare the one-Case DOE Batch CSV")"
    orchestrator_block="$(ad_step_block "Run the Orchestrator")"
    assert_contains "$prepare_block" "env.INSTALL_RESULT == 'SUCCEEDED'" \
        "observation 8: preparation starts only after a successful installation phase"
    assert_contains "$orchestrator_block" "env.PREPARE_RESULT == 'SUCCEEDED'" \
        "observation 8: the Orchestrator starts only after a successful preparation"
}

# ---- observation 9 ----------------------------------------------------------

o09_evidence_records_identity_fields() {
    local workspace identity field
    workspace="$(new_workspace identity)"
    ad_run_version_step match "$workspace"

    assert_eq 0 "$(cat "${workspace}/step.status")" \
        "observation 9: the environment-record step succeeds: $(cat "${workspace}/step.log")"
    assert_file_exists "${workspace}/evidence/openfoam-version.txt" \
        "observation 9: the step writes the environment identity record"
    identity="$(cat -- "${workspace}/evidence/openfoam-version.txt")"

    for field in OPENFOAM_BASELINE OPENFOAM_PACKAGE OPENFOAM_PACKAGE_VERSION \
                 OPENFOAM_BASHRC WM_PROJECT_VERSION WM_OPTIONS \
                 OS_IDENTITY ARCHITECTURE GCC_VERSION; do
        assert_contains "$identity" "${field}=" \
            "observation 9: the identity record holds ${field}"
    done
    for field in simpleFoam snappyHexMesh surfaceTransformPoints foamToVTK; do
        assert_contains "$identity" "${field}:" \
            "observation 9: the identity record holds the ${field} path"
    done

    assert_contains "$identity" "OPENFOAM_BASELINE=${AD_BASELINE}" \
        "observation 9: the identity record names the validated baseline"
    assert_contains "$identity" "OPENFOAM_PACKAGE=${AD_PACKAGE}" \
        "observation 9: the identity record names the derived package"
    assert_contains "$identity" "WM_PROJECT_VERSION=${AD_BASELINE}" \
        "observation 9: the identity record names the loaded version"

    # No required field is left empty. An unobtainable value is the explicit
    # UNAVAILABLE token, never a blank value and never an invented value.
    assert_eq 0 "$(awk -F= '
            /^(OPENFOAM_BASELINE|OPENFOAM_PACKAGE|OPENFOAM_PACKAGE_VERSION|OPENFOAM_BASHRC|WM_PROJECT_VERSION|WM_OPTIONS|OS_IDENTITY|ARCHITECTURE|GCC_VERSION)=/ {
                if (substr($0, index($0, "=") + 1) == "") { count++ }
            }
            END { print count + 0 }' "${workspace}/evidence/openfoam-version.txt")" \
        "observation 9: every recorded identity field holds a value"
}

# ---- observation 13 ---------------------------------------------------------

o13_batch_contract_path_filters() {
    local event block path
    for event in push pull_request; do
        block="$(ad_paths_block "$event")"
        assert_ne "" "$block" \
            "observation 13: the batch-contract ${event} filter is readable"
        for path in ".openfoam-version" ".github/workflows/openfoam-evidence.yml"; do
            assert_contains "$block" "- '${path}'" \
                "observation 13: the ${event} filter includes ${path}"
        done
        assert_contains "$block" "- '.github/workflows/batch-contract.yml'" \
            "observation 13: the ${event} filter keeps its existing workflow path"
        assert_contains "$block" "- 'tests/**'" \
            "observation 13: the ${event} filter keeps its existing test path"
    done
}

# ---- observations 11, 12, and 14 --------------------------------------------

o11_workflow_manual_and_not_required() {
    local on_block trigger jobs
    on_block="$(ad_on_block)"
    assert_ne "" "$on_block" "observation 11: the trigger block is readable"
    assert_contains "$on_block" "workflow_dispatch:" \
        "observation 11: the workflow starts through workflow_dispatch"
    for trigger in "push:" "pull_request:" "schedule:" "merge_group:" "workflow_call:"; do
        assert_not_contains "$on_block" "$trigger" \
            "observation 11: the workflow has no ${trigger} trigger"
    done
    assert_eq $'  workflow_dispatch:\n    inputs:\n      validation_only:\n        description: Validate workflow only. Run no product job.\n        type: boolean\n        required: false\n        default: false' \
        "$on_block" \
        "observation 11: workflow_dispatch has only the optional Boolean validation_only input, default false"

    # The job boundary: evidence is the only job, and its one job-level
    # condition makes it ineligible for a true validation_only input.
    jobs="$(awk '
        /^jobs:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]]/ { exit }
        inside && /^  [^[:space:]#]/ { print }
    ' "$WORKFLOW")"
    assert_eq "  evidence:" "$jobs" "observation 11: evidence is the only job"
    assert_contains "$(cat -- "$WORKFLOW")" $'\n  evidence:\n    name: OpenFOAM v2512 four-Stage evidence\n    runs-on: ubuntu-24.04\n    timeout-minutes: 120\n    if: ${{ !inputs.validation_only }}\n    defaults:\n' \
        "observation 11: the evidence job header holds the job-level validation_only condition"
    assert_eq 1 "$(grep -c '^    if:' "$WORKFLOW")" \
        "observation 11: the evidence job has one job-level condition"
    assert_eq $'      validation_only:\n    if: ${{ !inputs.validation_only }}' \
        "$(grep -F -- 'validation_only' "$WORKFLOW")" \
        "observation 11: only the input and the job-level condition name validation_only"
}

o12_preserved_accepted_behavior() {
    local text orchestrator prepare upload
    text="$(cat -- "$WORKFLOW")"

    assert_contains "$text" "permissions:"$'\n'"  contents: read" \
        "observation 12: the workflow keeps read-only content permission"
    assert_contains "$text" "  evidence:"$'\n' \
        "observation 12: the job id stays evidence"
    assert_contains "$text" "runs-on: ubuntu-24.04" \
        "observation 12: the runner stays ubuntu-24.04"
    assert_contains "$text" "timeout-minutes: 120" \
        "observation 12: the job timeout stays 120 minutes"

    orchestrator="$(ad_step_block "Run the Orchestrator")"
    assert_contains "$orchestrator" "--stage setup,mesh,flow,post-processing" \
        "observation 12: the Orchestrator runs the four accepted Stages"
    assert_contains "$orchestrator" "-j 1" \
        "observation 12: the Orchestrator keeps one Case job"
    assert_contains "$orchestrator" 'BATCH_STAGE_MPI_OVERSUBSCRIBE: "1"' \
        "observation 12: the Orchestrator step keeps the MPI oversubscription opt-in"
    assert_eq 0 "$(awk '/--stage / && /transport/ { count++ } END { print count + 0 }' \
        <<< "$orchestrator")" \
        "observation 12: the Stage selection names no transport Stage"

    prepare="$(ad_step_block "Prepare the one-Case DOE Batch CSV")"
    assert_contains "$prepare" '_ "$GITHUB_WORKSPACE" "7"' \
        "observation 12: the run keeps the existing Case 7 selection"
    assert_contains "$prepare" "src/output_batch_1.csv" \
        "observation 12: the run keeps the committed DOE Batch CSV as its source"

    upload="$(ad_step_block "Upload the evidence artifacts")"
    assert_contains "$upload" 'path: ${{ runner.temp }}/evidence' \
        "observation 12: the upload path stays the runner temporary directory"
    assert_contains "$upload" "if-no-files-found: error" \
        "observation 12: the upload guard stays error"
    assert_contains "$upload" "include-hidden-files: true" \
        "observation 12: the upload keeps the hidden Failure Artifact capture"
    assert_contains "$upload" "retention-days: 90" \
        "observation 12: the artifact retention stays 90 days"
}

o14_scenario_map_is_one_to_one() {
    local files spec readme
    files="$(find "${REPO_ROOT}/tests/cases" -maxdepth 1 -type f -name '*.sh' |
             wc -l | tr -d ' ')"
    spec="$(grep -c '^### [A-Z]\{1,2\}\. ' "$SPEC")"
    readme="$(grep -c '^| 23\.[A-Z]\{1,2\} |' "$TESTS_README")"

    assert_eq 30 "$files" "observation 14: tests/cases holds 30 Scenario files"
    assert_eq 30 "$spec" \
        "observation 14: specification Section 23 holds 30 Scenario entries"
    assert_eq 30 "$readme" "observation 14: the README map holds 30 Scenario rows"

    assert_contains "$(cat -- "$SPEC")" \
        "### AD. OpenFOAM version baseline and evidence-workflow contract" \
        "observation 14: the specification names Scenario AD"
    assert_contains "$(cat -- "$TESTS_README")" "| 23.AD |" \
        "observation 14: the README map names Scenario AD"
    assert_contains "$(cat -- "$TESTS_README")" "cases/ad_openfoam_version_contract.sh" \
        "observation 14: the README map names the Scenario AD file"
}

# ---- observation 15 ---------------------------------------------------------
#
# M1-R3 requires the baseline guard to reject a missing OR unreadable file.
# Observation 7 covers the missing file through the `! -f` condition. This
# observation covers the unreadable file, and it proves that the coverage
# detects the loss of the `! -r` condition.
#
# A regular file has no unreadable state for the root identity, so a behavioral
# execution of that branch cannot be identity-independent. This observation
# therefore has two identity-independent parts and two behavioral parts. The
# identity-independent parts always run and fail if the workflow loses the
# unreadable-file condition. The behavioral parts run when the current identity
# really cannot read a mode-000 file, which the scenario decides by one real
# read attempt and never by an identity number.

# ad_guard_requires_readable <body> - status 0 when the extracted baseline guard
# rejects a file that exists and denies read permission.
ad_guard_requires_readable() {
    [[ "$1" == *'! -r "$baseline_file"'* ]]
}

o15_unreadable_baseline_fails_closed() {
    local body mutated needle workspace fixture mutant_reason

    body="$(ad_step_run_body "Resolve the OpenFOAM baseline")"
    assert_ne "" "$body" \
        "observation 15: the baseline-resolution step body is extractable"

    # Part 1, identity-independent. The guard requires a readable file.
    ad_guard_requires_readable "$body" ||
        _fail "observation 15: the baseline guard must reject an unreadable file"

    # Part 2, identity-independent. The check above is load-bearing. A body
    # without the unreadable-file condition must not satisfy it, so this
    # observation fails if the workflow loses that behavior.
    needle=' || ! -r "$baseline_file"'
    mutated="${body//"$needle"/}"
    assert_ne "$body" "$mutated" \
        "observation 15: the mutation removes the unreadable-file condition"
    if ad_guard_requires_readable "$mutated"; then
        _fail "observation 15: the guard check must reject a body that lost the unreadable-file condition"
    fi

    workspace="$(new_workspace unreadable)"
    ad_run_baseline_step unreadable "$workspace"
    fixture="${workspace}/.openfoam-version"

    assert_file_exists "$fixture" \
        "observation 15: the fixture exists as a regular file"

    if [[ -r "$fixture" ]]; then
        # The root identity reads a mode-000 file, so this branch cannot be
        # executed here. Parts 1 and 2 already cover it without an identity.
        printf 'SKIP: the unreadable-baseline execution needs an identity that cannot read a mode-000 file (EUID=%s).\n' \
            "$EUID"
        return 0
    fi

    # Part 3, behavioral. The workflow guard rejects the unreadable baseline.
    assert_eq 0 "$(cat "${workspace}/step.status")" \
        "observation 15: the step ends with a recorded result, not an unhandled error"
    assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" BASELINE_RESULT)" \
        "observation 15: the step records the baseline infrastructure failure"
    assert_eq "INFRASTRUCTURE_FAILURE" "$(ad_env_value "$workspace" OVERALL_RESULT)" \
        "observation 15: the step records the overall infrastructure failure"
    assert_eq "false" "$(ad_env_value "$workspace" ORCHESTRATOR_STARTED)" \
        "observation 15: the step prevents the Orchestrator"
    assert_eq "the baseline file .openfoam-version is missing or unreadable" \
        "$(ad_env_value "$workspace" BASELINE_REASON)" \
        "observation 15: the step records the exact unreadable-file reason"
    assert_eq 1 "$(grep -c '^BASELINE_REASON=' "${workspace}/github_env")" \
        "observation 15: the recorded reason stays one line"
    assert_eq 0 "$(ad_env_malformed_lines "$workspace")" \
        "observation 15: every published line is one KEY=VALUE pair"
    assert_eq "" "$(ad_env_value "$workspace" OPENFOAM_PACKAGE)" \
        "observation 15: the step derives no package from an unreadable baseline"
    assert_eq "" "$(ad_env_value "$workspace" OPENFOAM_BASHRC)" \
        "observation 15: the step derives no environment file path from an unreadable baseline"
    assert_eq "" "$(ad_env_value "$workspace" OPENFOAM_BASELINE)" \
        "observation 15: the step publishes no baseline value"

    # Part 4, behavioral. The same fixture under a body that lost the
    # unreadable-file condition reaches the byte comparison instead, so it
    # records a different reason. The exact-reason assertion above therefore
    # fails when the workflow loses that behavior.
    workspace="$(new_workspace unreadable_mutant)"
    ad_run_baseline_step unreadable "$workspace" "$mutated"
    mutant_reason="$(ad_env_value "$workspace" BASELINE_REASON)"
    assert_ne "the baseline file .openfoam-version is missing or unreadable" \
        "$mutant_reason" \
        "observation 15: a body without the unreadable-file condition records a different reason"
    assert_ne "" "$mutant_reason" \
        "observation 15: the mutated body still records a reason"
}

# ---- observations 16 to 23: the collector FINAL reserve ---------------------
# Issue #80, annex 6354791264 Section 4: inert extraction, a fixture clock and
# stubs that run no supplied command. FINAL cap 10000 and used 0 are inputs.

# ad_metric_fn <name> - one exact function from standard input, dedented.
ad_metric_fn() {
    awk -v open="          $1() {" '
        $0 == open { n++; inside = 1 }
        inside { if ($0 != "" && substr($0, 1, 10) != "          ") bad = 1; print substr($0, 11) }
        inside && $0 == "          }" { inside = 0; closed++ }
        END { exit !(n == 1 && closed == 1 && !bad) }'
}

ad_sentinel() {
    printf '%s\n' "$1" >> "${AD_FX}/sentinel"
    printf 'SENTINEL: %s\n' "$1" >&2
    return 97
}

# ad_metric_load - permitted functions, METRIC_ numbers, stubs and sentinels.
ad_metric_load() {
    local fn text
    AD_FAILS=0
    AD_CAPTURE="$(ad_step_block "Capture the evidence")"
    for fn in metric_{op,seconds,text,fail,require,retain_logs,work,write_result,finish}; do
        text="$(ad_metric_fn "$fn" <<< "$AD_CAPTURE")" || { _fail "no single definition of ${fn}"; return 1; }
        eval "$text"
    done
    text="$(grep -E '^          METRIC_[A-Z_]+=[0-9]+$' <<< "$AD_CAPTURE" | sed 's/^ *//')"
    [[ -z "$(cut -d = -f 1 <<< "$text" | sort | uniq -d)" ]] || { _fail "a duplicate METRIC_ constant"; return 1; }
    eval "$text"
    metric_now_ms() { local t; read -r t < "${AD_FX}/clock"; printf '%s\n' "$t"; }
    metric_stop_group() { M_STOP="$AD_STOP"; [[ "$M_STOP" != NOT_STOPPED ]]; }
    # The stub never runs its arguments.
    timeout() {
        printf '%s %s\n' "$1" "$2" >> "${AD_FX}/vectors"
        printf '%s' "$AD_OUT"
        printf '%s' "$AD_ERR" >&2
        printf '%s\n' "$(( $(cat "${AD_FX}/clock") + AD_MS ))" > "${AD_FX}/clock"
        return "$AD_STATUS"
    }
    for fn in prlimit sudo kill foamListTimes simpleFoam metric_{collect,identity,cleanup,process_check,selection} \
              metric_{inputs,manifest,task_bytes,compare,foam_op,output,values}; do
        eval "${fn}() { ad_sentinel ${fn}; }"
    done
    metric_source() { return 0; }
    capture_note() { printf '%s\n' "$1" >> "${AD_FX}/notes"; }
}

# ad_fx <name> - clock 1000000 ms; metric end 170000 ms later.
ad_fx() {
    AD_FX="$(new_workspace "$1")"
    mkdir -p "${AD_FX}/logs"
    printf '1000000\n' > "${AD_FX}/clock"
    : > "${AD_FX}/vectors"
    M_DIR="$AD_FX" M_LOG_DIR="${AD_FX}/logs" M_OUT_FILE="" M_ERR_FILE="" M_RECORD="" M_FSIZE="" M_OP_END=""
    M_SEQ=0 M_SELECT_USED=0 M_CALC_USED=0 M_WORK_USED=0 M_FINAL_USED=0 M_CLEANUP_USED=0 M_END_MS=1170000
    M_GROUPS=()
    M_CODE="" M_REASON="" M_POINT=fixture M_FAIL_POINT=NONE M_CHECK_SOURCE_SHA=fixture
    METRIC_FINAL_MS=10000 METRIC_ROOT_CHECK_SOURCE="fixed check source"
    AD_MS=0 AD_STATUS=0 AD_OUT="" AD_ERR="" AD_STOP=EMPTY
}

# ad_op <label> <class> <advance-ms> [status]
ad_op() {
    AD_MS="$3" AD_STATUS="${4:-0}"
    metric_op "$1" "$2" fixture-command
}

# ad_state - limit outcome count [TERM] SELECT/CALC/WORK/FINAL/CLEANUP used.
ad_state() {
    printf '%s %s %s [%s] %s/%s/%s/%s/%s' "$M_LIMIT" "$M_OUTCOME" "$(wc -l < "${AD_FX}/vectors")" \
        "$(tail -n 1 "${AD_FX}/vectors" | cut -d ' ' -f 2)" \
        "$M_SELECT_USED" "$M_CALC_USED" "$M_WORK_USED" "$M_FINAL_USED" "$M_CLEANUP_USED"
}

# ad_check <message> <expected> <actual>
ad_check() {
    [[ "$2" == "$3" ]] && return 0
    AD_FAILS=$(( AD_FAILS + 1 ))
    _fail "$1" "expected: [$2]" "actual:   [$3]" || true
}

ad_done() { (( AD_FAILS == 0 )) || _fail "$1: ${AD_FAILS} failed checks"; }

ad_result_fixture() {
    local f
    for f in M_{VALUE,POST_TIME,SELECTION_VECTOR,METRIC_VECTOR,DICT_BYTES,DICT_SHA,INPUT_FILES,INPUT_BYTES} \
             M_{INPUTS_UNCHANGED,TASK_BYTES,COPY_FSIZE,CALC_FSIZE,OUTPUT_PATH,OUTPUT_SHA,OLDER_UNREADABLE} \
             M_{CLEANUP_START,CHECK_END,CLEANUP_END,EVIDENCE_BYTES,INVENTORY,START_MS} \
             M_O_{ROW_TIME,REGION,COLUMNS,CELLS,VOLUME,ROW_VALUE} M_CHECK_{RESULT,TOKEN,LAUNCH_CS,ENTRY,SCAN} \
             M_CHECK_{MONITOR,CHILD,STOPPED} SELECTED_TIME ORIGINAL_RUNNER_UID CHECK_END_BOOT_CS; do
        printf -v "$f" '%s' UNAVAILABLE
    done
    M_CLEANUP=NOT_NEEDED M_LOGS_RETAINED=NO M_LOG_BYTES=0
}

ad_values() {
    local key out=""
    for key; do
        out+="$(grep -m 1 "^${key}=" "${M_DIR}/result.env" | cut -d = -f 2- || true)|"
    done
    printf '%s' "${out%|}"
}

o16_collector_partition_source() {
    local cap op c fn all=""
    AD_FAILS=0
    cap="$(ad_step_block "Capture the evidence")"
    for c in TOTAL_MS=180000 SELECT_MS=10000 CALC_MS=60000 WORK_MS=80000 FINAL_MS=10000 CLEANUP_MS=20000 \
             CHECK_MS=12000 REMOVE_MS=8000 KILL_GRACE_MS=5000 STOP_RESERVE_MS=1000; do
        ad_check "o16: METRIC_${c} once" 1 "$(grep -cx -- "          METRIC_${c}" <<< "$cap" || true)"
    done
    op="$(ad_metric_fn metric_op <<< "$cap" || true)"
    ad_check "o16: split charge, FINAL_USED_MS, one FINAL ledger start" "1 0 1 1 1" \
        "$(grep -cF 'M_FINAL_USED=$(( M_FINAL_USED + M_ELAPSED ))' <<< "$op" || true) $(grep -cF 'WORK|FINAL)' <<< "$op" || true) $(ad_metric_fn metric_write_result <<< "$cap" | grep -cF 'echo "FINAL_USED_MS=${M_FINAL_USED}"' || true) $(grep -o 'M_FINAL_USED=0' <<< "$cap" | wc -l) $(ad_metric_fn metric_collect <<< "$cap" | grep -c 'M_FINAL_USED=0' || true)"
    ad_check "o16: collection order" $'metric_work || true\nmetric_retain_logs\nmetric_cleanup\nmetric_finish' \
        "$(ad_metric_fn metric_collect <<< "$cap" | grep -xE '    (metric_work \|\| true|metric_retain_logs|metric_cleanup|metric_finish)' | sed 's/^    //' || true)"
    for fn in metric_{now_ms,stop_group,identity,selection,inputs,output,retain_logs,cleanup,process_check,finish}; do
        all+="$(ad_metric_fn "$fn" <<< "$cap" || true)"$'\n'
    done
    ad_check "o16: frozen functions as at M" b6c0fbbe5f1aed8e828a5efded83fe20168f2b4608157c543318e3deb32c649d \
        "$(printf '%s' "$all" | sha256sum | cut -d ' ' -f 1)"
    ad_done o16
}

o17_work_and_final_ledgers_are_independent() {
    ad_metric_load
    ad_fx o17a; M_WORK_USED=80000
    ad_op work WORK 1000
    ad_check "o17: WORK used 80000, no WORK child" "0 NOT_STARTED 0 [] 0/0/80000/0/0" "$(ad_state)"
    ad_op final FINAL 1000
    ad_check "o17: FINAL used 0 still has 10000 ms" "10000 COMPLETED 1 [4.000] 0/0/80000/1000/0" "$(ad_state)"
    ad_fx o17b
    ad_op final FINAL 1000
    ad_check "o17: FINAL 1000 ms charges only FINAL" "10000 COMPLETED 1 [4.000] 0/0/0/1000/0" "$(ad_state)"
    ad_fx o17c; M_FINAL_USED=10000
    ad_op final FINAL 1000
    ad_check "o17: FINAL used 10000, no FINAL child" "0 NOT_STARTED 0 [] 0/0/0/10000/0" "$(ad_state)"
    ad_op work WORK 1000
    ad_check "o17: spent FINAL does not refill WORK" "80000 COMPLETED 1 [74.000] 0/0/1000/10000/0" "$(ad_state)"
    ad_fx o17d
    ad_op final-1 FINAL 2000
    ad_op final-2 FINAL 2000
    ad_op final-3 FINAL 2000
    ad_check "o17: 2 x 2000 ms FINAL leave 6000; third starts nothing" "6000 NOT_STARTED 2 [2.000] 0/0/0/4000/0" "$(ad_state)"
    M_FINAL_USED=10500 M_WORK_USED=80500
    ad_op final-4 FINAL 1000
    ad_op work WORK 1000
    ad_check "o17: over-cap ledgers start nothing and stay" "-500 NOT_STARTED 2 [2.000] 0/0/80500/10500/0" "$(ad_state)"
    ad_done o17
}

o18_absolute_and_operation_ends() {
    ad_metric_load
    ad_fx o18a; M_END_MS=1036000
    ad_op work WORK 0
    ad_check "o18: R 36000, unused FINAL 10000: limit 6000, no child" "6000 NOT_STARTED 0 [] 0/0/0/0/0" "$(ad_state)"
    ad_fx o18b; M_END_MS=1036001
    ad_op work WORK 0
    ad_check "o18: R 36001: limit 6001, TERM after 1 ms, KILL grace 5 s" \
        "6001 COMPLETED 1 [0.001] 0/0/0/0/0 --kill-after=5.000 0.001" "$(ad_state) $(cat "${AD_FX}/vectors")"
    ad_fx o18c; M_OP_END=1005000
    ad_op work WORK 0
    ad_check "o18: operation end start+5000 prevents launch" "5000 NOT_STARTED 0 [] 0/0/0/0/0 []" "$(ad_state) [${M_OP_END}]"
    ad_fx o18d
    ad_op other UNKNOWN 1000
    ad_check "o18: unknown class starts nothing" "0 NOT_STARTED 0 [] 0/0/0/0/0" "$(ad_state)"
    ad_done o18
}

o19_cleanup_reserves() {
    ad_metric_load
    ad_fx o19a; M_END_MS=1026000
    ad_op final FINAL 0
    ad_check "o19: FINAL keeps full cleanup; R 26000 starts nothing" "6000 NOT_STARTED 0 [] 0/0/0/0/0" "$(ad_state)"
    ad_fx o19b; M_END_MS=1100000
    ad_op work WORK 0
    ad_check "o19: work keeps unused FINAL and full cleanup" "70000 COMPLETED 1 [64.000] 0/0/0/0/0" "$(ad_state)"
    ad_fx o19c; M_CLEANUP_USED=20000 M_END_MS=1009000
    ad_op final FINAL 0
    ad_check "o19: after 20000 ms cleanup, FINAL R 9000 uses 9000" "9000 COMPLETED 1 [3.000] 0/0/0/0/20000" "$(ad_state)"
    ad_check "o19: cleanup partitions and source as at M" "12000 8000 53f2104e13cd1025ed6bb150720cb95513f8136334cfd389982dd73bad3c91af" \
        "${METRIC_CHECK_MS} ${METRIC_REMOVE_MS} $(ad_metric_fn metric_cleanup <<< "$AD_CAPTURE" | sha256sum | cut -d ' ' -f 1)"
    ad_done o19
}

# ad_retain <name> <inventory> <hashes> [fail-label] - stubbed retention.
ad_retain() {
    ad_fx "$1"
    TASK_TEMP="${AD_FX}/task"
    mkdir -p "${TASK_TEMP}/logs"
    AD_INVENTORY="$2" AD_HASHES="$3" AD_FAIL_LABEL="${4:-}"
    M_CODE=TIMEOUT M_REASON="identity timeout" M_LOG_BYTES=0 M_LOGS_RETAINED=NO
    metric_op() {
        local label="$1"
        M_OUT="${AD_FX}/${label}.out" M_STATUS=0 M_OUTCOME=COMPLETED M_LIMIT=10000 M_GROUP=-
        printf '%s\n' "$label" >> "${AD_FX}/labels"
        case "$label" in
            log-sizes) printf '%s' "$AD_INVENTORY" > "$M_OUT" ;;
            copy-logs) shift 4; set -- "${@:1:$#-1}"; printf '%s\n' "${@##*/}" > "$M_OUT" ;;
            hash-excluded) printf '%s' "$AD_HASHES" > "$M_OUT" ;;
            *) ad_sentinel "metric_op ${label}"; return 97 ;;
        esac
        if [[ "$label" == "$AD_FAIL_LABEL" ]]; then
            M_STATUS=1 M_OUTCOME=FAILED
        fi
    }
    metric_retain_logs > "${AD_FX}/retain.out"
    printf '%s %s %s %s [%s] [%s] [%s]' "$M_LOGS_RETAINED" "$M_LOG_BYTES" "$M_CODE" "$(paste -sd , "${AD_FX}/labels")" \
        "$(cat "${AD_FX}/copy-logs.out" 2> /dev/null | paste -sd , || true)" "$(tail -n +2 "${AD_FX}/excluded.tsv" | paste -sd '|')" \
        "$(grep -o 'RESOURCE_LIMIT: .*' "${AD_FX}/retain.out" | paste -sd '|' || true)"
}

o20_bounded_failure_streams() {
    local h eight="" kept n
    local reason=$'\tthe log is above a log limit'
    h="$(printf '%064d' 7)"
    ad_metric_load
    ad_fx o20a; AD_OUT=$'partial out\n' AD_ERR=$'partial err\n'
    ad_op read WORK 1000 124
    ad_check "o20: stopped operation keeps partial streams" "TIMEOUT|partial out|partial err" \
        "${M_OUTCOME}|$(cat "$M_OUT")|$(cat "$M_ERR")"
    ad_check "o20: a 1048576-byte log stays" "YES 1048576 TIMEOUT log-sizes,copy-logs [a.log] [] []" \
        "$(ad_retain o20b $'1048576\ta.log\n' "")"
    ad_check "o20: 1048577-byte log excluded with size, hash, failure" \
        "PARTIAL 0 TIMEOUT log-sizes,hash-excluded [] [b.log"$'\t'"1048577"$'\t'"${h}${reason}] [RESOURCE_LIMIT: the log b.log has 1048577 bytes, above 1048576]" \
        "$(ad_retain o20c $'1048577\tb.log\n' "b.log"$'\t'"1048577"$'\t'"${h}${reason}"$'\n')"
    for n in a b c d e f g h; do
        eight+="1048576"$'\t'"${n}.log"$'\n'
    done
    kept=a.log,b.log,c.log,d.log,e.log,f.log,g.log,h.log
    ad_check "o20: exactly 8388608 log bytes stay" "YES 8388608 TIMEOUT log-sizes,copy-logs [${kept}] [] []" \
        "$(ad_retain o20d "$eight" "")"
    ad_check "o20: next one-byte log excluded, failure" \
        "PARTIAL 8388608 TIMEOUT log-sizes,copy-logs,hash-excluded [${kept}] [i.log"$'\t1\t'"${h}${reason}] [RESOURCE_LIMIT: the kept logs are above 8388608 bytes together]" \
        "$(ad_retain o20e "${eight}1"$'\ti.log\n' "i.log"$'\t1\t'"${h}${reason}"$'\n')"
    ad_check "o20: failed copy is explicit no-retention" "NO_FAILED 10 TIMEOUT log-sizes,copy-logs [a.log] [] []" \
        "$(ad_retain o20f $'10\ta.log\n' "" copy-logs)"
    ad_done o20
}

o21_first_failure_blocks_downstream() {
    local status reason="the identity operation did not complete within its 89921 ms limit"
    ad_metric_load
    ad_fx o21a
    RUNNER_TEMP="${AD_FX}/runner" METRIC_TASK_SCRIPT=fixed METRIC_INVENTORY_SCRIPT=fixed
    TASK_TEMP="" CASE_DIR="" AD_OUT="${AD_FX}/runner/m3-metric-collection.ABCDEFGH"$'\n'
    metric_identity() { metric_fail TIMEOUT "$reason"; return 1; }
    ad_result_fixture
    metric_work > "${AD_FX}/work.out" && status=0 || status=$?
    metric_write_result UNAVAILABLE "$M_CODE" "$M_REASON"
    ad_check "o21: identity TIMEOUT blocks downstream; no scalar" "1 none 1 UNAVAILABLE|TIMEOUT|UNAVAILABLE|environment" \
        "${status} $(cat "${AD_FX}/sentinel" 2> /dev/null || echo none) $(wc -l < "${AD_FX}/vectors") $(ad_values MEAN_SPEED_VERDICT MEAN_SPEED_REASON_CODE MEAN_SPEED_VALUE MEAN_SPEED_STOP_POINT)"
    # Simulated later refusals; no cleanup runs.
    M_LOGS_RETAINED=NO_TIMEOUT M_CLEANUP=REFUSED_PROCESS_ACTIVE
    metric_fail CLEANUP_FAILURE "process group 4242 still has a process, so the task directory stays" > /dev/null
    AD_OUT="" AD_STATUS=124
    metric_finish > "${AD_FX}/finish.out"
    ad_check "o21: later refusal keeps first reason, no removal" \
        "UNAVAILABLE|TIMEOUT|UNAVAILABLE|REFUSED_PROCESS_ACTIVE|NO_TIMEOUT|UNAVAILABLE_TIMEOUT|M3 mean speed: TIMEOUT: ${reason}" \
        "$(ad_values MEAN_SPEED_VERDICT MEAN_SPEED_REASON_CODE MEAN_SPEED_VALUE CLEANUP_RESULT LOGS_RETAINED INVENTORY)|$(cat "${AD_FX}/notes" 2> /dev/null || true)"
    ad_done o21
}

o22_normal_trace_charges_each_class() {
    ad_metric_load
    ad_fx o22a
    ad_op select SELECT 1000
    ad_op work WORK 2000
    ad_op calc CALC 3000
    ad_op final FINAL 500
    ad_op remove CLEANUP 4000
    ad_op final-2 FINAL 500
    ad_check "o22: fixed trace TERM intervals and ledgers" "4.000 74.000 54.000 4.000 14.000 3.500 1000/3000/2000/1000/4000" \
        "$(cut -d ' ' -f 2 "${AD_FX}/vectors" | paste -sd ' ') ${M_SELECT_USED}/${M_CALC_USED}/${M_WORK_USED}/${M_FINAL_USED}/${M_CLEANUP_USED}"
    ad_result_fixture
    M_VALUE=1.5
    metric_write_result AVAILABLE NONE "a synthetic trace"
    # SHA-256 of the 62 field names: those of M plus FINAL_USED_MS.
    ad_check "o22: result fields plus FINAL_USED_MS" 24f9a7b794301e315243accac48591ce2c73b364034da0960a3d0ee48d6f1f5b \
        "$(cut -d = -f 1 "${M_DIR}/result.env" | paste -sd ' ' | sha256sum | cut -d ' ' -f 1)"
    ad_check "o22: values and both caps in LIMITS" "AVAILABLE|1.5|2000|1000 1" \
        "$(ad_values MEAN_SPEED_VERDICT MEAN_SPEED_VALUE WORK_USED_MS FINAL_USED_MS) $(grep -c 'evidence 80000 ms; final log copy and inventory 10000 ms; cleanup 20000 ms' "${M_DIR}/result.env" || true)"
    ad_done o22
}

o23_extraction_and_stub_sensitivity() {
    local text mutant value
    local new='FINAL) M_FINAL_USED=$(( M_FINAL_USED + M_ELAPSED )) ;;' old='FINAL) M_WORK_USED=$(( M_WORK_USED + M_ELAPSED )) ;;'
    ad_metric_load
    ad_fx o23_extraction
    value=""
    ad_metric_fn metric_op <<< "${AD_CAPTURE/"          metric_op() {"/"          metric_op_gone() {"}" > /dev/null && value+=found || value+=rejected
    ad_metric_fn metric_op <<< "${AD_CAPTURE}"$'\n          metric_op() {\n          }' > /dev/null && value+=" found" || value+=" rejected"
    ad_check "o23: missing, duplicate boundaries rejected" "rejected rejected" "$value"
    text="$(ad_metric_fn metric_op <<< "$AD_CAPTURE" || true)"
    mutant="${text/"$new"/"$old"}"
    [[ "$mutant" != "$text" ]] && value=changed || value=unchanged
    eval "$mutant"
    ad_fx o23a
    ad_op final FINAL 1000
    [[ "$(ad_state)" != "10000 COMPLETED 1 [4.000] 0/0/0/1000/0" ]] && value+=" detected" || value+=" missed"
    ad_check "o23: oracle rejects the shared-charge mutant" "changed detected" "$value"
    ad_fx o23b
    prlimit --core=0 2> /dev/null && value=0 || value=$?
    ad_check "o23: a forbidden command sentinel fails loudly" "97 prlimit" "${value} $(cat "${AD_FX}/sentinel")"
    ad_done o23
}

# ---- observation registry ---------------------------------------------------

AD_OBSERVATIONS=(
    o01_baseline_file_exact_bytes
    o02_workflow_reads_baseline_after_checkout
    o03_baseline_derives_package_and_bashrc
    o07_invalid_baseline_fails_closed
    o04_no_active_v2506_target
    o10_version_bearing_labels
    o05_environment_step_requires_exact_version
    o06_orchestrator_step_requires_exact_version
    o08_mismatched_loaded_version_fails_closed
    o09_evidence_records_identity_fields
    o13_batch_contract_path_filters
    o11_workflow_manual_and_not_required
    o12_preserved_accepted_behavior
    o14_scenario_map_is_one_to_one
    o15_unreadable_baseline_fails_closed
    o16_collector_partition_source
    o17_work_and_final_ledgers_are_independent
    o18_absolute_and_operation_ends
    o19_cleanup_reserves
    o20_bounded_failure_streams
    o21_first_failure_blocks_downstream
    o22_normal_trace_charges_each_class
    o23_extraction_and_stub_sensitivity
)

# One observation runs in this process when the caller names it. The scenario
# runner never uses this form; the scenario itself uses it for each child.
if [[ "${1:-}" == "--observation" ]]; then
    "$2"
    exit 0
fi

failed_observations=()
for observation in "${AD_OBSERVATIONS[@]}"; do
    if bash "${BASH_SOURCE[0]}" --observation "$observation" 2>&1 |
            sed -e "s/^/  [${observation}] /"; then
        printf 'OBSERVATION PASS: %s\n' "$observation"
    else
        printf 'OBSERVATION FAIL: %s\n' "$observation"
        failed_observations+=("$observation")
    fi
done

printf '\nObservations : %s\n' "${#AD_OBSERVATIONS[@]}"
printf 'Failed       : %s\n' "${#failed_observations[@]}"

if (( ${#failed_observations[@]} > 0 )); then
    printf 'Failed observations: %s\n' "${failed_observations[*]}" >&2
    exit 1
fi
