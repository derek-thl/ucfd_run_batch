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
