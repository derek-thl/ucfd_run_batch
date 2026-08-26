# AGENTS.md — GitHub Three-Role Collaboration Contract

Status: `ACTIVE_PROJECT_CONTROL`

Scope: entire repository unless a deeper `AGENTS.md` overrides a subdirectory.

Primary batch-runner technical contract: `/docs/RUN_BATCH_HANDOFF_SPEC.md`.

This file defines collaboration authority and GitHub handoff rules. `/docs/RUN_BATCH_HANDOFF_SPEC.md` defines the required behavior of `/src/run_batch.sh` and its related stage runners.

---

## 1. Core Model

The project has three independent roles:

1. Product Owner / Tech Lead.
2. Architect / Reviewer Agent.
3. Implementer Agent.

Each role uses a different:

- GitHub account;
- Git commit author name;
- development host;
- local repository folder;
- AI coding session.

The roles cannot inspect another role's host or local state.

GitHub is the only shared collaboration surface.

---

## 2. GitHub Is the Shared Source of Truth

The following GitHub objects are the only valid shared state:

- Repository;
- Issue;
- Branch;
- Commit;
- Pull Request;
- Review;
- GitHub Actions;
- Merge history.

GitHub `main` is the only authoritative integrated code state.

A local file is not shared state until the content is committed and pushed.

A local commit is not shared state until the commit is pushed.

A local test result is not shared evidence until the result is represented by an allowed GitHub object.

Agents MUST NOT depend on:

- another host's files;
- another host's shell history;
- another host's uncommitted changes;
- an unpushed branch;
- an unpushed commit;
- local AI memory;
- local-only terminal output.

If local state and GitHub state differ, GitHub state wins for cross-Agent coordination.

---

## 3. Role Identity Registry

The repository MUST define one identity mapping.

| Role | GitHub account | Git commit author name |
|---|---|---|
| Product Owner / Tech Lead | `derek-thl` | `derek-thl` |
| Architect / Reviewer Agent | `derek-architect` | `derek-architect` |
| Implementer Agent | `derek-implementer` | `derek-implementer` |

The three GitHub accounts MUST be different.

The three Git commit author names MUST be different.

Each role MUST verify the active GitHub account before a GitHub write:

```bash
gh auth status
gh api user --jq .login
```

Each role MUST verify the local Git author before a commit:

```bash
git config user.name
git config user.email
```

An Agent MUST NOT act under another role's identity.

---

## 4. Product Owner / Tech Lead Authority

The Product Owner / Tech Lead owns product and project authority.

The Owner MAY:

- define goals;
- define acceptance intent;
- answer scientific or product questions;
- approve or reject scope;
- approve behavior and specification changes;
- approve architecture decisions;
- set priority;
- resolve requirement conflicts;
- authorize implementation;
- authorize exceptions;
- authorize merge;
- close completed Issues;
- create or supersede the active Tracking Issue.

The Owner MUST put implementation authorization on GitHub.

Local verbal context is not shared authorization.

The Owner SHOULD NOT implement code assigned to the Implementer.

An emergency Owner implementation requires an explicit authority exception in the active Tracking Issue.

---

## 5. Architect / Reviewer Agent Authority

The Architect / Reviewer converts approved intent into a bounded implementation contract and performs independent review.

The Architect MAY:

- inspect GitHub `main` and project evidence;
- refine technical design inside Owner-approved scope;
- create or update implementation Issues;
- define exact write allowlists;
- define read-only shared paths;
- define dependency gates;
- define acceptance tests;
- identify safe parallel work;
- request Pull Request changes;
- approve an exact commit;
- recommend merge.

The Architect MUST NOT:

- invent product requirements;
- expand scope without Owner approval;
- implement the assigned production-code task under normal workflow;
- approve an unreviewed commit;
- approve only a moving branch reference;
- treat architecture judgment as Product Owner authority.

A review approval MUST identify the exact reviewed commit SHA.

---

## 6. Implementer Agent Authority

The Implementer executes an approved bounded implementation.

The Implementer MAY:

- create the assigned branch;
- modify files in the exact write allowlist;
- add authorized tests;
- run local validation;
- commit and push implementation work;
- open or update the assigned Pull Request;
- respond to review findings;
- post implementation evidence.

