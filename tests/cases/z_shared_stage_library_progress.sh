#!/usr/bin/env bash
# Section 23.Z - shared Stage progress primitives (Issue #53).
#
# This scenario characterizes the aggregate-progress timing gate and the
# aggregate-progress active-process count of all five Stage Runners, and then
# proves that the four aggregate-progress Stage Runners delegate to the shared
# helpers.
#
# Every assertion uses a direct Stage Runner CLI, the process status, the
# console output, the Batch Workspace artifacts, or a test control record that
# lives outside every Batch Workspace. No assertion sources lib_batch_stage.sh,
# and no assertion calls a shared helper or a private Stage Runner function.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every Stage Runner invocation has a finite timeout. Status 124 is never an
# accepted result.
STAGE_TIMEOUT=180

# Test control records live in a sibling directory of the Batch Workspaces,
# under CONTRACT_TEST_RUN_DIR, so no record enters a Batch Workspace.
CONTROL_ROOT="${CONTRACT_TEST_RUN_DIR}/z_controls"
mkdir -p "$CONTROL_ROOT"

# The clock-controlled timing group needs `wait -n`, because the free-slot and
# final-drain callbacks of a Bash 4.0 through 4.2 host use the polling fallback
# path. Scenario X remains the required forced fallback-path evidence.
if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    TIMING_GROUP=1
else
    TIMING_GROUP=0
    printf 'SKIP: clock-controlled timing group. This Bash has no wait -n.\n'
    printf 'SKIP: Scenario X keeps the forced fallback-path evidence.\n'
fi

# =============================================================================
# The deterministic clock control
# =============================================================================
#
# The control resolves the real date before the control directory enters PATH.
# The control intercepts only the exact one-argument call `date +%s` and
# delegates every other argument vector to the real date with the exact status.
# Each intercepted call claims one sequence index with an atomic noclobber
# creation, so the sequence update is finite and concurrency-safe. The control
# repeats the final sequence value after the sequence is exhausted, and records
# every returned integer outside every Batch Workspace.

CLOCK_DIR="${CONTROL_ROOT}/clock"
mkdir -p "${CLOCK_DIR}/bin"
DATE_REAL="$(command -v date)"
assert_ne "${CLOCK_DIR}/bin/date" "$DATE_REAL" \
    "the clock control resolves the real date first"

