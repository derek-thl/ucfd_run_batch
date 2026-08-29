# UCFD Batch Runner

This context covers UCFD OpenFOAM batch simulation execution. The project automates DOE simulation batches through a fixed stage pipeline.

The normative technical contract is `docs/RUN_BATCH_HANDOFF_SPEC.md`. The normative authority contract is `AGENTS.md`. This file defines only the stable project language. Implementation and behavior stay in the technical contract.

## Language

### Batch execution

**UCFD Batch Runner**:
The tool that runs DOE batches of UCFD OpenFOAM simulation Cases through the fixed Stage pipeline.
_Avoid_: batch system, pipeline tool

**DOE Batch CSV**:
One input table that defines one batch. Each data row defines one Case.
_Avoid_: input file, experiment sheet

**Batch ID**:
The unique identifier of one batch.
_Avoid_: batch number, run number

**Batch Workspace**:
The working area that holds the Cases and Failure Artifacts of one batch.
_Avoid_: output folder, run directory

**Case**:
One simulation configuration that comes from one DOE Batch CSV row.
_Avoid_: job, run, sample

**Stage**:
One step of the fixed pipeline: setup, mesh, flow, transport, post-processing.
_Avoid_: phase, step, task

**Stage Runner**:
The execution unit that performs one Stage for the Cases of one batch.
_Avoid_: worker, stage script (in prose)

**Orchestrator**:
The top-level component that coordinates the Batch Workspaces, Stages, and Stage Runners of every requested batch.
_Avoid_: wrapper, driver, main script

**Failure Artifact**:
A record that documents a Case, Stage, or batch failure.
_Avoid_: error file, crash dump

### Collaboration

**Execution Frontier**:
The current cross-Agent project state: what is complete, what is blocked, who acts next, and the exact next action.
_Avoid_: status, progress

**Tracking Issue**:
The single active GitHub Issue that records the Execution Frontier for the project.
_Avoid_: status thread, meta issue
