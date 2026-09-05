#!/usr/bin/env bash
# lib_batch_stage.sh v4
#
# Internal shared Stage library for the UCFD batch Stage Runners.
#
# This library and the Stage Runner that sources it are one deployment unit.
# A Stage Runner resolves this library only from the physical directory of its
# own target. A Stage Runner never searches the current working directory,
# PATH, MASTER_BATCH_DIR, BATCH_DIR, or an environment override.
#
# Source-time work is limited to variable assignment and function definition.
# This library performs no file, process, network, or console work when it is
# sourced.
#
# The library publishes its API version. Each Stage Runner that uses the
# library declares the version that it requires and rejects any other value.
#
# I-G0 establishes the deployment and verification foundation only. The library
# defines no helper function yet. Later authorized Items add shared helpers in
# the batch_stage_ namespace.

# The API version stays non-exported, so that the variable never enters a Stage
# Runner child-process environment. The side-effect-free reference below exists
# only to prevent ShellCheck SC2034 for a variable that only a sourcing Stage
# Runner reads. A suppression directive is not used. The reference writes no
# output, creates no process, defines no helper, and changes no value.
readonly BATCH_STAGE_LIBRARY_API_VERSION=1
: "$BATCH_STAGE_LIBRARY_API_VERSION"

# batch_stage_lock_acquire <lock-path> <retry-seconds>
#
# The helper runs the current mkdir acquisition attempt and retries without a
# limit until the attempt succeeds. Only the acquisition attempt sends standard
# error to /dev/null. The helper returns 0 only after acquisition succeeds.
#
# The helper adds no timeout, no retry limit, no stale-lock detection, no owner
# file, no trap, no signal handling, no backoff, no logging, no argument
# validation, and no flock. A failed sleep keeps the current shell failure
# behavior.
batch_stage_lock_acquire() {
    while ! mkdir "$1" 2>/dev/null; do
        sleep "$2"
    done
}

# batch_stage_lock_release <lock-path>
#
# The helper runs the current rmdir release operation on the exact caller path
# and returns the exact rmdir status. The helper never suppresses, retries,
# replaces, or normalizes that status. The helper never removes a non-empty lock
# directory and never uses recursive removal. Each caller keeps its own status
# interpretation.
batch_stage_lock_release() {
    rmdir "$1"
}

# batch_stage_csv_quote <output-variable> <value>
#
# The helper renders one CSV field into the named caller variable. It doubles
# each double quote and adds one leading and one trailing double quote. The
# assignment preserves every input byte, including a trailing newline byte,
# because the helper never uses command substitution.
#
# The helper writes no standard output and no standard error. The helper returns
# the exact status of its assignment. The helper performs no file, lock,
# process, network, or console operation. An absent value argument gives an
# empty value.
batch_stage_csv_quote() {
    local __batch_stage_csv_quote_value="${2-}"
    __batch_stage_csv_quote_value="${__batch_stage_csv_quote_value//\"/\"\"}"
    printf -v "$1" '"%s"' "$__batch_stage_csv_quote_value"
}

# batch_stage_csv_append_row <target-path> <rendered-field>...
#
# The helper joins the caller-rendered fields with one comma, adds one newline
# after the last field, and appends the complete row to the target path with one
# printf operation and one append redirection. Each rendered field keeps every
# byte, because the helper adds no quote escaping and uses no command
# substitution.
#
# The helper acquires and releases no lock, creates no temporary file, and
# prints no diagnostic. The helper returns the exact append status, so a caller
# keeps its own failure interpretation.
batch_stage_csv_append_row() {
    local __batch_stage_csv_append_row_target="$1"
    shift
    local IFS=,
    printf '%s\n' "$*" >> "$__batch_stage_csv_append_row_target"
}

# batch_stage_job_pool_running_count
#
# The helper counts only active background processes and writes the decimal
# count to standard output. The helper writes no diagnostic.
batch_stage_job_pool_running_count() {
    jobs -rp | wc -l | tr -d ' '
}