{
    printf '#!/usr/bin/env bash\n'
    printf 'real_date=%q\n' "$DATE_REAL"
    cat <<'CONTROL'
if [[ $# -ne 1 || "$1" != "+%s" || -z "${Z_CLOCK_DIR:-}" ]]; then
    "$real_date" "$@"
    exit $?
fi

claim_index=0
while (( claim_index < 10000 )); do
    if ( set -o noclobber; : > "${Z_CLOCK_DIR}/claim.${claim_index}" ) 2>/dev/null
    then
        break
    fi
    claim_index=$(( claim_index + 1 ))
done

claim_value="$(awk -v want="$(( claim_index + 1 ))" '
    NR == want { print; found = 1; exit }
    { last = $0 }
    END { if (!found) print last }' "${Z_CLOCK_DIR}/sequence")"

printf '%s\n' "$claim_value" >> "${Z_CLOCK_DIR}/record"
printf '%s\n' "$claim_value"
exit 0
CONTROL
} > "${CLOCK_DIR}/bin/date"
chmod +x "${CLOCK_DIR}/bin/date"

# new_clock <name> <second> [<second> ...] - one clock control for one run.
new_clock() {
    local name="$1"
    shift
    Z_CLOCK_DIR="${CLOCK_DIR}/${name}"
    rm -rf -- "$Z_CLOCK_DIR"
    mkdir -p "$Z_CLOCK_DIR"
    : > "${Z_CLOCK_DIR}/record"
    printf '%s\n' "$@" > "${Z_CLOCK_DIR}/sequence"
    CLOCK_RECORD="${Z_CLOCK_DIR}/record"
}

# add_ramp <first> <step> <count> - append an increasing tail to the sequence.
# Every tail value is due under the current arithmetic, so a forced call and a
# timing-reset call keep the same due result as the plain interval rule.
add_ramp() {
    local first="$1" step="$2" count="$3" index
    for (( index = 0; index < count; index++ )); do
        printf '%s\n' "$(( first + index * step ))" >> "${Z_CLOCK_DIR}/sequence"
    done
}

# clock_calls - the number of recorded `date +%s` calls.
clock_calls() {
    grep -c . "$CLOCK_RECORD" || true
}

# clock_due_count <interval> - replay the recorded seconds through the exact
# current arithmetic and print the number of due decisions. The oracle reads
# the real record, so an extra callback iteration cannot change the result.
clock_due_count() {
    awk -v interval="$1" '
        BEGIN { last = 0; due = 0 }
        { if ($1 - last >= interval) { due++; last = $1 } }
        END { print due }' "$CLOCK_RECORD"
}

# clock_suppressed_count <interval> - the number of not-due decisions.
clock_suppressed_count() {
    awk -v interval="$1" '
        BEGIN { last = 0; suppressed = 0 }
        { if ($1 - last >= interval) { last = $1 } else { suppressed++ } }
        END { print suppressed }' "$CLOCK_RECORD"
}

# clock_exact_gap_count <interval> - due decisions whose elapsed gap equals the
# exact interval. The first call has no earlier due second, so it never counts.
clock_exact_gap_count() {
    awk -v interval="$1" '
        BEGIN { last = 0; exact = 0 }
        {
            if ($1 - last >= interval) {
                if (last > 0 && $1 - last == interval) exact++
                last = $1
            }
        }
        END { print exact }' "$CLOCK_RECORD"
}

# =============================================================================
# The deterministic Case controls
# =============================================================================

# new_hold <name> - one Case-hold control directory outside every Batch
# Workspace.
new_hold() {
    hold_dir="${CONTROL_ROOT}/hold.${1}"
    rm -rf -- "$hold_dir"
    mkdir -p "${hold_dir}/active" "${hold_dir}/seen"
    : > "${hold_dir}/events"
}

# write_clock_hold_control <bin_dir> <command> <real_command> [<extra_body>]
# The control holds one Case process until the parent Stage Runner records one
# more clock call. An emitted progress line therefore observes the active Case,
# and the free-slot and final-drain callbacks run while a Case is active. The
# hold has a finite deadline, preserves the exact argument vector, and returns
# the exact delegated status.
write_clock_hold_control() {
    local bin_dir="$1" command_name="$2" real_command="$3" extra="${4:-}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'real_command=%q\n' "$real_command"
        printf 'hold_dir=%q\n' "$hold_dir"
        cat <<'CONTROL'
printf 'enter\n' >> "${hold_dir}/events"

if [[ -n "${Z_CLOCK_RECORD:-}" && -f "$Z_CLOCK_RECORD" ]]; then
    hold_before="$(grep -c . "$Z_CLOCK_RECORD" || true)"
    hold_waited=0
    while (( hold_waited < 40 )); do
        if (( "$(grep -c . "$Z_CLOCK_RECORD" || true)" > hold_before )); then
            break
        fi
        sleep 0.05
        hold_waited=$(( hold_waited + 1 ))
    done
fi
CONTROL
        printf '%s' "$extra"
        cat <<'CONTROL'

"$real_command" "$@"
hold_status=$?
printf 'exit %s\n' "$hold_status" >> "${hold_dir}/events"
exit "$hold_status"
CONTROL
    } > "${bin_dir}/${command_name}"
    chmod +x "${bin_dir}/${command_name}"
}

# write_overlap_hold_control <bin_dir> <command> <real_command> <target>
# The control holds each Case process until <target> Case processes overlap or
# a finite deadline passes. Mesh and transport running-Case detail needs more
# than one active Case.
write_overlap_hold_control() {
    local bin_dir="$1" command_name="$2" real_command="$3" target="$4"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'real_command=%q\n' "$real_command"
        printf 'hold_dir=%q\n' "$hold_dir"
        printf 'overlap_target=%q\n' "$target"
        cat <<'CONTROL'
hold_token="$(printf '%s' "$PWD" | tr '/' '_')"
hold_owner=0
active_count() { find "${hold_dir}/active" -type f 2>/dev/null | wc -l; }

if ( set -o noclobber; : > "${hold_dir}/seen/${hold_token}" ) 2>/dev/null; then
    hold_owner=1
    printf 'enter\n' >> "${hold_dir}/events"
    : > "${hold_dir}/active/${hold_token}"

    hold_waited=0
    while (( "$(active_count)" < overlap_target )); do
        sleep 0.05
        hold_waited=$(( hold_waited + 1 ))
        if (( hold_waited > 80 )); then
            break
        fi
    done

    # The Case stays active long enough for one parent progress update to read
    # the running-Case state files.
    sleep 0.4
fi

"$real_command" "$@"
hold_status=$?

if (( hold_owner == 1 )); then
    rm -f -- "${hold_dir}/active/${hold_token}"
    printf 'exit %s\n' "$hold_status" >> "${hold_dir}/events"
fi
exit "$hold_status"
CONTROL
    } > "${bin_dir}/${command_name}"
    chmod +x "${bin_dir}/${command_name}"
}

# write_failing_control <bin_dir> <command> <real_command> <token>
# The control fails only inside the named Case directory and delegates every
# other Case to the real command.
write_failing_control() {
    local bin_dir="$1" command_name="$2" real_command="$3" token="$4"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'real_command=%q\n' "$real_command"
        printf 'fail_token=%q\n' "$token"
        cat <<'CONTROL'
case "$PWD" in
    *"/${fail_token}/"*|*"/${fail_token}") exit 1 ;;
esac
"$real_command" "$@"
exit $?
CONTROL
    } > "${bin_dir}/${command_name}"
    chmod +x "${bin_dir}/${command_name}"
}

# =============================================================================
# Fixtures
# =============================================================================