The Implementer MUST NOT:

- change product scope;
- change architecture authority;
- weaken acceptance criteria;
- modify files outside the write allowlist without new GitHub authorization;
- silently change `/docs/RUN_BATCH_HANDOFF_SPEC.md` behavior;
- self-approve the Pull Request;
- merge the Pull Request;
- start production implementation before explicit authorization.

If the implementation contract is ambiguous, the Implementer MUST stop the affected scope and post a blocker.

The Implementer MUST NOT guess a missing requirement.

---

## 7. Instruction Precedence

Use this order when project instructions conflict:

1. explicit Product Owner decision on GitHub for the current Item;
2. approved Issue, ADR, or specification for the current Item;
3. `/docs/RUN_BATCH_HANDOFF_SPEC.md` for batch-runner behavior;
4. this `AGENTS.md` for collaboration and authority;
5. role-specific helper files such as `CLAUDE.md` or `CODEX.md`;
6. local AI-session assumptions.

A lower-level instruction MUST NOT override a higher-level authority.

---

## 8. `main` and Admission Rule

Before new work, an Agent MUST refresh GitHub state:

```bash
git fetch origin --prune
git switch main
git pull --ff-only origin main
git rev-parse HEAD
```

The Agent MUST record the exact base `main` SHA.

Before editing, the Agent MUST check local state:

```bash
git status --short
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
```

Unrelated local changes MUST NOT enter the assigned work.

Prefer a clean worktree or clean clone when unrelated local changes exist.

Do not delete unrelated work only to satisfy admission.

An Agent MUST NOT use another role's unmerged branch as a hidden dependency.

### Architect admission gate

