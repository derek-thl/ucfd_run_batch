# UCFD Batch Runner

This context covers the UCFD OpenFOAM batch execution scripts in `src/`. The project automates DOE simulation batches through a fixed stage pipeline.

The normative technical contract is `docs/RUN_BATCH_HANDOFF_SPEC.md`. The normative authority contract is `AGENTS.md`. This file defines only the stable project language.

## Language

### Batch execution

**UCFD Batch Runner**:
The script family that runs DOE batches of UCFD OpenFOAM cases through the fixed stage pipeline.
_Avoid_: batch system, pipeline tool

**DOE Batch CSV**:
One input CSV file that defines one batch. Each data row defines one Case.
_Avoid_: input file, experiment sheet

**Batch ID**:
The numeric identifier that the Orchestrator extracts from a DOE Batch CSV filename. Two DOE Batch CSVs must not resolve to the same Batch ID in one run.
_Avoid_: batch number, run number

**Batch Workspace**:
The generated `batch_<id>` directory that holds the Cases and artifacts of one batch.
_Avoid_: output folder, run directory

**Case**:
One simulation configuration from one DOE Batch CSV row, materialized as one case directory inside a Batch Workspace.
_Avoid_: job, run, sample

**Stage**:
One step of the fixed pipeline: setup, mesh, flow, transport, post-processing.
_Avoid_: phase, step, task

**Stage Runner**:
The script that executes one Stage for the Cases of one batch: `setup_cases.sh`, `run_mesh_cases.sh`, `run_flow_cases.sh`, `run_transport_cases.sh`, or `run_post_processing_cases.sh`.
_Avoid_: worker, stage script (in prose)

**Orchestrator**:
`run_batch.sh`. The top-level script that selects DOE Batch CSVs, resolves Batch Workspaces, orders Stages, and controls concurrency.
_Avoid_: wrapper, driver, main script

**Failure Artifact**:
A file that a Stage Runner or the Orchestrator writes to record a Case, Stage, or batch failure, for example a stage failure file, a summary, or a log.
_Avoid_: error file, crash dump

### Collaboration

**Execution Frontier**:
The current cross-Agent project state: what is complete, what is blocked, who acts next, and the exact next action.
_Avoid_: status, progress

**Tracking Issue**:
The single active GitHub Issue that records the Execution Frontier for the project.
_Avoid_: status thread, meta issue
