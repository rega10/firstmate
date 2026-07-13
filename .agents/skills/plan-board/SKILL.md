---
name: plan-board
description: >-
  Create, update, and show a visual living implementation-plan tracker for any project in the firstmate fleet.
  Use when the captain invokes /plan-board, asks to snapshot an agreed plan, records progress against plan steps, or wants to see the current plan board.
user-invocable: true
metadata:
  internal: true
---

# plan-board

Maintain one agreed implementation plan per project as a local firstmate record and render it as a polished visual board.
Perform the plan-file writes and rendering directly because `data/` and `.lavish/` are firstmate-writable operational state.
Never delegate this bookkeeping and never write the plan or its board into a project clone.

## Resolve the request

Resolve the project using AGENTS.md section 7 before reading or writing a plan.
Use the registered project slug consistently in every plan and artifact path.
Infer exactly one operation from the captain's natural-language invocation:

- Use **snapshot** when the captain asks to capture, replace, or establish the agreed implementation plan.
- Use **update** when the captain reports progress, completion, a blocker, or another outcome for one or more existing steps.
- Use **show** when the captain asks to view or refresh the plan, and use it as the default when no other operation is clear.

Run **show** after every successful **snapshot** or **update** so the visual board never trails the plan record.

## Snapshot an agreed plan

1. Identify the final implementation plan that the captain agreed to in the current conversation or in a referenced specification.
2. Ask the captain for the missing agreement when no final plan exists, because brainstorming and draft specifications are not permission to invent steps.
3. Preserve the agreed step order, scope, definitions, tasks, and named responsible parties without adding speculative work.
4. Create `data/plans/` when needed and write the current plan to `data/plans/<project>.md` using the canonical contract below.
5. Before replacing a materially different current plan, copy the old file unchanged to `data/plans/<project>-superseded-<YYYY-MM-DD>.md`.
6. Add `-2`, `-3`, and so on before `.md` when another plan was already superseded for that project on the same date.
7. Do not archive the current plan for a routine progress update or a wording correction that does not replace the agreed plan.
8. Record a precise source such as a specification path, a scout report, or the date and topic of the captain's agreement.

## Update progress

1. Read `data/plans/<project>.md` and match every requested change to its stable step ID.
2. Ask for clarification instead of guessing when the request could refer to more than one step.
3. Set each affected step's `status` to exactly `pending`, `in-progress`, `done`, or `blocked`.
4. Update task checkboxes only when the reported outcome establishes their state, and check every remaining task when the captain explicitly marks the whole step done.
5. Append one dated note of at most one short physical line under each affected step, summarizing what happened and retaining every earlier note unchanged.
6. Include compact evidence in the note when available, such as a PR number, test count, decision, or blocker.
7. Recalculate `overall-status` as `done` when every step is done, `blocked` when any step is blocked, `in-progress` when any step is in progress or done, and `pending` otherwise.
8. Preserve step IDs and order across updates, and change them only when snapshotting a newly agreed replacement plan.

## Show the visual board

1. Read the current plan file without changing its content.
2. If no current plan exists, report that no board can be shown and ask the captain to identify an agreed plan for a snapshot.
3. Load the `lavish` skill, then run `lavish-axi playbook plan` and `lavish-axi playbook table` before authoring or refreshing the HTML.
4. Follow the loaded Lavish design-selection and render-verification guidance.
5. Write the board to the stable path `.lavish/plan-board-<project>.html` so every refresh reuses the existing Lavish session.
6. Show the project, plan title, source, snapshot date, overall status, and completed-step count as `done steps / total steps` with an accessible progress indicator.
7. Show steps in plan order as a compact timeline or responsive card grid with visible status labels and distinct status colors.
8. Show each step's definition, task checkboxes, responsible chips when present, and latest note directly on its card.
9. Put the full notes history for each step in an expandable disclosure attached to that step.
10. Keep typical plans of 5 to 15 steps readable on one screen through compact spacing and responsive columns, while allowing longer plans to scroll naturally.
11. Prevent horizontal overflow at every nesting level and use text labels in addition to color for status meaning.
12. Open or refresh the board with `lavish-axi .lavish/plan-board-<project>.html` and follow the loaded Lavish skill for layout-warning handling.
13. Keep the board local unless the captain explicitly asks to export or share it.

## Canonical plan-file contract

Use the following realistic example as the complete format specification.
Keep header keys, step headings, field names, task checkbox syntax, and notes syntax unchanged.
Omit `responsible` when no actor or party is involved, and place it at step level, task level, or both only when the agreed plan names that responsibility.

```markdown
# Implementation plan

- project: `billing-api`
- plan-title: `Zero-downtime invoice ledger migration`
- snapshot-date: `2026-07-13`
- source: `docs/specs/invoice-ledger-v2.md, approved by the captain on 2026-07-13`
- overall-status: `in-progress`

## S1 - Establish migration safety rails

- definition: `Create the observability and rollback controls required before data movement starts.`
- status: `done`
- responsible: `Platform team`

### tasks

- [x] Add old-versus-new ledger comparison metrics.
- [x] Add a feature flag for dual writes.
- [x] Document and rehearse the rollback command.

### notes

- `2026-07-13`: Safety rails deployed in PR #41, and all 28 migration tests passed.

## S2 - Backfill historical invoices

- definition: `Copy existing invoice entries into the new ledger without interrupting writes.`
- status: `in-progress`

### tasks

- [x] Run the backfill against the staging snapshot.
  - responsible: `Data engineering`
- [ ] Run the production backfill in bounded batches.
  - responsible: `Release engineering`
- [ ] Reconcile counts and sampled balances.

### notes

- `2026-07-13`: Staging backfill reconciled 1.8 million entries with no balance drift.

## S3 - Cut reads over and retire compatibility code

- definition: `Move invoice reads to the new ledger and remove the temporary migration path after the observation window.`
- status: `pending`

### tasks

- [ ] Enable new-ledger reads for the canary cohort.
- [ ] Expand reads to all tenants after the 48-hour observation window.
- [ ] Remove dual-write and legacy-read compatibility code.

### notes

- `2026-07-13`: Waiting for S2 production reconciliation before the canary begins.
```