# make_setup_bases <root> - flow and transport base folders for a real setup run.
make_setup_bases() {
    local flow="${1}/simpleFoam_files" transport="${1}/scalarTransportDeffFoam_files"
    local field

    mkdir -p "${flow}/0" "${flow}/system" "${flow}/constant/triSurface"
    for field in U p k nut epsilon; do
        printf 'FoamFile { object %s; }\n' "$field" > "${flow}/0/${field}"
    done
    printf 'FoamFile { object controlDict; }\napplication simpleFoam;\nendTime 3000;\n' \
        > "${flow}/system/controlDict"
    printf 'FoamFile { object turbulenceProperties; }\nsimulationType RAS;\n' \
        > "${flow}/constant/turbulenceProperties"
    printf 'FoamFile { object blockMeshDict; }\nvertices ( <xMin> <yMin> <zMin> <xMax> <yMax> <zMax> );\nblocks ( hex ( <nx> <ny> <nz> ) );\n' \
        > "${flow}/system/blockMeshDict"
    printf 'FoamFile { object snappyHexMeshDict; }\nsnap <snap_ctrl>;\n' \
        > "${flow}/system/snappyHexMeshDict"
    printf 'solid f18p2\nendsolid f18p2\n' > "${flow}/constant/triSurface/f18p2_all.stl"

    mkdir -p "${transport}/0" "${transport}/system"
    printf 'FoamFile { object T; }\n' > "${transport}/0/T"
    printf 'FoamFile { object controlDict; }\napplication scalarTransportDeffFoam;\n' \
        > "${transport}/system/controlDict"
}

# make_setup_side_commands <bin_dir> - the setup commands that are not controls.
make_setup_side_commands() {
    cat > "${1}/surfaceCheck" <<'STUB'
#!/usr/bin/env bash
echo "Overall bounds (0 0 0) (10 10 10)"
exit 0
STUB

    cat > "${1}/foamDictionary" <<'STUB'
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

    chmod +x "${1}/surfaceCheck" "${1}/foamDictionary"
}

# new_progress_workspace <name> <case_id> [<case_id> ...]
new_progress_workspace() {
    local name="$1"
    shift
    workspace="$(new_workspace "$name")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" "$@"
    control_bin="${workspace}/_control_bin"
    mkdir -p "$control_bin"
}

# make_mesh_cases <case_id> [<case_id> ...] - meshable flow Case directories.
make_mesh_cases() {
    local case_id
    for case_id in "$@"; do
        make_flow_case "${workspace}/case_${case_id}/flow" 2
    done
}

# make_flow_cases <case_id> [<case_id> ...] - solvable flow Case directories.
make_flow_cases() {
    local case_id
    for case_id in "$@"; do
        make_flow_case "${workspace}/case_${case_id}/flow" 2
        make_flow_mesh "${workspace}/case_${case_id}/flow"
        printf 'FoamFile { object wallDistance; }\n' \
            > "${workspace}/case_${case_id}/flow/0/wallDistance"
    done
}

# make_transport_cases <case_id> [<case_id> ...] - solvable transport Cases.
make_transport_cases() {
    local case_id
    for case_id in "$@"; do
        make_flow_case "${workspace}/case_${case_id}/flow" 2
        make_flow_mesh "${workspace}/case_${case_id}/flow"
        make_flow_result "${workspace}/case_${case_id}/flow" 3000
        make_transport_case "${workspace}/case_${case_id}/trd" 2 T 300
    done
}

# run_stage <script> <args...> - one Stage Runner run with a finite timeout.
# The function sets out and status.
run_stage() {
    local script="$1"
    shift
    out="$(cd "$workspace" && LC_ALL=C \
        Z_CLOCK_DIR="$Z_CLOCK_DIR" Z_CLOCK_RECORD="$CLOCK_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$script" "$@" 2>&1)" && status=0 || status=$?
    assert_ne 124 "$status" \
        "the ${script##*/} run completes without an external kill"
}

# progress_count <prefix> - emitted aggregate-progress lines with that prefix.
progress_count() {
    grep -c -- "$1" <<< "$out" || true
}

# last_progress_line <prefix> - the final emitted aggregate-progress line.
last_progress_line() {
    grep -- "$1" <<< "$out" | tail -n 1
}

# assert_timing_gate <label> <prefix> <interval>
# The emitted line count must equal the due count of the recorded seconds. The
# assertion needs no fixed number of callback invocations.
assert_timing_gate() {
    local label="$1" prefix="$2" interval="$3"
    assert_eq "$(clock_due_count "$interval")" "$(progress_count "$prefix")" \
        "${label}: the emitted progress lines match the due seconds"
}

# =============================================================================
# GROUP 1 - the clock-controlled timing group
# =============================================================================
#
# Every observation uses a concurrency limit of 1.

if (( TIMING_GROUP == 1 )); then

# ---- setup: a second call in the same second is suppressed ------------------
#
# The sequence gives one repeated second and then one elapsed second. Every
# later value is due, so the unforced final call is due and reports no running
# Case.

new_progress_workspace setup_timing 0 1 2
make_setup_bases "$workspace"
make_setup_side_commands "$control_bin"
new_hold setup_timing
new_clock setup_timing 1000 1000
add_ramp 1001 10 400
write_clock_hold_control "$control_bin" surfaceTransformPoints "$(command -v true)" \
    'echo "Set centre of rotation to (100 200 0)"
'

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
assert_eq "${CLOCK_DIR}/bin/date" "$(command -v date)" \
    "the setup timing run resolves the clock control first"
run_stage "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the setup timing run keeps exit status 0"
assert_eq 1 "$(( $(clock_calls) >= 3 ? 1 : 0 ))" \
    "the setup timing run records at least three clock calls"
assert_eq 1 "$(( $(clock_suppressed_count 1) >= 1 ? 1 : 0 ))" \
    "setup suppresses a second call in the same second"
assert_eq 1 "$(( $(clock_exact_gap_count 1) >= 1 ? 1 : 0 ))" \
    "setup emits again after one elapsed second"