# batch_stage_job_pool_wait_n_supported
#
# The helper returns 0 only when this Bash supports `wait -n`. Bash 4.0 through
# 4.2 therefore stays on the fallback path. The helper inspects only
# BASH_VERSINFO and writes no output.
batch_stage_job_pool_wait_n_supported() {
    (( BASH_VERSINFO[0] > 4 ||
       (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))
}

# batch_stage_job_pool_wait_for_slot <maximum-running> <before-wait-callback>
#     <wait-status-callback> <post-cycle-seconds>
#
# The helper waits until fewer than <maximum-running> background processes are
# active. Each callback is one command name that the helper invokes directly.
# The helper never uses eval, a command string, or an environment override.
#
# The helper never launches a Case, never counts a child status, never owns a
# caller counter, and never uses a wait status as its own return status. A
# non-zero child status reaches the caller-owned wait-status callback before it
# can affect the caller shell. The wait-status callback is not called on the
# Bash 4.0 through 4.2 fallback path.
#
# Every local name uses the __batch_stage_job_pool_ prefix, because Bash
# functions use dynamic scoping and a caller callback may use its own locals.
batch_stage_job_pool_wait_for_slot() {
    local __batch_stage_job_pool_maximum="$1"
    local __batch_stage_job_pool_before="$2"
    local __batch_stage_job_pool_status="$3"
    local __batch_stage_job_pool_post_cycle_seconds="$4"
    local __batch_stage_job_pool_wait_status

    while true; do
        if (( $(batch_stage_job_pool_running_count) < __batch_stage_job_pool_maximum )); then
            return 0
        fi

        "$__batch_stage_job_pool_before"

        if batch_stage_job_pool_wait_n_supported; then
            __batch_stage_job_pool_wait_status=0
            wait -n || __batch_stage_job_pool_wait_status=$?
            "$__batch_stage_job_pool_status" "$__batch_stage_job_pool_wait_status"
        else
            sleep 0.5
        fi

        if [[ "$__batch_stage_job_pool_post_cycle_seconds" != "0" ]]; then
            sleep "$__batch_stage_job_pool_post_cycle_seconds"
        fi
    done
}

# batch_stage_job_pool_wait_for_all <before-wait-callback> <wait-status-callback>
#     <post-cycle-seconds>
#
# The helper waits until no active background process remains. The helper uses
# `jobs -rp` and never `jobs -p`. Every other rule of
# batch_stage_job_pool_wait_for_slot applies without change.
batch_stage_job_pool_wait_for_all() {
    local __batch_stage_job_pool_before="$1"
    local __batch_stage_job_pool_status="$2"
    local __batch_stage_job_pool_post_cycle_seconds="$3"
    local __batch_stage_job_pool_wait_status

    while true; do
        if (( $(batch_stage_job_pool_running_count) == 0 )); then
            return 0
        fi

        "$__batch_stage_job_pool_before"

        if batch_stage_job_pool_wait_n_supported; then
            __batch_stage_job_pool_wait_status=0
            wait -n || __batch_stage_job_pool_wait_status=$?
            "$__batch_stage_job_pool_status" "$__batch_stage_job_pool_wait_status"
        else
            sleep 0.5
        fi

        if [[ "$__batch_stage_job_pool_post_cycle_seconds" != "0" ]]; then
            sleep "$__batch_stage_job_pool_post_cycle_seconds"
        fi
    done
}

# batch_stage_csv_tokenize <output-array-name> <line>
#
# The helper splits one CSV record into the named dynamically scoped caller
# array. Comma is the only delimiter. The `read -a` operation clears the caller
# array before it assigns, so no element of an earlier record survives.
#
# The helper keeps the current simple Bash parser without change. It adds no
# quote parsing, quote removal, quote unescaping, carriage-return removal, or
# row-shape validation. An empty field between two commas stays empty, the one
# empty element after a trailing delimiter stays dropped, and a field count that
# differs from the header count stays accepted.
#
# The helper writes no standard output and no standard error, and returns the
# exact `read` status. An absent line argument gives an empty line.
batch_stage_csv_tokenize() {
    IFS=, read -r -a "$1" <<< "${2-}"
}

# batch_stage_csv_normalize_header <trim-callback> <header-value>
#
# The helper normalizes one header field. It calls the caller trim callback once
# for the exact supplied value, captures that output with one plain assignment,
# and lowercases the captured value with one echo and tr pipeline. Only the
# lowercase value reaches standard output, and the helper returns the exact
# status of that pipeline.
#
# The helper invokes the callback directly, so each Stage Runner keeps its own
# trim behavior. The helper removes no quote, carriage-return byte, or
# whitespace of its own, writes no diagnostic, and guards no failure. The
# caller `set -e` behavior stays the failure path.
batch_stage_csv_normalize_header() {
    local __batch_stage_csv_normalize_header_value
    __batch_stage_csv_normalize_header_value="$("$1" "${2-}")"
    echo "$__batch_stage_csv_normalize_header_value" | tr '[:upper:]' '[:lower:]'
}

# batch_stage_csv_find_column <index-array-name> <alias>...
#
# The helper inspects the caller-named associative index for each alias in the
# exact caller-supplied order. Each alias is lowercased with one echo and tr
# pipeline, and Bash indirect expansion reads the named index. The helper writes
# the decimal zero-based index of the first matching alias and returns 0. When
# no alias matches, the helper writes nothing and returns 1.
#
# Alias priority stays caller-owned, so the first alias in the caller list stays
# authoritative. The helper defines no alias list, decides no required column,
# calls no Stage Runner diagnostic, writes no diagnostic, and never modifies the
# named index. The named index must be a caller `declare -A` associative array,
# and no alias may hold `$`, a backtick, `[`, or `]`.
batch_stage_csv_find_column() {
    local __batch_stage_csv_find_column_index="$1"
    shift
    local __batch_stage_csv_find_column_alias
    local __batch_stage_csv_find_column_key
    local __batch_stage_csv_find_column_reference

    for __batch_stage_csv_find_column_alias in "$@"; do
        __batch_stage_csv_find_column_key="$(
            echo "$__batch_stage_csv_find_column_alias" | tr '[:upper:]' '[:lower:]')"
        __batch_stage_csv_find_column_reference="${__batch_stage_csv_find_column_index}[${__batch_stage_csv_find_column_key}]"
        if [[ -n "${!__batch_stage_csv_find_column_reference+x}" ]]; then
            echo "${!__batch_stage_csv_find_column_reference}"
            return 0
        fi
    done

    return 1
}

