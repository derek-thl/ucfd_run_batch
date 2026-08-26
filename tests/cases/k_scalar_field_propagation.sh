#!/usr/bin/env bash
# Section 23.K - SCALAR_FIELD reaches setup, transport, and post.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace scalar)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(bash "$RUN_BATCH" --scalar-field c -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "--scalar-field c must succeed: $out"
assert_contains "$out" "Scalar field    : c" "preflight reports the scalar field"

assert_eq "c" "$(stub_env setup 1 SCALAR_FIELD)"     "setup sees SCALAR_FIELD=c"
assert_eq "c" "$(stub_env transport 1 SCALAR_FIELD)" "transport sees SCALAR_FIELD=c"
assert_eq "c" "$(stub_env post 1 SCALAR_FIELD)"      "post sees SCALAR_FIELD=c"

# The cross-stage environment contract also exports the batch identity.
assert_eq "1" "$(stub_env transport 1 BATCH_NUMBER)" "BATCH_NUMBER is exported"
assert_eq "output_batch_1.csv" "$(stub_env transport 1 BATCH_CSV)" \
    "BATCH_CSV is the CSV file name"
assert_eq "${output}/batch_1" "$(stub_env transport 1 BATCH_DIR)" \
    "BATCH_DIR is the batch workspace"

# The default scalar field is T.
workspace="$(new_workspace default)"
use_stub_records "$workspace"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(bash "$RUN_BATCH" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
assert_status 0 "$status" "the default pipeline must succeed: $out"
assert_eq "T" "$(stub_env transport 1 SCALAR_FIELD)" "the default scalar field is T"

# The SCALAR_FIELD environment default is supported, and the CLI wins over it.
workspace="$(new_workspace envform)"
use_stub_records "$workspace"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(SCALAR_FIELD=s bash "$RUN_BATCH" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
assert_status 0 "$status" "SCALAR_FIELD=s must succeed: $out"
assert_eq "s" "$(stub_env post 1 SCALAR_FIELD)" "the environment default applies"

use_stub_records "${workspace}/second"
out="$(SCALAR_FIELD=s bash "$RUN_BATCH" --scalar-field c --stage transport \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
assert_status 0 "$status" "the CLI override must succeed: $out"
assert_eq "c" "$(stub_env transport 1 SCALAR_FIELD)" \
    "the CLI value wins over the environment default"

# An invalid field token is rejected.
out="$(bash "$RUN_BATCH" --scalar-field '1bad' -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
assert_failure "$status" "an invalid scalar-field token must be rejected"
assert_contains "$out" "--scalar-field must be a valid OpenFOAM field token" \
    "the failure explains the field-token rule"