assert_timing_gate "setup" '>>> Progress: launched=' 1
assert_contains "$out" "running=1/1" \
    "an emitted setup progress line reports one active Case"
assert_contains "$(last_progress_line '>>> Progress: launched=')" "running=0/1" \
    "the final emitted setup progress line reports no active Case"

# ---- setup: the final unforced call inside the same second is suppressed ----
#
# The single-value sequence keeps every call inside one second. Setup neither
# forces nor resets its final call, so the final call emits nothing.

new_progress_workspace setup_final 0 1
make_setup_bases "$workspace"
make_setup_side_commands "$control_bin"
new_hold setup_final
new_clock setup_final 1000
write_clock_hold_control "$control_bin" surfaceTransformPoints "$(command -v true)" \
    'echo "Set centre of rotation to (100 200 0)"
'

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the setup final-call run keeps exit status 0"
assert_eq 1 "$(( $(clock_calls) >= 3 ? 1 : 0 ))" \
    "the setup final-call run records at least three clock calls"
assert_eq 1 "$(progress_count '>>> Progress: launched=')" \
    "setup emits exactly one progress line inside one second"
assert_timing_gate "setup final call" '>>> Progress: launched=' 1
assert_not_contains "$out" "running=0/1" \
    "setup does not force or reset its final progress call"

# ---- mesh: the interval gate ------------------------------------------------
#
# PROGRESS_INTERVAL is 5. The sequence gives one gap below the interval and one
# gap at the exact interval.

new_progress_workspace mesh_timing 0 1 2
make_mesh_cases 0 1 2
new_hold mesh_timing
new_clock mesh_timing 1000 1002 1005
add_ramp 1015 10 400
write_clock_hold_control "$control_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the mesh timing run keeps exit status 0"
assert_eq 1 "$(( $(clock_calls) >= 3 ? 1 : 0 ))" \
    "the mesh timing run records at least three clock calls"
assert_eq 1 "$(( $(clock_suppressed_count 5) >= 1 ? 1 : 0 ))" \
    "mesh suppresses a call before PROGRESS_INTERVAL"
assert_eq 1 "$(( $(clock_exact_gap_count 5) >= 1 ? 1 : 0 ))" \
    "mesh emits at the exact PROGRESS_INTERVAL"
assert_timing_gate "mesh" '>>> Mesh progress:' 5

# ---- mesh: the forced final-drain calls bypass the interval ------------------
#
# The single-value sequence keeps every call inside one interval. Only a forced
# call can emit after the first line.

new_progress_workspace mesh_forced 0 1
make_mesh_cases 0 1
new_hold mesh_forced
new_clock mesh_forced 1000
write_clock_hold_control "$control_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the mesh forced-drain run keeps exit status 0"
assert_eq 1 "$(clock_due_count 5)" \
    "the mesh forced-drain sequence keeps exactly one unforced due second"
assert_eq 1 "$(( $(progress_count '>>> Mesh progress:') >= 3 ? 1 : 0 ))" \
    "mesh forced drain calls emit inside the interval"

# ---- flow: the one-second gate ----------------------------------------------

new_progress_workspace flow_timing 0 1 2
make_flow_cases 0 1 2
new_hold flow_timing
new_clock flow_timing 1000 1000 1001
add_ramp 1011 10 400
write_clock_hold_control "$control_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the flow timing run keeps exit status 0"
assert_eq 1 "$(( $(clock_calls) >= 3 ? 1 : 0 ))" \
    "the flow timing run records at least three clock calls"
assert_eq 1 "$(( $(clock_suppressed_count 1) >= 1 ? 1 : 0 ))" \
    "flow suppresses a second call in the same second"
assert_eq 1 "$(( $(clock_exact_gap_count 1) >= 1 ? 1 : 0 ))" \
    "flow emits again after one elapsed second"
assert_timing_gate "flow" '>>> Progress: launched=' 1

# ---- flow: both final timing resets make a call due -------------------------

new_progress_workspace flow_reset 0 1
make_flow_cases 0 1
new_hold flow_reset
new_clock flow_reset 1000
write_clock_hold_control "$control_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the flow reset run keeps exit status 0"
assert_eq 1 "$(clock_due_count 1)" \
    "the flow reset sequence keeps exactly one unreset due second"
assert_eq 1 "$(( $(progress_count '>>> Progress: launched=') >= 3 ? 1 : 0 ))" \
    "both flow final timing resets make a progress call due"

# ---- transport: the interval gate -------------------------------------------

new_progress_workspace transport_timing 0 1 2
make_transport_cases 0 1 2
new_hold transport_timing
new_clock transport_timing 1000 1002 1005
add_ramp 1015 10 400
write_clock_hold_control "$control_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300
PATH="$saved_path"

assert_status 0 "$status" "the transport timing run keeps exit status 0"
assert_eq 1 "$(( $(clock_calls) >= 3 ? 1 : 0 ))" \
    "the transport timing run records at least three clock calls"
assert_eq 1 "$(( $(clock_suppressed_count 5) >= 1 ? 1 : 0 ))" \
    "transport suppresses a call before PROGRESS_INTERVAL"
assert_eq 1 "$(( $(clock_exact_gap_count 5) >= 1 ? 1 : 0 ))" \
    "transport emits at the exact PROGRESS_INTERVAL"
assert_timing_gate "transport" '>>> Transport progress:' 5

# ---- transport: both final timing resets make a call due --------------------

