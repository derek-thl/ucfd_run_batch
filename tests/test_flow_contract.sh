#!/usr/bin/env bash
# Focused Issue #7 regression tests for the flow reconstruction-mode preflight.
#
# Covered requirements:
#   * RECONSTRUCT_MODE=none must not require or execute reconstructPar.
#   * RECONSTRUCT_MODE=latest and all must keep requiring reconstructPar and
#     must keep their exact command arguments.
#   * A missing mode-required command must fail before solver execution.
#   * Wall-distance compatibility behavior stays unchanged.
#
# Usage:
#   bash tests/test_flow_contract.sh
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

CONTRACT_TEST_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ucfd-flow-focus.XXXXXXXX")"
CONTRACT_TEST_NAME="flow_focus"
export CONTRACT_TEST_RUN_DIR CONTRACT_TEST_NAME

cleanup() {
    case "$CONTRACT_TEST_RUN_DIR" in
        /tmp/*|/var/tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf -- "$CONTRACT_TEST_RUN_DIR" ;;
    esac
}
trap cleanup EXIT

source "${TESTS_DIR}/lib/harness.sh"
source "${TESTS_DIR}/lib/assert.sh"

set -e

PASS_COUNT=0
report() { PASS_COUNT=$(( PASS_COUNT + 1 )); printf 'PASS %s\n' "$1"; }

# new_flow_fixture <name> - one meshed flow case ready to solve.
new_flow_fixture() {
    local name="$1"
    workspace="$(new_workspace "$name")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
    make_flow_mesh "${workspace}/case_0/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_0/flow/0/wallDistance"
    summary="${workspace}/run_flow_cases_summary.csv"
}

run_flow() {
    ( cd "$workspace" && env "$@" bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
}

# build_restricted_path - print a PATH that contains only the fake commands
# plus a minimal tool directory. A host with a real OpenFOAM installation must
# not satisfy a command check after remove_fake, so the missing-command
# scenarios run the flow script under this PATH.
build_restricted_path() {
    local tools_dir="${workspace}/_tools_bin" tool resolved
    mkdir -p "$tools_dir"
    for tool in bash sh env awk sed tee date tr wc find sort grep head tail \
        mkdir rmdir rm cp mv touch cat basename dirname readlink realpath \
        sleep ls paste cut mktemp; do
        resolved="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$resolved" ]] && ln -sf "$resolved" "${tools_dir}/${tool}"
    done
    printf '%s:%s\n' "$FAKE_BIN_DIR" "$tools_dir"
}

# ---- 1. none mode succeeds without reconstructPar ------------------------------

new_flow_fixture none_ok
remove_fake reconstructPar
restricted="$(build_restricted_path)"

out="$(run_flow RECONSTRUCT_MODE=none CLEAN_PROCESSORS=0 PATH="$restricted")" \
    && status=0 || status=$?

assert_status 0 "$status" "none mode must succeed without reconstructPar: $out"
assert_eq 1 "$(summary_status_count "$summary" solved)" \
    "the none-mode case is solved"
assert_eq 0 "$(fake_call_count reconstructPar)" \
    "none mode records no reconstructPar invocation"
assert_eq 1 "$(fake_call_count simpleFoam)" "the flow solver runs once"
assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
    "Skipping reconstructPar (RECONSTRUCT_MODE=none)." \
    "none mode reports the skipped reconstruction"
report "test_none_mode_independent_of_reconstructpar"

# ---- 2. latest mode fails preflight without reconstructPar ---------------------

new_flow_fixture latest_missing
remove_fake reconstructPar
restricted="$(build_restricted_path)"

out="$(run_flow RECONSTRUCT_MODE=latest CLEAN_PROCESSORS=0 PATH="$restricted")" \
    && status=0 || status=$?

# The case-level preflight rejects the missing command before solver
# execution. The stage-level exit status for a flow case failure is the
# known Issue #9 propagation gap and is not asserted here.
assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
    "'reconstructPar' not found in PATH." \
    "latest mode requires reconstructPar and names the missing command"
assert_eq 0 "$(fake_call_count simpleFoam)" \
    "the preflight failure occurs before solver execution"
assert_eq 0 "$(summary_status_count "$summary" solved)" \
    "the latest-mode case is not summarized as solved"
report "test_latest_mode_requires_reconstructpar"

# ---- 3. all mode fails preflight without reconstructPar ------------------------

new_flow_fixture all_missing
remove_fake reconstructPar
restricted="$(build_restricted_path)"

out="$(run_flow RECONSTRUCT_MODE=all CLEAN_PROCESSORS=0 PATH="$restricted")" \
    && status=0 || status=$?

assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
    "'reconstructPar' not found in PATH." \
    "all mode requires reconstructPar and names the missing command"
assert_eq 0 "$(fake_call_count simpleFoam)" \
    "the preflight failure occurs before solver execution"
assert_eq 0 "$(summary_status_count "$summary" solved)" \
    "the all-mode case is not summarized as solved"
report "test_all_mode_requires_reconstructpar"

# ---- 4. latest and all keep their exact command arguments ----------------------

new_flow_fixture latest_args
out="$(run_flow RECONSTRUCT_MODE=latest CLEAN_PROCESSORS=0)" && status=0 || status=$?
assert_status 0 "$status" "latest mode must succeed with reconstructPar: $out"
assert_eq "$(argv_line -latestTime)" "$(fake_argvs reconstructPar)" \
    "latest mode executes reconstructPar -latestTime"
report "test_latest_mode_arguments_unchanged"

new_flow_fixture all_args
out="$(run_flow RECONSTRUCT_MODE=all CLEAN_PROCESSORS=0)" && status=0 || status=$?
assert_status 0 "$status" "all mode must succeed with reconstructPar: $out"
assert_eq "$(argv_line)" "$(fake_argvs reconstructPar)" \
    "all mode executes reconstructPar with no arguments"
report "test_all_mode_arguments_unchanged"

# ---- 5. other command prerequisites stay required -------------------------------

new_flow_fixture solver_missing
remove_fake simpleFoam
restricted="$(build_restricted_path)"

out="$(run_flow RECONSTRUCT_MODE=none CLEAN_PROCESSORS=0 PATH="$restricted")" \
    && status=0 || status=$?

assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
    "'simpleFoam' not found in PATH." \
    "a missing solver is still rejected in none mode"
assert_eq 0 "$(fake_call_count decomposePar)" \
    "the missing-solver preflight stops before any case command"
assert_eq 0 "$(summary_status_count "$summary" solved)" \
    "the missing-solver case is not summarized as solved"
report "test_other_prerequisites_stay_required"

# ---- 6. wall-distance compatibility stays unchanged ------------------------------

# 6a. An existing 0/wallDistance skips the checkMesh fallback.
new_flow_fixture walldistance_skip
out="$(run_flow RECONSTRUCT_MODE=none CLEAN_PROCESSORS=0)" && status=0 || status=$?
assert_status 0 "$status" "the wallDistance-present case must succeed: $out"
assert_eq 0 "$(fake_call_count checkMesh)" \
    "an existing wallDistance skips the checkMesh fallback"
report "test_walldistance_skip_unchanged"

# 6b. A missing 0/wallDistance runs the exact checkMesh fallback.
workspace="$(new_workspace walldistance_fallback)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
summary="${workspace}/run_flow_cases_summary.csv"

out="$(run_flow RECONSTRUCT_MODE=none CLEAN_PROCESSORS=0)" && status=0 || status=$?
assert_status 0 "$status" "the wallDistance-missing case must succeed: $out"
assert_eq "$(argv_line -writeAllFields -time 0)" "$(fake_argvs checkMesh)" \
    "the fallback runs checkMesh -writeAllFields -time 0"
assert_file_exists "${workspace}/case_0/flow/0/wallDistance" \
    "the fallback creates 0/wallDistance"
report "test_walldistance_fallback_unchanged"

printf '\nAll %s focused flow contract tests passed.\n' "$PASS_COUNT"
