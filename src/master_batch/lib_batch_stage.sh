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