new_progress_workspace transport_reset 0 1
make_transport_cases 0 1
new_hold transport_reset
new_clock transport_reset 1000
write_clock_hold_control "$control_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300
PATH="$saved_path"

assert_status 0 "$status" "the transport reset run keeps exit status 0"
assert_eq 1 "$(clock_due_count 5)" \
    "the transport reset sequence keeps exactly one unreset due second"
assert_eq 1 "$(( $(progress_count '>>> Transport progress:') >= 3 ? 1 : 0 ))" \
    "both transport final timing resets make a progress call due"

fi

# =============================================================================
# GROUP 2 - the uninstrumented format, counter, detail, scheduling, artifact,
#           and status group
# =============================================================================
#
# Every observation runs the unmodified production deployment unit. The clock
# sequence makes every call due, so each emitted line reports the exact current
# text and the exact current counter values.

# ---- setup: the exact progress format and counters --------------------------

new_progress_workspace setup_format 0 1
make_setup_bases "$workspace"
make_setup_side_commands "$control_bin"
new_hold setup_format
new_clock setup_format 1000
add_ramp 1010 10 400
write_clock_hold_control "$control_bin" surfaceTransformPoints "$(command -v true)" \
    'echo "Set centre of rotation to (100 200 0)"
'

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the setup format run keeps exit status 0"
assert_eq '>>> Progress: launched=2/2, processed=4/2, running=0/1, created=4, skipped=0, failed=0, dry_run=0' \
    "$(last_progress_line '>>> Progress: launched=')" \
    "the final setup progress line keeps its exact prefix, fields, order, and values"
assert_contains "$out" "running=1/1" \
    "an emitted setup progress line reports one active Case"
assert_file_exists "${workspace}/setup_cases_summary.csv" \
    "the setup format run keeps its summary"
assert_contains "$out" "Done." "the setup format run keeps its success message"

# ---- setup: the dry-run counter ---------------------------------------------

new_progress_workspace setup_dry 0 1
make_setup_bases "$workspace"
make_setup_side_commands "$control_bin"
new_hold setup_dry
new_clock setup_dry 1000
add_ramp 1010 10 400

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run
PATH="$saved_path"

assert_status 0 "$status" "the setup dry-run keeps exit status 0"
assert_eq '>>> Progress: launched=2/2, processed=4/2, running=0/1, created=0, skipped=0, failed=0, dry_run=4' \
    "$(last_progress_line '>>> Progress: launched=')" \
    "the setup dry_run counter keeps its current meaning"

# ---- setup: the processed, created, skipped, and failed counters -------------
#
# The first row keeps an existing flow Case, so setup skips that flow Case. The
# second row carries an invalid wind speed, so setup records a failed Case. The
# third row creates both Cases.

new_progress_workspace setup_mixed 0
make_setup_bases "$workspace"
make_setup_side_commands "$control_bin"
mkdir -p "${workspace}/case_0/flow"
{
    printf 'Case,met__WS_mps,met__WD_deg\n'
    printf '0,3.5,270.0\n'
    printf '1,not_a_speed,270.0\n'
    printf '2,3.5,270.0\n'
} > "${workspace}/output_batch_1.csv"
new_hold setup_mixed
new_clock setup_mixed 1000
add_ramp 1010 10 400
write_clock_hold_control "$control_bin" surfaceTransformPoints "$(command -v true)" \
    'echo "Set centre of rotation to (100 200 0)"
'

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_eq '>>> Progress: launched=3/3, processed=5/3, running=0/1, created=3, skipped=1, failed=1, dry_run=0' \
    "$(last_progress_line '>>> Progress: launched=')" \
    "the setup processed, created, skipped, and failed values keep their current meaning"

# ---- mesh: the exact progress format, counters, and running-Case detail -----
#
# PROGRESS_MAX_ACTIVE is 1 and two Cases overlap, so the detail limit and the
# omitted-detail message both appear.

new_progress_workspace mesh_format 0 1
make_mesh_cases 0 1
new_hold mesh_format
new_clock mesh_format 1000
add_ramp 1010 10 400
write_overlap_hold_control "$control_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh" 2

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C \
    Z_CLOCK_DIR="$Z_CLOCK_DIR" Z_CLOCK_RECORD="$CLOCK_RECORD" \
    PROGRESS_MAX_ACTIVE=1 \
    timeout "$STAGE_TIMEOUT" bash "$MESH_SCRIPT" \
    -i output_batch_1.csv -O . -j 2 2>&1)" && status=0 || status=$?
PATH="$saved_path"

assert_ne 124 "$status" "the mesh format run completes without an external kill"
assert_status 0 "$status" "the mesh format run keeps exit status 0"
assert_eq '>>> Mesh progress: total=2, launched=2, running=0/2, pending=0, meshed=2, continued=0, skipped=0, failed=0' \
    "$(last_progress_line '>>> Mesh progress:')" \
    "the final mesh progress line keeps its exact prefix, fields, order, and values"
assert_contains "$out" "running=2/2" \
    "an emitted mesh progress line reports the active Cases"
assert_contains "$out" ">>> Mesh cases currently running:" \
    "mesh keeps its exact running-Case heading"
assert_eq 1 "$(( $(grep -c '^>>>   - case_[01]/flow | stage=[^|]* | [^|]* | updated=[^|]* | log=' <<< "$out") >= 1 ? 1 : 0 ))" \
    "mesh keeps its exact running-Case detail format"