# batch_stage_csv_get_cell <trim-callback> <row-line> <zero-based-index>
#
# The helper tokenizes the exact supplied row line, selects the exact zero-based
# index, substitutes an empty string when that index is absent, and invokes the
# caller trim callback with the selected value as its last command. The callback
# therefore owns the exact output and the exact status, and the helper captures
# neither.
#
# The helper validates no index, field count, field value, Case ID, or row, and
# removes no carriage-return byte, whitespace, or quote byte of its own.
batch_stage_csv_get_cell() {
    local -a __batch_stage_csv_get_cell_cells
    batch_stage_csv_tokenize __batch_stage_csv_get_cell_cells "${2-}"
    "$1" "${__batch_stage_csv_get_cell_cells[${3-}]:-}"
}

# batch_stage_progress_tick <due-output-variable> <last-time-variable>
#     <interval-seconds> <force>
#
# The helper decides whether one aggregate-progress update is due. The helper
# reads the current second exactly once, compares that second with the
# caller-owned last-time value, and writes the decimal decision to the
# caller-owned due-output variable. The helper updates the caller-owned
# last-time variable only when the update is due.
#
# The helper reads the caller-owned last-time value through Bash indirect
# expansion, so the helper needs no name reference and stays compatible with
# Bash 4.0. Both caller assignments use `printf -v`, so the helper needs no
# eval, no command string, no temporary file, no process substitution, and no
# environment override.
#
# The helper returns the exact non-zero `date` status before it changes either
# caller variable. A caller with `errexit` therefore keeps its current failure
# effect. The due decision uses an `if` condition, so a not-due result cannot
# activate caller `errexit`.
#
# The helper writes no standard output, writes no standard error, calls no
# callback, counts no process, and owns no persistent library variable. The
# helper adds no clock correction, no monotonic clock, no interval limit, no
# sleep, no retry, no timeout, and no date fallback. The caller keeps every
# progress message, every counter, every interval value, every force value, and
# every timing reset.
#
# Every local name uses the __batch_stage_progress_tick_ prefix, because Bash
# functions use dynamic scoping and a caller supplies its own due-output,
# last-time, and progress variable names.
batch_stage_progress_tick() {
    local __batch_stage_progress_tick_due_name="$1"
    local __batch_stage_progress_tick_last_name="$2"
    local __batch_stage_progress_tick_interval="$3"
    local __batch_stage_progress_tick_force="$4"
    local __batch_stage_progress_tick_now
    local __batch_stage_progress_tick_status=0

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
        return 0
    fi

    printf -v "$__batch_stage_progress_tick_due_name" '%s' 0
    return 0
}
