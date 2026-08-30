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

# The API version carries the export attribute so that ShellCheck 0.9.0 reports
# no finding for a variable that only a sourcing Stage Runner reads. A
# suppression directive is not used. An inherited value cannot satisfy a Stage
# Runner check, because each Stage Runner removes both API-version variables
# before it sources this library.
export BATCH_STAGE_LIBRARY_API_VERSION=1
readonly BATCH_STAGE_LIBRARY_API_VERSION