assert_eq 1 "$(awk '
        /^>>> Mesh cases currently running:$/ { shown = 0; next }
        /^>>>   - / { shown++; if (shown > most) most = shown; next }
        { shown = 0 }
        END { print most + 0 }' <<< "$out")" \
    "PROGRESS_MAX_ACTIVE still limits the printed mesh details"
assert_contains "$out" ">>>   ... 1 more running mesh case(s) not shown." \
    "mesh keeps its exact omitted-detail message"
assert_contains "$out" "All mesh jobs finished." \
    "the mesh format run keeps its success message"

# ---- mesh: the continued, skipped, and failed counters ----------------------

new_progress_workspace mesh_mixed 0 1 2 3
make_mesh_cases 0 1 3
# case_1 keeps a complete mesh and a restart marker, so mesh continues it.
make_flow_mesh "${workspace}/case_1/flow"
: > "${workspace}/case_1/flow/restart.marker"
new_hold mesh_mixed
new_clock mesh_mixed 1000
add_ramp 1010 10 400
write_failing_control "$control_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh" case_3

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_failure "$status" "the mesh mixed run keeps a non-zero status"
assert_eq '>>> Mesh progress: total=4, launched=3, running=0/1, pending=0, meshed=1, continued=1, skipped=1, failed=1' \
    "$(last_progress_line '>>> Mesh progress:')" \
    "the mesh pending, meshed, continued, skipped, and failed values keep their current meaning"

# ---- flow: the exact progress format and counters ---------------------------

new_progress_workspace flow_format 0 1
make_flow_cases 0 1
new_hold flow_format
new_clock flow_format 1000
add_ramp 1010 10 400
write_clock_hold_control "$control_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the flow format run keeps exit status 0"
assert_eq '>>> Progress: launched=2/2, completed=2, running=0/1, skipped=0, failed=0' \
    "$(last_progress_line '>>> Progress: launched=')" \
    "the final flow progress line keeps its exact prefix, fields, order, and values"
assert_contains "$out" "running=1/1" \
    "an emitted flow progress line reports one active Case"
assert_contains "$out" "All flow jobs finished." \
    "the flow format run keeps its success message"

# ---- flow: the skipped and failed counters ----------------------------------

new_progress_workspace flow_mixed 0 1 2
make_flow_cases 0 2
new_hold flow_mixed
new_clock flow_mixed 1000
add_ramp 1010 10 400
write_failing_control "$control_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam" case_2

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_failure "$status" "the flow mixed run keeps a non-zero status"
assert_eq '>>> Progress: launched=2/3, completed=2, running=0/1, skipped=1, failed=1' \
    "$(last_progress_line '>>> Progress: launched=')" \
    "the flow completed, skipped, and failed values keep their current meaning"

# ---- transport: the exact progress format, counters, and running detail -----

new_progress_workspace transport_format 0 1
make_transport_cases 0 1
new_hold transport_format
new_clock transport_format 1000
add_ramp 1010 10 400
write_overlap_hold_control "$control_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam" 2

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 2 --save-times 300
PATH="$saved_path"

assert_status 0 "$status" "the transport format run keeps exit status 0"
assert_eq '>>> Transport progress: total=2, launched=2, running=0/2, pending=0, solved=2, continued=0, skipped=0, failed=0' \
    "$(last_progress_line '>>> Transport progress:')" \
    "the final transport progress line keeps its exact prefix, fields, order, and values"
assert_contains "$out" "running=2/2" \
    "an emitted transport progress line reports the active Cases"
assert_eq 1 "$(( $(grep -c '^>>>   RUNNING: case_[01]/trd | stage=[^|]* | [^|]* | updated=[^|]* | log=' <<< "$out") >= 1 ? 1 : 0 ))" \
    "transport keeps its exact running-Case detail format"
assert_contains "$out" "All transport jobs finished." \
    "the transport format run keeps its success message"

# ---- transport: the skipped and failed counters -----------------------------

new_progress_workspace transport_mixed 0 2
make_transport_cases 0 2
# The middle row names no Case, so transport skips it before a launch.
{
    printf 'Case,met__WS_mps,met__WD_deg\n'
    printf '0,3.5,270.0\n'
    printf ',3.5,270.0\n'
    printf '2,3.5,270.0\n'
} > "${workspace}/output_batch_1.csv"
new_hold transport_mixed
new_clock transport_mixed 1000
add_ramp 1010 10 400
write_failing_control "$control_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam" case_2

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300
PATH="$saved_path"

assert_failure "$status" "the transport mixed run keeps a non-zero status"
assert_contains "$(last_progress_line '>>> Transport progress:')" \
    ", solved=1, continued=0, skipped=1, failed=1" \
    "the transport solved, continued, skipped, and failed values keep their current meaning"

# ---- post-processing: no aggregate progress output --------------------------

new_progress_workspace post_format 0 1
make_transport_cases 0 1
new_hold post_format
new_clock post_format 1000
add_ramp 1010 10 400

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"
run_stage "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1
PATH="$saved_path"

assert_status 0 "$status" "the post-processing run keeps exit status 0"
for post_index in 0 1; do
    assert_contains "$out" "Launching [$(( post_index + 1 ))]: case_${post_index}" \
        "post-processing keeps its per-Case launch message for case_${post_index}"
done
assert_contains "$out" "All post-processing jobs completed." \
    "post-processing keeps its success message"