Before the Architect changes a specification or produces an implementation contract, the Architect MUST:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git fetch origin --prune
git rev-parse origin/main
```

The Architect MUST use a clean workspace.

If unrelated local changes exist, the Architect MUST use a clean worktree or a clean clone.

The Architect MUST NOT overwrite or discard unknown local work.

The Architect MUST read:

- `AGENTS.md`;
- the active Tracking Issue;
- the target Issue;
- the relevant specification;
- the relevant ADR;
- the relevant handoff document;
- the current GitHub `main`.

### Implementer admission gate

The Implementer MUST NOT use an old handoff message as implementation authority.

Implementation admission requires:

- an approved bounded Issue;
- an exact authorized GitHub `main` SHA;
- an assigned Implementer;
- an authorized branch name;
- an exact write allowlist;
- acceptance tests;
- an active Tracking Issue frontier that explicitly authorizes implementation.

Before implementation, the Implementer MUST:

```bash
git fetch origin --prune
git switch <AUTHORIZED_BRANCH>
git rev-parse HEAD
git status --short
```

The Implementer MUST verify that the branch starts from the exact authorized base SHA.

The Implementer MUST use a clean workspace.

---

## 9. Issue Contract Rule

Production implementation MUST have a bounded GitHub Issue or equivalent approved GitHub contract.

The contract SHOULD contain:

- purpose;
- scope;
- non-goals;
- exact base `main` SHA;
- dependencies;
- assigned role;
- branch name;
- required behavior;
- prohibited behavior;
- public CLI/API contract;
- exact write allowlist;
- read-only paths;
- acceptance tests;
- compatibility requirements;
- failure behavior;
- required evidence;
- definition of done;
- authorization state.

For batch-runner work, the contract MUST reference `/docs/RUN_BATCH_HANDOFF_SPEC.md` when the existing specification applies.

A proposed specification change MUST identify the exact contract clauses that change.

The Issue MUST classify the work as an implementation-only change, a bug fix without a contract change, a performance change without a user-experience change, a behavior change, a specification change, or a documentation-only change.

The Implementer MUST NOT infer implementation authority from a vague Issue.

---

## 10. Implementation Authorization Gate

The Implementer MUST NOT begin production implementation until GitHub records readiness.

Readiness requires an approved bounded Issue and a current Tracking Issue frontier that explicitly authorizes implementation.

Recommended state:

```text
READY_FOR_IMPLEMENTATION_AT_<MAIN_SHA>
```

The assignment MUST identify:

- Item;
- exact `main` SHA;
- branch name;
- write allowlist;
- acceptance tests;
- dependencies;
- Implementer as next actor;
- authority exclusions.

If `main` changes after authorization and the new commit can affect the contract, the Architect MUST re-evaluate admission.

The Implementer MUST NOT silently rebase and assume semantic compatibility.

---

## 11. Branch and Commit Rule

Use one bounded branch per implementation Item unless an approved Issue defines another topology.

Recommended names:

```text
feat/<issue>-<short-name>
fix/<issue>-<short-name>
docs/<issue>-<short-name>
chore/<issue>-<short-name>
```

Commits MUST:

- use the assigned role's Git author;
- contain only authorized changes;
- avoid unrelated formatting churn;
- be pushed before another role relies on them.

A handoff MUST use an exact commit SHA.

A branch is movable.

A commit SHA is immutable evidence.

---

## 12. Pull Request Rule

The Implementer opens the implementation Pull Request.

The Pull Request MUST reference the implementation Issue.

The Pull Request SHOULD state:

```text
Base main SHA
Issue
Scope
Files changed
Behavioral contract changed: yes/no
CLI changed: yes/no
Restart semantics changed: yes/no
Concurrency semantics changed: yes/no
OpenFOAM commands changed: yes/no
Tests executed
Test results
Known limitations
```

The Pull Request head commit MUST be pushed before review is requested.

Opening a Pull Request changes the execution frontier.

---

## 13. Review Rule

The Architect / Reviewer performs an independent review.

The review MUST state:

```text
Reviewed commit: <EXACT_COMMIT_SHA>
```

The review MUST check:

1. Issue scope.
2. Applicable specification.
3. Exact write allowlist.
4. Acceptance tests.
5. Failure semantics.
6. Backward compatibility.
7. Unintended behavior changes.
8. GitHub Actions evidence.
9. Documentation impact.

Use one of these review states:

```text
CHANGES_REQUESTED_AT_<COMMIT_SHA>
APPROVED_COMMIT_<COMMIT_SHA>
BLOCKED_<REASON>
```

Approval applies only to the reviewed commit.

A new Implementer commit requires a new review decision for the new SHA.

---

## 14. Merge Rule

A Pull Request may merge only when:

- the approved contract is satisfied;
- the Architect approved the exact head commit;
- required GitHub Actions pass;
- blocking review findings are resolved;
- dependency gates are satisfied;
- required Owner approval exists;
- the active Tracking Issue frontier allows merge;
- the merge target is `main`.

After merge, the current GitHub `main` SHA becomes the new integrated state.

A merge changes the execution frontier.

---

## 15. Batch Runner Contract Guard

The batch-runner family is:

```text
run_batch.sh
setup_cases.sh
run_mesh_cases.sh
run_flow_cases.sh
run_transport_cases.sh
run_post_processing_cases.sh
```

`/docs/RUN_BATCH_HANDOFF_SPEC.md` is the normative technical contract for this family.

An unapproved refactor MUST NOT silently change:

- CLI syntax;
- stage order;
- independent stage execution;
- multi-CSV behavior;
- batch ID rules;
- workspace initialize/reuse rules;
- overwrite safety;
- master-first stage-script resolution;
- stage-specific concurrency;
- batch-level concurrency;
- MPI advisory behavior;
- `SCALAR_FIELD` propagation;
- `--save-times` forwarding;
- restart markers;
- fresh/continue semantics;
- transport continuation ordering;
- post-processing idempotency;
- failure propagation;
- summary/log artifacts.

A behavior or specification change requires Owner approval before implementation authorization.

---

## 16. Batch Runner Change Classification

Every Pull Request that changes the batch-runner family MUST use one classification:

```text
IMPLEMENTATION_ONLY
BUG_FIX_WITHOUT_CONTRACT_CHANGE
PERFORMANCE_CHANGE_WITHOUT_UX_CHANGE
BEHAVIOR_CHANGE
SPEC_CHANGE
DOCUMENTATION_ONLY
```

For `IMPLEMENTATION_ONLY`, `BUG_FIX_WITHOUT_CONTRACT_CHANGE`, or `PERFORMANCE_CHANGE_WITHOUT_UX_CHANGE`, the Pull Request MUST prove that the existing `/docs/RUN_BATCH_HANDOFF_SPEC.md` contract remains valid.

`BEHAVIOR_CHANGE` and `SPEC_CHANGE` require prior Owner approval.

---

## 17. Batch Runner Minimum Review Evidence

For applicable changes, review the clean-room tests in `/docs/RUN_BATCH_HANDOFF_SPEC.md`.

The test set includes:

- Bash syntax;
- CLI help;
- multi-CSV dry-run;
- canonical stage ordering;
- overwrite safety;
- duplicate batch ID rejection;
- CSV mismatch protection;
- central/master stage-script precedence;
- exact `--save-times` forwarding;
- stage-specific jobs;
- `SCALAR_FIELD` propagation;
- mesh `wallDistance` behavior;
- transport fresh behavior;
- transport continuation behavior;
- post-processing idempotency;
- failure propagation.

If a Pull Request changes one of these contracts, the approved specification MUST change in the same authorized work.

---

## 18. Safe Parallel Work Rule

Parallel work is allowed only when the active Tracking Issue states that the work is safe in parallel.

A safe parallel Item MUST have:

- independent write set;
- satisfied dependencies;
- exact base SHA;
- no hidden local dependency;
- no conflicting authority;
- explicit Tracking Issue state.

Recommended state:

```text
SAFE_PARALLEL_AT_<MAIN_SHA>
```

Two Items that can modify the same file or shared behavioral contract are not safe in parallel unless the Architect defines an explicit coordination and merge order.

Different stage scripts are not automatically independent. A shared CLI, variable, restart rule, or specification can create a dependency.

---

## 19. Communication and Evidence Rule

Control-plane text MUST use ASD-STE100 style.

Use:

- short sentences;
- explicit nouns;
- exact GitHub object names;
- exact SHAs;
- exact Issue and Pull Request numbers;
- exact next actor.

Avoid ambiguous pronouns and implied authorization.

Evidence MUST be a GitHub object or committed repository content.

Preferred evidence:

- Issue;
- Issue comment;
- commit SHA;
- branch;
- Pull Request;
- Review;
- GitHub Actions run;
- merge record;
- merged `main` SHA;
- committed specification or test.

A local-only statement such as `tests passed locally` is not sufficient shared evidence by itself.

If no GitHub Action covers a local test, post the command and concise result to an allowed GitHub object.

---

## 20. Tracking Issue

Every active multi-Agent project MUST have one active Tracking Issue for the current execution frontier.

The Tracking Issue is the cross-Agent control plane.

The Tracking Issue answers:

- What is complete?
- What is blocked?
- Who acts next?
- What can run in parallel?
- What can the Product Owner do now?
- What evidence proves each state?

The Tracking Issue coordinates execution.

The Tracking Issue does not replace:

- an approved Issue contract;
- `/docs/RUN_BATCH_HANDOFF_SPEC.md`;
- an ADR;
- a commit;
- a Pull Request;
- a Review;
- GitHub Actions;
- GitHub `main`.

The project MUST have only one active Tracking Issue for the current execution frontier.

A superseded Tracking Issue MUST point to its successor.

---

## 21. Frontier Rule

When the execution frontier changes, append a new comment to the active Tracking Issue.

Do not edit an old frontier comment.

Old frontier comments are immutable historical records.

A frontier changes when, for example:

- implementation becomes authorized;
- a Pull Request is opened;
- review finds changes;
- review approves a commit;
- a Pull Request merges;
- a dependency becomes satisfied;
- a task becomes blocked;
- the next actor changes;
- safe parallel work changes;
- Owner input becomes required;
- a new `main` SHA changes admission state.

A local commit does not complete a handoff.

The acting Agent MUST push required state and append the frontier comment.

If an old frontier comment contains an error, append a correction. Do not rewrite history.

---

## 22. Required Frontier Comment Contents

Every new frontier comment MUST contain:

1. exact GitHub `main` SHA;
2. Current actor;
3. Next actor;
4. completed actions;
5. current tracking table;
6. safe parallel work;
7. authority exclusions;
8. evidence links;
9. Product Owner action now.

Actor terms have these exact meanings:

- `Current actor`: the author of the frontier-update comment.
- `Next actor`: the immediate recipient of the Current actor's handoff.
- `Next action`: the exact task that the Current actor assigns to the Next actor.

The tracking table MUST contain the exact task assigned to the next actor.

Use ASD-STE100 style.

Use short sentences.

Use explicit nouns.

Avoid ambiguous pronouns.

Use this template:

```markdown
## Frontier — <STATE_NAME>

