# Parallel approval

Status: **done** (2026-10-07). On the route core of
`docs/design/documents-core.md`; the user's batch A3 (then C11 drug
interactions, B6 duty rosters).

## Decisions

- A route entry may take **several assignees** (`"multiple": true`) and
  have them decide **in parallel** (`"parallel": true`, approvals only):
  all of them are pending at once, each decides their own step in any
  order, and the next stage starts only when all have approved. One
  return sends the document back and cancels the rest of the round.
- An entry may be **optional** (`"optional": true`, never the signature):
  the author may leave it empty and the stage is skipped.
- First uses: the **medical board**'s members approve in parallel (before:
  one after another); **outgoing letters** start with optional
  **co-approvers** (anyone with `people.read`, in parallel). Personnel
  orders keep their routes for now.

## Model

- `Step.stage` (the route entry, 1-based) and `Step.parallel`; steps of
  earlier documents got `stage = position` (one by one, as they ran).
- `App.Documents.Route.next_active/1` (pure): what becomes pending —
  nothing while a step of the round is pending; else the first waiting
  step, with all of its stage when parallel. Used when sending
  (`CreateSteps`) and after each decision (`DecideStep`).
- `Queries.step_for/2`: the actor's own pending step, or one they may
  decide as a deputy. `CurrentAssignee`, `DecideStep` and the document
  page use it (several steps can be pending).
- Notifications: a decision tells only those whose steps it started
  (`DecideStep` → changeset context → `DocumentEvents`), so nobody in a
  parallel stage is notified twice.
- Deputy candidates count required stages only (an open co-approval needs
  no deputy).
- The send form marks parallel ("together, in any order") and optional
  stages; the route shows ∥ for parallel steps.
