#!/usr/bin/env bash
#
# Ensure every case_*/flow case contains:
#   0/wallDistance
#
# Generate it with:
#   checkMesh -time 0 -writeAllFields

set -euo pipefail
trap 'echo ">>> [ERROR] ${0##*/} failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_ALL=C

PARALLEL_JOBS="${PARALLEL_JOBS:-2}"
OUT_DIR="./"
FORCE_WALL_DISTANCE="${FORCE_WALL_DISTANCE:-0}"

usage() {
    cat <<'USAGE'
Usage:
  bash check_wall_distance_cases.sh [options]

Options:
  -O, --output-dir <dir>  Directory containing case_*/flow cases.
  -j <jobs>               Number of parallel jobs. Default: 2.
  --force                 Run checkMesh even if wallDistance was detected.
  -h, --help

Environment:
  PARALLEL_JOBS=2
  FORCE_WALL_DISTANCE=1
USAGE
}

info() {
    echo ">>> $*"
}

die() {
    echo ">>> [ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "'$1' not found in PATH."
}

safe_name() {
    echo "$1" |
        sed \
            -e 's#[/[:space:]]#_#g' \
            -e 's#[^0-9A-Za-z._-]#_#g'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -O|--output-dir)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            OUT_DIR="$2"
            shift 2
            ;;
        -j)
            [[ $# -ge 2 ]] || die "Missing value for -j"
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --force)
            FORCE_WALL_DISTANCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] &&
    (( PARALLEL_JOBS >= 1 )) ||
    die "PARALLEL_JOBS must be an integer >= 1."

[[ "$FORCE_WALL_DISTANCE" == "0" ||
   "$FORCE_WALL_DISTANCE" == "1" ]] ||
    die "FORCE_WALL_DISTANCE must be 0 or 1."

[[ -d "$OUT_DIR" ]] || die "Output directory not found: $OUT_DIR"

need_cmd checkMesh
need_cmd awk
need_cmd find
need_cmd sed
need_cmd tee

OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"
LOG_DIR="$OUT_ABS/_wall_distance_logs"
FAIL_FILE="$OUT_ABS/.check_wall_distance_failed"
SUMMARY_FILE="$OUT_ABS/check_wall_distance_summary.csv"
SUMMARY_LOCK="${SUMMARY_FILE}.lockdir"

mkdir -p "$LOG_DIR"
: > "$FAIL_FILE"
printf 'case_name,case_dir,target_time,status,message\n' > "$SUMMARY_FILE"

csv_quote() {
    local value="${1:-}"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

with_summary_lock() {
    while ! mkdir "$SUMMARY_LOCK" 2>/dev/null; do
        sleep 0.05
    done

    "$@"
    local rc=$?

    rmdir "$SUMMARY_LOCK"
    return "$rc"
}

append_summary_unlocked() {
    local case_name="$1"
    local case_dir="$2"
    local latest_time="$3"
    local status="$4"
    local message="$5"

    {
        csv_quote "$case_name"
        printf ','
        csv_quote "$case_dir"
        printf ','
        csv_quote "$latest_time"
        printf ','
        csv_quote "$status"
        printf ','
        csv_quote "$message"
        printf '\n'
    } >> "$SUMMARY_FILE"
}

append_summary() {
    with_summary_lock append_summary_unlocked "$@"
}

mark_failed_unlocked() {
    echo "$1" >> "$FAIL_FILE"
}

mark_failed() {
    with_summary_lock mark_failed_unlocked "$1"
}

has_wall_distance_field() {
    local case_dir="$1"

    [[ -f "$case_dir/0/wallDistance" ||
       -f "$case_dir/0/wallDistance.gz" ]]
}

check_one_case() {
    local case_dir="$1"
    local case_name
    local log_file

    case_name="${case_dir#"$OUT_ABS"/}"
    log_file="$LOG_DIR/$(safe_name "$case_name").log"

    if [[ "$FORCE_WALL_DISTANCE" != "1" ]] &&
       has_wall_distance_field "$case_dir"; then
        info "EXISTS: $case_name, field=0/wallDistance"
        append_summary \
            "$case_name" \
            "$case_dir" \
            "0" \
            "existing" \
            "wallDistance field found in time directory 0"
        return 0
    fi

    info "RUNNING: $case_name, targetTime=0"

    if (
        cd "$case_dir"

        {
            echo ">>> Case       : $case_name"
            echo ">>> Directory  : $case_dir"
            echo ">>> Target time: 0"
            echo ">>> Command    : checkMesh -time 0 -writeAllFields"

            checkMesh -time 0 -writeAllFields
        } 2>&1 | tee "$log_file"
    ); then
        if ! has_wall_distance_field "$case_dir"; then
            info "FAILED: $case_name; 0/wallDistance not found after checkMesh. See $log_file"
            append_summary \
                "$case_name" \
                "$case_dir" \
                "0" \
                "failed" \
                "checkMesh succeeded but 0/wallDistance was not found; see log: $log_file"
            mark_failed "$case_name"
            return 1
        fi

        info "FINISHED: $case_name, field=0/wallDistance"
        append_summary \
            "$case_name" \
            "$case_dir" \
            "0" \
            "generated" \
            "wallDistance generated in time directory 0"
    else
        info "FAILED: $case_name; see $log_file"
        append_summary \
            "$case_name" \
            "$case_dir" \
            "0" \
            "failed" \
            "see log: $log_file"
        mark_failed "$case_name"
        return 1
    fi
}

wait_for_slot() {
    while (( $(jobs -rp | wc -l | tr -d ' ') >= PARALLEL_JOBS )); do
        if (( BASH_VERSINFO[0] > 4 ||
              (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
            wait -n || true
        else
            sleep 0.5
        fi
    done
}

mapfile -d '' CASE_DIRS < <(
    find "$OUT_ABS" \
        -mindepth 2 \
        -maxdepth 2 \
        -type d \
        -name flow \
        -path '*/case_*/flow' \
        -print0 |
        sort -z
)

(( ${#CASE_DIRS[@]} > 0 )) ||
    die "No case_*/flow directories found under: $OUT_ABS"

info "Output directory : $OUT_ABS"
info "Cases found      : ${#CASE_DIRS[@]}"
info "Parallel jobs    : $PARALLEL_JOBS"
info "Force execution  : $FORCE_WALL_DISTANCE"
info "Logs             : $LOG_DIR"
info "Summary          : $SUMMARY_FILE"

started=0

for case_dir in "${CASE_DIRS[@]}"; do
    wait_for_slot

    started=$((started + 1))
    info "Launching [$started/${#CASE_DIRS[@]}]: ${case_dir#"$OUT_ABS"/}"

    check_one_case "$case_dir" < /dev/null &
done

while (( $(jobs -rp | wc -l | tr -d ' ') > 0 )); do
    if (( BASH_VERSINFO[0] > 4 ||
          (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
        wait -n || true
    else
        sleep 0.5
    fi
done

if [[ -s "$FAIL_FILE" ]]; then
    die "One or more cases failed. See $FAIL_FILE, $SUMMARY_FILE and $LOG_DIR"
fi

rm -f "$FAIL_FILE"

info "All wallDistance checks completed."
info "Summary: $SUMMARY_FILE"