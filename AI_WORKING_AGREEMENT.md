# AI Working Agreement

This file is a human-readable summary of the multi-account AI workflow.

`AGENTS.md` is the normative authority contract. When this summary and `AGENTS.md` differ, `AGENTS.md` wins.

## Roles and accounts

| Role | GitHub account |
|---|---|
| Product Owner / Tech Lead | `derek-thl` |
| Architect / Reviewer Agent | `derek-architect` |
| Implementer Agent | `derek-implementer` |

Each role uses its own GitHub account, Git author, host, clone, and AI session. GitHub is the only shared source of truth.

## The work loop

1. The Product Owner approves scope and intent.
2. The Architect writes one bounded implementation Issue with an exact base SHA, a branch name, a write allowlist, and acceptance tests.
3. The Tracking Issue frontier authorizes implementation: `READY_FOR_IMPLEMENTATION_AT_<SHA>`.
4. The Implementer implements only the approved scope, pushes the branch, and opens a Pull Request with evidence.
5. The Architect reviews the exact head commit and publishes `ARCHITECT_APPROVED_AT_<SHA>` or `CHANGES_REQUESTED_AT_<SHA>`.
6. Required GitHub Actions pass at the approved commit.
7. The Product Owner merges. The frontier records `MERGED_COMPLETE_AT_<MAIN_SHA>`.

Each frontier change is one new append-only comment on the active Tracking Issue, with the table:

`| Item | State | Next actor | Next action | Evidence |`

## Key rules

- No actor self-approves. The Architect does not merge. The Implementer does not approve or merge.
- A review or approval names one exact commit SHA. A new commit needs a new review.
- Work stays inside the Issue write allowlist. A needed change outside the allowlist becomes a `BLOCKED_BY_<CAUSE>` frontier entry, not a silent edit.
- Control-plane text uses ASD-STE100 Simplified Technical English and the terms in `CONTEXT.md`.
- Agent Skills in `.agents/skills/` aid execution. Skills and triage labels grant no project authority.

## Where things live

- Authority contract: `AGENTS.md`
- Batch-runner technical contract: `docs/RUN_BATCH_HANDOFF_SPEC.md`
- Project language: `CONTEXT.md`
- Skills configuration: `docs/agents/`
- Model entry points: `CODEX.md`, `CLAUDE.md`