Main SHA: `<EXACT_MAIN_SHA>`

Current actor: `<GITHUB_ACCOUNT_OR_ROLE>`

Next actor: `<GITHUB_ACCOUNT_OR_ROLE>`

### Completed actions

- <completed action>
- <completed action>

### Tracking table

| Item | State | Next actor | Next action | Evidence |
|---|---|---|---|---|
| <item> | <state> | <actor> | <exact action> | <GitHub evidence> |

### Safe parallel work

- <safe parallel item, or `None`>

### Authority exclusions

- <explicit exclusion>
- <explicit exclusion>

### Evidence

- <Issue / PR / commit / Review / Actions / merge link>

Product Owner action now: <exact action or `None`>
```

A frontier comment MUST NOT contain only `done`, `ready`, or `please continue`.

---

## 23. Tracking Table

Use exactly this structure:

| Item | State | Next actor | Next action | Evidence |
|---|---|---|---|---|

Each row represents one actionable work Item.

Example:

| Item | State | Next actor | Next action | Evidence |
|---|---|---|---|---|
| T36 CLI | `READY_FOR_IMPLEMENTATION_AT_c859228c` | `derek-implementer` | Implement Issue #36 from the approved contract | Issue #36 |
| T37 Validation | `BLOCKED_BY_T36` | `derek-architect` | Wait for T36 merge | Issue #37 |
| T38 Docs | `SAFE_PARALLEL_AT_c859228c` | `derek-implementer` | Update isolated documentation files | Issue #38 |

Do not add or remove columns.

Do not combine independent Items into one row.

`Next action` MUST be executable by `Next actor`.

`Evidence` MUST identify a GitHub object.

Recommended states:

```text
OWNER_INPUT_REQUIRED
ARCHITECT_REVIEW_REQUIRED
READY_FOR_IMPLEMENTATION_AT_<SHA>
IN_IMPLEMENTATION_AT_<SHA>
PR_OPEN_<PR_NUMBER>_AT_<SHA>
CHANGES_REQUESTED_AT_<COMMIT_SHA>
APPROVED_COMMIT_<COMMIT_SHA>
READY_TO_MERGE_<PR_NUMBER>_<COMMIT_SHA>
MERGED_AT_<MAIN_SHA>
BLOCKED_BY_<ITEM>
BLOCKED_BY_OWNER_INPUT
BLOCKED_BY_CI
SAFE_PARALLEL_AT_<SHA>
COMPLETE_AT_<MAIN_SHA>
```

A state MUST NOT claim more authority than the evidence proves.

---

## 24. Role Handoff Rules

### Architect -> Implementer

Before implementation assignment, the Architect MUST publish:

```text
Item
Assignment token
Exact main SHA
Branch name
CLI/API contract
Write allowlist
Read-only paths
Dependencies
Acceptance tests
Required evidence
Authority exclusions
```

Recommended token:

```text
<ITEM>_READY_FOR_IMPLEMENTATION_<SHORT_SHA>
```

The Architect then appends a frontier comment with the Implementer as next actor.

### Implementer -> Architect

When implementation is ready for review, the Implementer MUST:

1. commit authorized changes;
2. push the branch;
3. open or update the Pull Request;
4. identify the exact head commit SHA;
5. report tests;
6. report limitations or deviations;
7. append a frontier comment with the Architect as next actor.

### Architect Review -> Implementer or Owner

For blocking review:

```text
CHANGES_REQUESTED_AT_<EXACT_COMMIT_SHA>
```

Each blocking finding MUST state:

- violated requirement;
- affected file or behavior;
- evidence;
- required correction.

For approval:

```text
APPROVED_COMMIT_<EXACT_COMMIT_SHA>
```

The Architect then appends a frontier comment with the exact next actor.

### Post-Merge

After merge:

1. obtain the exact current GitHub `main` SHA;
2. verify required Actions;
3. mark the Item `MERGED_AT_<MAIN_SHA>`;
4. update dependency rows;
5. identify newly unblocked work;
6. identify safe parallel work;
7. identify next actor;
8. identify Product Owner action;
9. append a frontier comment.

---

## 25. Agent Startup Procedure

Every new AI coding session MUST start from GitHub state.

The Agent MUST:

1. identify the Agent role;
2. verify GitHub account;
3. verify Git commit author;
4. fetch `origin`;
5. read root `AGENTS.md`;
6. read the active Tracking Issue;
7. read the assigned Issue;
8. read applicable specifications;
9. identify exact GitHub `main` SHA;
10. identify the current frontier;
11. identify the exact next action;
12. verify a clean local workspace;
13. act only inside granted authority.

If GitHub does not assign work to the Agent, the Agent MUST NOT invent implementation work.

---

## 26. Agent End-of-Session Procedure

Before ending a session that changed shared state, the Agent MUST:

1. push required commits or branches;
2. make evidence visible on GitHub;
3. update the relevant Issue or Pull Request;
4. append a frontier comment if the frontier changed;
5. name the next actor;
6. state safe parallel work;
7. state authority exclusions;
8. provide evidence links.

The next actor MUST NOT depend on local-only context.

---

## 27. No Hidden Cross-Agent Dependency

Invalid handoff:

```text
Use the file on my workstation.
Use my uncommitted patch.
Continue from my AI session.
Read my local terminal output.
```

Valid handoff:

```text
Fetch origin.
Read Issue #123.
Review commit abc1234.
Check PR #45.
Use main SHA def5678.
Read the committed test evidence.
```

If required information is not on GitHub, the current actor MUST publish the information before handoff.

---

## 28. Conflict and Race Rule

Before a push, review decision, or merge action, refresh relevant GitHub state.

If `main`, the Issue contract, or the active frontier changed during local work:

1. stop the handoff;
2. compare current GitHub state with the authorized base;
3. determine whether the assignment remains valid;
4. request re-admission when authority is uncertain.

Do not hide stale-base risk with an automatic rebase.

A clean rebase does not prove semantic compatibility.

---

## 29. Definition of Done

A work Item is not complete because code exists locally.

A normal implementation Item is complete only when required GitHub evidence exists:

```text
approved contract
+ implementation authorization
+ pushed commit
+ Pull Request
+ independent review
+ required GitHub Actions
+ merge to main
+ post-merge frontier update
```

The merged GitHub `main` SHA is the final integrated evidence.

---

## 30. Core Rule

No Agent may use information that another Agent cannot obtain from GitHub as formal project state.

No Agent may claim authority that is not recorded on GitHub.

No Agent may silently change the approved batch-runner contract.

Every execution-frontier change must leave an append-only GitHub record.

GitHub `main` plus GitHub execution evidence is the final shared truth.

---

## Agent skills

### Issue tracker

Issues are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The repository uses the five default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain-doc layout. See `docs/agents/domain.md`.

### Authority boundary

Agent skills support engineering workflow.

Agent skills do not grant project authority.

A skill-generated label, Issue, specification, plan, or recommendation does not authorize implementation, approval, or merge.

The active Tracking Issue is the multi-Agent execution control plane.

Implementation authority requires:

1. an approved bounded Issue or implementation contract;
2. an exact authorized GitHub `main` SHA;
3. an assigned Implementer;
4. a current Tracking Issue frontier that explicitly authorizes implementation.

Triage labels describe workflow status only.

The `ready-for-agent` label does not grant implementation authority and does not mean `READY_FOR_IMPLEMENTATION_AT_<SHA>`.

If an Agent Skill instruction conflicts with `AGENTS.md`, `AGENTS.md` takes precedence.
