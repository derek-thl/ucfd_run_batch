#!/usr/bin/env bash
# run_post_processing_cases.sh v4 - Convert flow and scalar-transport results to VTU files.
#
# Output structure:
#   case_80/
#     vtk/
#       flow_0.vtu
#       flow_latest_1000.vtu
#       trd_0.vtu
#       trd_100.vtu
#       trd_200.vtu
#       ...
#       logs/

set -euo pipefail
trap 'echo ">>> [ERROR] ${0##*/} failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_ALL=C

# =============================================================================
# SHARED STAGE LIBRARY DEPLOYMENT UNIT
# =============================================================================
# This Stage Runner and its co-located lib_batch_stage.sh are one deployment
# unit. The library comes only from the physical directory of this script
# target. The check runs before argument parsing, artifact initialization, Case
# work, and any OpenFOAM command.
unset BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION BATCH_STAGE_LIBRARY_API_VERSION
readonly BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION=1
BATCH_STAGE_LIBRARY="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib_batch_stage.sh"

batch_stage_library_reject() {
    echo "Error: Required Stage library is missing or incompatible: ${BATCH_STAGE_LIBRARY}" >&2
    exit 1
}

[[ -f "$BATCH_STAGE_LIBRARY" && -r "$BATCH_STAGE_LIBRARY" ]] || batch_stage_library_reject

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib_batch_stage.sh
source "$BATCH_STAGE_LIBRARY" 2>/dev/null || batch_stage_library_reject

[[ "${BATCH_STAGE_LIBRARY_API_VERSION:-}" == "$BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION" ]] ||
    batch_stage_library_reject

# =============================================================================
# 0. USER CONFIG
# =============================================================================
PARALLEL_JOBS="${POST_PARALLEL_JOBS:-2}"
OUT_DIR="./"
CSV_FILE=""

FLOW_ZERO_FIELDS='(U p wallDistance)'
FLOW_RESULT_FIELDS='(U p)'
SCALAR_FIELD="${SCALAR_FIELD:-T}"
TRD_FIELDS="(${SCALAR_FIELD})"
FORCE_POST="${FORCE_POST:-0}"

# =============================================================================
# 1. SMALL UTILITIES
# =============================================================================
info() {
    echo ">>> $*"
}

die() {
    echo ">>> [ERROR] $*" >&2
    exit 1
}

warn() {
    echo ">>> [warn] $*" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "'$1' not found in PATH."
}

trim() {
    local value="${1//$'\r'/}"
    value="${value#\"}"
    value="${value%\"}"

    echo "$value" |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//'
}

lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

sanitize_token() {
    local value
    value="$(trim "$1")"
    value="$(
        echo "$value" |
            sed \
                -e 's/[[:space:]]\+/_/g' \
                -e 's/[^0-9A-Za-z._-]/_/g' \
                -e 's/_\+/_/g' \
                -e 's/^_//' \
                -e 's/_$//'
    )"

    [[ -n "$value" ]] || value="NA"
    echo "$value"
}

make_case_id() {
    local value
    value="$(sanitize_token "$1")"

    if [[ "$value" == "NA" ]]; then
        echo "$value"
    elif [[ "$value" == case_* ]]; then
        echo "$value"
    else
        echo "case_${value}"
    fi
}

safe_filename() {
    local value="$1"
    value="${value//\//_}"
    sanitize_token "$value"
}

is_time_name() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ || "$1" =~ ^[.][0-9]+$ ]]
}

usage() {
    cat <<'USAGE'
Usage:
  bash run_post_processing_cases.sh [options]

Options:
  -i <csv>            Process one DOE CSV.
  -O, --output-dir    Root folder containing case_* directories.
  -j <jobs>           Number of cases processed in parallel.
  -h, --help          Show this help.

Environment:
  BATCH_CSV_PATH       CSV path exported by run_batch.sh.
  BATCH_CSV            CSV filename exported by run_batch.sh.
  POST_PARALLEL_JOBS   Number of parallel post-processing jobs.
  SCALAR_FIELD          Transport scalar field. Default: T.
  FORCE_POST=1          Rebuild VTU outputs even when source-result signature is unchanged.

Output:
  case_#/vtk/flow_0.vtu
  case_#/vtk/flow_latest_<time>.vtu
  case_#/vtk/trd_0.vtu
  case_#/vtk/trd_<time>.vtu
USAGE
}

