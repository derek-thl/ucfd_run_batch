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
    local on_block trigger
    on_block="$(ad_on_block)"
    assert_ne "" "$on_block" "observation 11: the trigger block is readable"
    assert_contains "$on_block" "workflow_dispatch:" \
        "observation 11: the workflow starts through workflow_dispatch"
    for trigger in "push:" "pull_request:" "schedule:" "merge_group:" "workflow_call:"; do
        assert_not_contains "$on_block" "$trigger" \
            "observation 11: the workflow has no ${trigger} trigger"
    done
    assert_contains "$on_block" "  workflow_dispatch:" \
        "observation 11: workflow_dispatch needs no input"
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