assert_not_contains "$out" "Progress: launched=" \
    "post-processing gives no setup or flow aggregate-progress prefix"
assert_not_contains "$out" "Mesh progress:" \
    "post-processing gives no mesh aggregate-progress prefix"
assert_not_contains "$out" "Transport progress:" \
    "post-processing gives no transport aggregate-progress prefix"
assert_eq 0 "$(clock_calls)" \
    "post-processing makes no aggregate-progress clock call"
assert_file_exists "${workspace}/run_post_processing_cases_summary.csv" \
    "the post-processing run keeps its summary"

# =============================================================================
# GROUP 3 - shared-helper delegation through a copied deployment unit
# =============================================================================
#
# The copied library keeps its production content and then receives compatible
# instrumented implementations of the shared timing helper and the shared
# active-count helper. Each instrumented helper keeps the production behavior
# and records one call outside every Batch Workspace. A Stage Runner that keeps
# local timing code and a local active-count pipeline produces no aggregate
# progress record, so this group fails before the extraction.
#
# The test never sources the library and never calls a helper.

HELPER_RECORD_DIR="${CONTROL_ROOT}/helpers"
mkdir -p "$HELPER_RECORD_DIR"

# make_instrumented_unit <master_dir>
make_instrumented_unit() {
    local master="$1" name
    mkdir -p "$master"
    for name in lib_batch_stage.sh setup_cases.sh run_mesh_cases.sh \
            run_flow_cases.sh run_transport_cases.sh run_post_processing_cases.sh; do
        cp -f -- "${MASTER_SRC_DIR}/${name}" "${master}/${name}"
    done

    cat >> "${master}/lib_batch_stage.sh" <<'INSTRUMENT'

# Test instrumentation. Each definition keeps the approved production behavior,
# the exact output, the exact status, the exact caller assignments, and the
# exact process count, and records one call outside every Batch Workspace.
# FUNCNAME records only which caller invoked the helper.
__z_record() { printf '%s\n' "$1" >> "${Z_HELPER_RECORD:-/dev/null}"; }

batch_stage_job_pool_running_count() {
    __z_record "count|${FUNCNAME[1]:-none}"
    jobs -rp | wc -l | tr -d ' '
}

batch_stage_progress_tick() {
    local __batch_stage_progress_tick_due_name="$1"
    local __batch_stage_progress_tick_last_name="$2"
    local __batch_stage_progress_tick_interval="$3"
    local __batch_stage_progress_tick_force="$4"
    local __batch_stage_progress_tick_now
    local __batch_stage_progress_tick_status=0

    __z_record "tick|${FUNCNAME[1]:-none}|$1|$2|$3|$4"

    __batch_stage_progress_tick_now="$(date +%s)" ||
        __batch_stage_progress_tick_status=$?

    if (( __batch_stage_progress_tick_status != 0 )); then
        return "$__batch_stage_progress_tick_status"
    fi

    if (( __batch_stage_progress_tick_force == 1 ||
          __batch_stage_progress_tick_now -
          ${!__batch_stage_progress_tick_last_name} >=
          __batch_stage_progress_tick_interval )); then
        printf -v "$__batch_stage_progress_tick_due_name" '%s' 1
        printf -v "$__batch_stage_progress_tick_last_name" '%s' \
            "$__batch_stage_progress_tick_now"
        __z_record "due|1|${__batch_stage_progress_tick_now}"
        return 0
    fi

    printf -v "$__batch_stage_progress_tick_due_name" '%s' 0
    __z_record "due|0|${__batch_stage_progress_tick_now}"
    return 0
}
INSTRUMENT
}

# run_copied_stage <record-name> <script> <args...>
# The copied run discards the console output, because the delegation records
# carry the evidence. The run keeps the exact process status. Status 124 is
# never an accepted Stage result, and each of these five copied observations
# uses a success path, so the status must be 0.
run_copied_stage() {
    local record_name="$1"
    shift
    local copied_status=0
    HELPER_RECORD="${HELPER_RECORD_DIR}/${record_name}.log"
    : > "$HELPER_RECORD"
    ( cd "$workspace" && Z_HELPER_RECORD="$HELPER_RECORD" \
        Z_CLOCK_DIR="$Z_CLOCK_DIR" Z_CLOCK_RECORD="$CLOCK_RECORD" \
        LC_ALL=C timeout "$STAGE_TIMEOUT" bash "$@" ) >/dev/null 2>&1 ||
        copied_status=$?
    assert_ne 124 "$copied_status" \
        "the copied ${record_name} Stage Runner completes without an external kill"
    assert_status 0 "$copied_status" \
        "the copied ${record_name} Stage Runner keeps exit status 0"
}

# tick_records - the recorded aggregate-progress timing-helper calls.
tick_records() {
    grep '^tick|show_progress|' "$HELPER_RECORD" || true
}

