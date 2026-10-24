# Access control — phase 2 design

Status: **implemented** (2026-09-27; commits `79ce4de`, `3608ae1`, `fc27544`, `a266e80`, `1d4f120`). Builds on
`access-control-phase1.md`; the user asked to continue without a separate
approval round, so decisions are recorded here and can be revisited.

## 1. Linking accounts to people

- `App.Accounts.User.person_id` (nullable, unique): the Person this
  account belongs to. Set explicitly by someone with `users.manage` in the
  Users access panel (explicit over implicit). A Person with
  the same email as the account is offered as a one-click suggestion, never
  linked automatically.
- The person page shows which account, if any, belongs to the person.
- Needed by everything below: a user's unit comes from their person's
  current assignment, their clearance from their person's records.

## 2. Unit scoping

Each access profile declares a `scope` in `priv/access_profiles.json`:

| Scope | Profiles | Meaning |
|---|---|---|
| `global` | registrar, security_officer, ciso | everyone |
| `unit` | line_commander, clinician, command_surgeon | people whose current assignment is in the user's unit or any unit below it |

A user's unit is the organization of their linked person's current
position. Base roles are global.

A permission granted by any global source is global. One granted only by
unit-scoped profiles applies only inside the unit. Enforced in the
`PersonRecord`, `PersonIdentifier` and `IdentityDocument` read filters, so
out-of-unit rows are never returned. A unit-scoped user with no linked
person or no current assignment has an empty unit: fail closed.

People, organizations and positions stay readable app-wide
(`people.read`): the roster is not sensitive; the records are.

## 3. Clearance check

A record's `classification` must not exceed the reader's clearance: the
`clearanceLevel` of the latest `security_clearance` record of the reader's
linked person, if `status` is `granted` and it has not expired. Order:
`NATO_RESTRICTED` < `NATO_CONFIDENTIAL` < `NATO_SECRET` <
`COSMIC_TOP_SECRET`. Unclassified records (`classification` nil) need no
clearance. Enforced in the `PersonRecord` read filter, on top of
permissions and scope.

## 4. Break the Glass

- New permission `btg.invoke`, given to clinician and command surgeon.
- On a person page, a user with `btg.invoke` who cannot currently see that
  person's clinical data (out of unit) can request emergency access,
  giving a reason (required).
- Access: that person's allergy records only, for 60 minutes, regardless
  of unit scope. Stored as `App.Audit.EmergencyAccess` (actor, person,
  reason, expires_at, reviewed_by, reviewed_at).
- Every read during it is in the access log with the reason. The CISO sees
  emergency accesses on `/access-log` and marks each one reviewed.

## 5. Second approval for sensitive profiles

- Granting clinician, command_surgeon, security_officer or ciso creates a
  pending request; a different user with `users.manage` approves or
  rejects it. Removing a profile needs no approval.
- Behind `REQUIRE_SECOND_APPROVAL` (default off): during development there
  is a single admin. Turning it on is a go-live checklist item.

## 6. Development override

`ADMIN_FULL_DATA_ACCESS` keeps giving `:admin` everything:
unit scope and clearance checks don't apply to admin while it is on.

## 7. Order of work

1. Account ↔ person link (+ UI).
2. Unit scoping.
3. Clearance check.
4. Break the Glass.
5. Second approval.
6. Role start pages (UI plan item 8).