# =============================================================================
# 2. ARGUMENTS
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            [[ $# -ge 2 ]] || die "-i requires a CSV filename."
            CSV_FILE="$2"
            shift 2
            ;;
        -O|--output-dir)
            [[ $# -ge 2 ]] || die "$1 requires a directory."
            OUT_DIR="$2"
            shift 2
            ;;
        -j)
            [[ $# -ge 2 ]] || die "-j requires a job count."
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1. Use -h for help."
            ;;
    esac
done

validate_config() {
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] &&
        ((PARALLEL_JOBS >= 1)) ||
        die "PARALLEL_JOBS must be an integer >= 1."

    [[ "$FORCE_POST" == "0" || "$FORCE_POST" == "1" ]] ||
        die "FORCE_POST must be 0 or 1."

    [[ -d "$OUT_DIR" ]] ||
        die "Output directory not found: $OUT_DIR"

    need_cmd awk
    need_cmd sed
    need_cmd find
    need_cmd sort
    need_cmd foamToVTK

    OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"
    SUMMARY_CSV="$OUT_ABS/run_post_processing_cases_summary.csv"
    FAIL_FILE="$OUT_ABS/.run_post_processing_cases_failed"

    : >"$FAIL_FILE"
    printf '%s\n' \
        'case_id,case_dir,status,message' >"$SUMMARY_CSV"
}

# =============================================================================
# 3. CSV HANDLING
# =============================================================================
declare -A COLUMN_INDEX=()

# Each shared parser helper reads this column index through the caller-supplied
# index name, so no direct read of the index stays visible in this Stage Runner.
# The side-effect-free reference below prevents ShellCheck SC2034 for an index
# that only a shared helper reads. A suppression directive is not used. The
# reference writes no output, creates no process, and changes no value.
: "${#COLUMN_INDEX[@]}"

declare -A SEEN_CASES=()
CASE_COLUMN=""

find_csv_file() {
    if [[ -n "$CSV_FILE" ]]; then
        if [[ -f "$CSV_FILE" ]]; then
            readlink -f "$CSV_FILE"
            return 0
        fi

        if [[ -n "${BATCH_DIR:-}" &&
              -f "${BATCH_DIR}/${CSV_FILE}" ]]; then
            readlink -f "${BATCH_DIR}/${CSV_FILE}"
            return 0
        fi

        die "CSV file not found: $CSV_FILE"
    fi

    if [[ -n "${BATCH_CSV_PATH:-}" &&
          -f "$BATCH_CSV_PATH" ]]; then
        readlink -f "$BATCH_CSV_PATH"
        return 0
    fi

    if [[ -n "${BATCH_CSV:-}" &&
          -f "$BATCH_CSV" ]]; then
        readlink -f "$BATCH_CSV"
        return 0
    fi

    shopt -s nullglob
    local files=(output_batch_*.csv)
    shopt -u nullglob

    ((${#files[@]} > 0)) ||
        die "No batch CSV file found."

    readlink -f "${files[0]}"
}

load_csv_header() {
    local csv_file="$1"
    local header column_lower index
    local -a columns

    header="$(head -n 1 "$csv_file")"
    header="${header//$'\r'/}"
    batch_stage_csv_tokenize columns "$header"

    COLUMN_INDEX=()

    for index in "${!columns[@]}"; do
        column_lower="$(batch_stage_csv_normalize_header trim "${columns[$index]}")"
        COLUMN_INDEX["$column_lower"]="$index"
    done

    CASE_COLUMN="$(batch_stage_csv_find_column COLUMN_INDEX Case)" ||
        die "Required CSV column not found: Case"
}

get_csv_cell() {
    local row="$1"
    local index="$2"
    batch_stage_csv_get_cell trim "$row" "$index"
}

# =============================================================================
# 4. TIME-DIRECTORY HANDLING
# =============================================================================
list_times() {
    local case_dir="$1"
    local entry

    find "$case_dir" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' |
        while IFS= read -r entry; do
            is_time_name "$entry" && echo "$entry"
        done |
        sort -g
}

list_nonzero_times() {
    local case_dir="$1"
    local time

    while IFS= read -r time; do
        [[ "$time" == "0" ]] && continue
        echo "$time"
    done < <(list_times "$case_dir")
}

latest_time() {
    local case_dir="$1"
    list_times "$case_dir" | tail -n 1
}

# =============================================================================
# 5. VTU CONVERSION
# =============================================================================
find_generated_internal_vtu() {
    local vtk_dir="$1"

    find "$vtk_dir" \
        -type f \
        -name 'internal.vtu' \
        -print |
        sort |
        tail -n 1
}

convert_time_to_vtu() {
    local domain_dir="$1"
    local time_value="$2"
    local fields="$3"
    local output_file="$4"
    local log_file="$5"

    local generated_vtu=""

    [[ -d "$domain_dir/$time_value" ]] ||
        die "Time directory not found: $domain_dir/$time_value"

    (
        cd "$domain_dir"
        rm -rf VTK

        echo ">>> [$PWD] foamToVTK -time $time_value -no-boundary -no-point-data -fields $fields"
        foamToVTK \
            -time "$time_value" \
            -no-boundary \
            -no-point-data \
            -fields "$fields"
    ) >"$log_file" 2>&1

    generated_vtu="$(find_generated_internal_vtu "$domain_dir/VTK")"

    [[ -n "$generated_vtu" &&
       -f "$generated_vtu" ]] ||
        die "foamToVTK did not produce internal.vtu for $domain_dir, time=$time_value. See $log_file"

    cp -f "$generated_vtu" "$output_file"
    rm -rf "$domain_dir/VTK"

    echo ">>> Wrote: $output_file"
}

convert_flow_case() {
    local case_id="$1"
    local flow_dir="$2"
    local vtk_dir="$3"
    local log_dir="$4"

    local final_time final_tag final_fields

    [[ -d "$flow_dir" ]] ||
        die "Flow directory not found: $flow_dir"

    [[ -d "$flow_dir/0" ]] ||
        die "Flow time 0 directory not found: $flow_dir/0"

    info "$case_id: converting flow time 0"

    convert_time_to_vtu \
        "$flow_dir" \
        "0" \
        "$FLOW_ZERO_FIELDS" \
        "$vtk_dir/flow_0.vtu" \
        "$log_dir/flow_0.log"

    final_time="$(latest_time "$flow_dir")"
    [[ -n "$final_time" ]] ||
        die "No flow time directories found: $flow_dir"

    final_tag="$(safe_filename "$final_time")"

    if [[ "$final_time" == "0" ]]; then
        final_fields="$FLOW_ZERO_FIELDS"
    else
        final_fields="$FLOW_RESULT_FIELDS"
    fi

    info "$case_id: converting flow latest time $final_time"

    convert_time_to_vtu \
        "$flow_dir" \
        "$final_time" \
        "$final_fields" \
        "$vtk_dir/flow_latest_${final_tag}.vtu" \
        "$log_dir/flow_latest_${final_tag}.log"

    printf '%s\n' "$final_time" >"$vtk_dir/flow_latest_time.txt"
}

convert_transport_case() {
    local case_id="$1"
    local transport_dir="$2"
    local vtk_dir="$3"
    local log_dir="$4"

    local time_value time_tag
    local converted_count=0

    [[ -d "$transport_dir" ]] ||
        die "Transport directory not found: $transport_dir"

    [[ -d "$transport_dir/0" ]] ||
        die "Transport time 0 directory not found: $transport_dir/0"

    info "$case_id: converting transport time 0"

    convert_time_to_vtu \
        "$transport_dir" \
        "0" \
        "$TRD_FIELDS" \
        "$vtk_dir/trd_0.vtu" \
        "$log_dir/trd_0.log"

    while IFS= read -r time_value; do
        [[ -n "$time_value" ]] || continue

        time_tag="$(safe_filename "$time_value")"

        info "$case_id: converting transport time $time_value"

        convert_time_to_vtu \
            "$transport_dir" \
            "$time_value" \
            "$TRD_FIELDS" \
            "$vtk_dir/trd_${time_tag}.vtu" \
            "$log_dir/trd_${time_tag}.log"

        converted_count=$((converted_count + 1))
    done < <(list_nonzero_times "$transport_dir")

    if ((converted_count == 0)); then
        warn "$case_id: no reconstructed nonzero transport times found."
    fi
}

# =============================================================================
# 6. CASE PROCESSING
# =============================================================================
append_summary() {
    local case_id="$1"
    local case_dir="$2"
    local status="$3"
    local message="$4"
    local lock="${SUMMARY_CSV}.lockdir"

    local f_case_id f_case_dir f_status f_message

    batch_stage_lock_acquire "$lock" 0.05

    # Post-processing keeps its own field rendering. The Case ID, the Case
    # directory, and the status keep their literal double-quote delimiters and
    # add no inner-quote escaping. Only the message field doubles an inner
    # double quote.
    printf -v f_case_id '"%s"' "$case_id"
    printf -v f_case_dir '"%s"' "$case_dir"
    printf -v f_status '"%s"' "$status"
    batch_stage_csv_quote f_message "$message"

    batch_stage_csv_append_row "$SUMMARY_CSV" \
        "$f_case_id" "$f_case_dir" "$f_status" "$f_message"

    batch_stage_lock_release "$lock"
}

post_outputs_complete() {
    local flow_dir="$1" transport_dir="$2" vtk_dir="$3"
    local flow_latest flow_tag t tag
    [[ -f "$vtk_dir/flow_0.vtu" && -f "$vtk_dir/trd_0.vtu" ]] || return 1
    flow_latest="$(latest_time "$flow_dir")"
    flow_tag="$(safe_filename "$flow_latest")"
    [[ -f "$vtk_dir/flow_latest_${flow_tag}.vtu" ]] || return 1
    while IFS= read -r t; do
        [[ -n "$t" && "$t" != "0" ]] || continue
        tag="$(safe_filename "$t")"
        [[ -f "$vtk_dir/trd_${tag}.vtu" ]] || return 1
    done < <(list_times "$transport_dir")
    return 0
}

build_post_signature() {
    local flow_dir="$1"
    local transport_dir="$2"
    local flow_latest transport_times

    [[ -d "$flow_dir" && -d "$transport_dir" ]] || return 1
    flow_latest="$(latest_time "$flow_dir")"
    transport_times="$(list_times "$transport_dir" | paste -sd, -)"

    printf 'flow_latest=%s\n' "$flow_latest"
    printf 'transport_times=%s\n' "$transport_times"
    printf 'scalar_field=%s\n' "$SCALAR_FIELD"
    printf 'flow_zero_fields=%s\n' "$FLOW_ZERO_FIELDS"
    printf 'flow_result_fields=%s\n' "$FLOW_RESULT_FIELDS"
}

process_case() {
    local case_id="$1"
    local case_dir="$OUT_ABS/$case_id"
    local flow_dir="$case_dir/flow"
    local transport_dir="$case_dir/trd"
    local vtk_dir="$case_dir/vtk"
    local log_dir="$vtk_dir/logs"
    local marker="$vtk_dir/post_processing.complete"
    local current_signature="" stored_signature=""

    info "Processing $case_id"

    if [[ ! -d "$case_dir" ]]; then
        append_summary \
            "$case_id" \
            "$case_dir" \
            "failed" \
            "case directory not found"

        # v4 Sections 18.5 and 23.P: a missing requested case is a failed case.
        # The failure artifact makes the stage exit non-zero.
        echo "$case_id" >>"$FAIL_FILE"
        return 1
    fi

    if [[ "$FORCE_POST" != "1" && -f "$marker" ]]; then
        current_signature="$(build_post_signature "$flow_dir" "$transport_dir" || true)"
        stored_signature="$(cat "$marker" 2>/dev/null || true)"
        if [[ -n "$current_signature" && "$current_signature" == "$stored_signature" ]] &&
           post_outputs_complete "$flow_dir" "$transport_dir" "$vtk_dir"; then
            append_summary "$case_id" "$case_dir" "skipped" "source results unchanged; existing VTU outputs reused"
            info "Skip $case_id: post-processing outputs are current. Set FORCE_POST=1 to rebuild."
            return 0
        fi
    fi

    # Source results changed (or forced): rebuild atomically enough to avoid stale VTUs.
    rm -rf "$vtk_dir"
    mkdir -p "$vtk_dir" "$log_dir"

    if ! (
        convert_flow_case \
            "$case_id" \
            "$flow_dir" \
            "$vtk_dir" \
            "$log_dir"

        convert_transport_case \
            "$case_id" \
            "$transport_dir" \
            "$vtk_dir" \
            "$log_dir"
    ); then
        append_summary \
            "$case_id" \
            "$case_dir" \
            "failed" \
            "VTU conversion failed; see $log_dir"

        echo "$case_id" >>"$FAIL_FILE"
        return 1
    fi

    current_signature="$(build_post_signature "$flow_dir" "$transport_dir")"
    printf '%s\n' "$current_signature" > "$marker"

    append_summary \
        "$case_id" \
        "$case_dir" \
        "completed" \
        "flow and transport VTU files created"

    info "Finished $case_id: $vtk_dir"
}

# Failure counter for discarded child exits. A case job that fails without a
# readable failure artifact must still make the stage non-zero.
JOB_FAILURES=0

# The caller owns the wait-status meaning. Post-processing counts each non-zero
# wait once, in both the free-slot wait and the final drain.
post_wait_status() {
    (( $1 == 0 )) || JOB_FAILURES=$((JOB_FAILURES + 1))
    return 0
}

wait_for_slot() {
    batch_stage_job_pool_wait_for_slot "$PARALLEL_JOBS" : post_wait_status 0
}

wait_for_all_jobs() {
    batch_stage_job_pool_wait_for_all : post_wait_status 0
}

# =============================================================================
# 7. MAIN
# =============================================================================
main() {
    validate_config

    local csv_file row raw_case case_id
    local row_number=1
    local launched=0

    csv_file="$(find_csv_file)"
    load_csv_header "$csv_file"

    info "CSV file      : $csv_file"
    info "Output folder : $OUT_ABS"
    info "Parallel jobs : $PARALLEL_JOBS"
    info "Scalar field  : $SCALAR_FIELD"
    info "FORCE_POST    : $FORCE_POST"
    info "Summary       : $SUMMARY_CSV"

    while IFS= read -r row || [[ -n "$row" ]]; do
        row_number=$((row_number + 1))
        row="${row//$'\r'/}"

        [[ -n "${row//[[:space:]]/}" ]] || continue

        raw_case="$(get_csv_cell "$row" "$CASE_COLUMN")"

        if [[ -z "$raw_case" ]]; then
            warn "CSV row $row_number has an empty Case value."
            continue
        fi

        case_id="$(make_case_id "$raw_case")"

        if [[ "$case_id" == "NA" ]]; then
            warn "CSV row $row_number has an invalid Case value."
            continue
        fi

        if [[ -n "${SEEN_CASES[$case_id]+x}" ]]; then
            warn "Skipping duplicate case: $case_id"
            continue
        fi
        SEEN_CASES["$case_id"]=1

        wait_for_slot

        launched=$((launched + 1))
        info "Launching [$launched]: $case_id"

        process_case "$case_id" < /dev/null &
    done < <(tail -n +2 "$csv_file")

    wait_for_all_jobs

    # The final gate must not trust the failure artifact alone. A failed
    # summary row or a discarded non-zero child exit must also make the stage
    # non-zero, so a failure-artifact write error cannot produce success.
    local failed_rows
    failed_rows="$(
        awk -F, 'NR > 1 { gsub(/"/, "", $3); if ($3 == "failed") c++ }
                 END { print c + 0 }' "$SUMMARY_CSV"
    )"

    if [[ -s "$FAIL_FILE" ]] || ((failed_rows > 0)) || ((JOB_FAILURES > 0)); then
        die "One or more post-processing jobs failed. See $SUMMARY_CSV"
    fi

    rm -f "$FAIL_FILE"

    info "All post-processing jobs completed."
    info "Summary: $SUMMARY_CSV"
}

main "$@"