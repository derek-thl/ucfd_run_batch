#!/usr/bin/env bash
# Section 23.I - exact --save-times argument forwarding.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace savetimes)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "${output}/batch_1"
make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"

out="$(bash "$RUN_BATCH" --stage transport --save-times "60,120,300" \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "transport with --save-times must succeed: $out"

# The child must receive exactly two adjacent tokens.
mapfile -t argv < <(stub_argv transport 1)
found=0
for (( i = 0; i < ${#argv[@]}; i++ )); do
    [[ "${argv[$i]}" == "--save-times" ]] || continue
    found=$(( found + 1 ))
    assert_eq "60,120,300" "${argv[$((i + 1))]:-}" \
        "--save-times forwards one exact list token"
done
assert_eq 1 "$found" "--save-times appears exactly once in the child argv"

# No literal backslash may reach the child argument.
joined="$(stub_argv_joined transport 1)"
assert_not_contains "$joined" '\' "the child argument holds no literal backslash"

# The default list applies when the option is absent.
workspace="$(new_workspace default)"
use_stub_records "$workspace"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "${output}/batch_1"
make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"

out="$(bash "$RUN_BATCH" --stage transport -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
assert_status 0 "$status" "transport without --save-times must succeed: $out"
assert_eq "60,120,300" "$(stub_arg_after transport 1 --save-times)" \
    "the default save-time list is 60,120,300"

# The top-level v4 interface rejects a non-integer list.
out="$(bash "$RUN_BATCH" --stage transport --save-times "60;120" \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
assert_failure "$status" "the narrow v4 save-time syntax rejects a semicolon list"
assert_contains "$out" "--save-times must be comma-separated non-negative integers" \
    "the failure explains the v4 save-time syntax"