# assert_progress_delegation <stage> <interval> <force>
# The named failure before the extraction is the missing shared progress-helper
# delegation.
assert_progress_delegation() {
    local stage="$1" interval="$2" force="$3" ticks

    assert_file_exists "$HELPER_RECORD" \
        "the copied ${stage} deployment unit records shared-helper delegation"
    ticks="$(tick_records)"
    assert_ne "" "$ticks" \
        "the copied ${stage} Stage Runner uses the shared progress-timing helper"
    assert_eq "" \
        "$(grep -v "^tick|show_progress|progress_due|_LAST_PROGRESS_TIME|${interval}|${force}\$" <<< "$ticks" || true)" \
        "the copied ${stage} Stage Runner passes its due-output variable, _LAST_PROGRESS_TIME, interval ${interval}, and force ${force}"
    assert_ne 0 "$(grep -c '^count|show_progress$' "$HELPER_RECORD" || true)" \
        "the copied ${stage} show_progress uses the shared active-count helper"
    assert_ne 0 "$(grep -c '^count|batch_stage_job_pool_wait_for_' "$HELPER_RECORD" || true)" \
        "the copied ${stage} job-pool waits keep their own shared active-count calls"
    assert_eq "$(grep -c '^tick|' "$HELPER_RECORD" || true)" "$(clock_calls)" \
        "the copied ${stage} Stage Runner makes one clock call for each timing-helper call"
}

new_progress_workspace delegation 0 1
make_setup_bases "$workspace"
make_transport_cases 0 1
printf 'FoamFile { object wallDistance; }\n' \
    > "${workspace}/case_0/flow/0/wallDistance"
printf 'FoamFile { object wallDistance; }\n' \
    > "${workspace}/case_1/flow/0/wallDistance"
make_setup_side_commands "$control_bin"
printf '#!/usr/bin/env bash\necho "Set centre of rotation to (100 200 0)"\nexit 0\n' \
    > "${control_bin}/surfaceTransformPoints"
chmod +x "${control_bin}/surfaceTransformPoints"
delegation_master="${workspace}/master_batch"
make_instrumented_unit "$delegation_master"

saved_path="$PATH"
PATH="${control_bin}:${CLOCK_DIR}/bin:${PATH}"

new_clock delegation_setup 1000
add_ramp 1010 10 400
run_copied_stage setup "${delegation_master}/setup_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_progress_delegation setup 1 0

new_clock delegation_mesh 1000
add_ramp 1010 10 400
run_copied_stage mesh "${delegation_master}/run_mesh_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_file_exists "$HELPER_RECORD" \
    "the copied mesh deployment unit records shared-helper delegation"
assert_ne "" "$(tick_records)" \
    "the copied mesh Stage Runner uses the shared progress-timing helper"
assert_eq "" \
    "$(grep -v '^tick|show_progress|progress_due|_LAST_PROGRESS_TIME|5|[01]$' \
        <<< "$(tick_records)" || true)" \
    "the copied mesh Stage Runner passes its due-output variable, _LAST_PROGRESS_TIME, PROGRESS_INTERVAL, and its own force value"
assert_ne 0 "$(grep -c '^tick|show_progress|progress_due|_LAST_PROGRESS_TIME|5|1$' "$HELPER_RECORD" || true)" \
    "the copied mesh Stage Runner keeps its forced final-drain calls"
assert_ne 0 "$(grep -c '^tick|show_progress|progress_due|_LAST_PROGRESS_TIME|5|0$' "$HELPER_RECORD" || true)" \
    "the copied mesh Stage Runner keeps its unforced calls"
assert_ne 0 "$(grep -c '^count|show_progress$' "$HELPER_RECORD" || true)" \
    "the copied mesh show_progress uses the shared active-count helper"
assert_ne 0 "$(grep -c '^count|batch_stage_job_pool_wait_for_' "$HELPER_RECORD" || true)" \
    "the copied mesh job-pool waits keep their own shared active-count calls"
assert_eq "$(grep -c '^tick|' "$HELPER_RECORD" || true)" "$(clock_calls)" \
    "the copied mesh Stage Runner makes one clock call for each timing-helper call"

new_clock delegation_flow 1000
add_ramp 1010 10 400
run_copied_stage flow "${delegation_master}/run_flow_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_progress_delegation flow 1 0

new_clock delegation_transport 1000
add_ramp 1010 10 400
run_copied_stage transport "${delegation_master}/run_transport_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --save-times 300
assert_progress_delegation transport 5 0

new_clock delegation_post 1000
add_ramp 1010 10 400
run_copied_stage post "${delegation_master}/run_post_processing_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_eq 0 "$(grep -c '^tick|' "$HELPER_RECORD" || true)" \
    "the copied post-processing Stage Runner calls no shared progress-timing helper"
assert_eq 0 "$(grep -c '^count|show_progress$' "$HELPER_RECORD" || true)" \
    "the copied post-processing Stage Runner has no aggregate-progress active-count call"
assert_ne 0 "$(grep -c '^count|batch_stage_job_pool_wait_for_' "$HELPER_RECORD" || true)" \
    "the copied post-processing Stage Runner keeps its job-pool active-count calls"

PATH="$saved_path"

# ---- every control record lives outside every Batch Workspace ---------------

mapfile -t z_workspaces < <(find "$CONTRACT_TEST_RUN_DIR" -maxdepth 1 -type d \
    -name "${CONTRACT_TEST_NAME:-case}.*" | sort)
assert_ne 0 "${#z_workspaces[@]}" "the scenario created its Batch Workspaces"
assert_eq "" "$(find "${z_workspaces[@]}" \
        \( -name 'record' -o -name 'sequence' -o -name 'claim.*' \
           -o -name 'events' \) -print | sort | tr '\n' ' ')" \
    "no progress control record enters a Batch Workspace"

printf 'Scenario Z passed.\n'
