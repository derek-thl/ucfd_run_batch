#!/usr/bin/env bash
# Stage-script stub used by the top-level run_batch.sh contract tests.
#
# A generated stub sets STUB_ORIGIN and then sources this file through $STUB_LIB.
# The stub records the exact argument vector, the working directory, and the
# cross-stage environment that run_batch.sh exports.
#
# Records:
#   $STUB_RECORD_DIR/stubs.log              one line per call
#   $STUB_RECORD_DIR/<stage>.<batch>.argv   argument vector, one token per line
#   $STUB_RECORD_DIR/<stage>.<batch>.env    recorded environment values

set -u

STUB_US=$'\x1f'
: "${STUB_RECORD_DIR:?STUB_RECORD_DIR must be set for stage stubs}"
mkdir -p "$STUB_RECORD_DIR"

stub_file_name="${0##*/}"

case "$stub_file_name" in
    setup_cases.sh) stub_stage="setup" ;;
    run_mesh_cases.sh) stub_stage="mesh" ;;
    run_flow_cases.sh) stub_stage="flow" ;;
    run_transport_cases.sh) stub_stage="transport" ;;
    run_post_processing_cases.sh) stub_stage="post" ;;
    *) stub_stage="unknown" ;;
esac

stub_batch="${BATCH_NUMBER:-none}"
stub_origin="${STUB_ORIGIN:-unknown}"
stub_prefix="${STUB_RECORD_DIR}/${stub_stage}.${stub_batch}"

stub_joined=""
for stub_arg in "$@"; do
    stub_joined+="${stub_arg}${STUB_US}"
done

stub_lock="${STUB_RECORD_DIR}/.lockdir"
while ! mkdir "$stub_lock" 2>/dev/null; do
    sleep 0.02
done
printf '%s\t%s\t%s\t%s\t%s\n' \
    "$stub_stage" "$stub_origin" "$stub_batch" "$PWD" "$stub_joined" \
    >> "${STUB_RECORD_DIR}/stubs.log"
rmdir "$stub_lock"

: > "${stub_prefix}.argv"
for stub_arg in "$@"; do
    printf '%s\n' "$stub_arg" >> "${stub_prefix}.argv"
done

{
    printf 'stage=%s\n' "$stub_stage"
    printf 'origin=%s\n' "$stub_origin"
    printf 'cwd=%s\n' "$PWD"
    printf 'SCALAR_FIELD=%s\n' "${SCALAR_FIELD:-}"
    printf 'BATCH_CSV=%s\n' "${BATCH_CSV:-}"
    printf 'BATCH_CSV_PATH=%s\n' "${BATCH_CSV_PATH:-}"
    printf 'BATCH_NUMBER=%s\n' "${BATCH_NUMBER:-}"
    printf 'BATCH_DIR=%s\n' "${BATCH_DIR:-}"
} > "${stub_prefix}.env"

# Forced failure control. STUB_FAIL_STAGES holds space-separated tokens.
# A token is either "<stage>" or "<stage>:<batch_number>".
for stub_token in ${STUB_FAIL_STAGES:-}; do
    if [[ "$stub_token" == "$stub_stage" || "$stub_token" == "${stub_stage}:${stub_batch}" ]]; then
        echo "stage stub ${stub_stage}: forced failure for batch ${stub_batch}" >&2
        exit 3
    fi
done

echo "stage stub ${stub_stage} (${stub_origin}) completed for batch ${stub_batch}"
exit 0
