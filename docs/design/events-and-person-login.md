# EVENTS and PERSON-LOGIN — event log, publishing, PersonID sign-in

Requested 2026-10-09 (user): a list of users and their roles; signing in
with PersonID and a password, confirmed through a message on first use;
access events logged separately; an event log that can later become its
own high-load service (through a message queue), which an administrator
may switch off — the switch itself always recorded; publishing key and
critical events as JSON packets to external subscribers, with names that
show the event's type and origin.

Decisions (user, 2026-10-09):

- **Who may sign in with a PersonID:** any person whose contact record has
  an e-mail address. A person without an account gets one on the first
  request, with the new base role `person` — their own data only. An
  administrator grants more as for any account. The setting
  `auth.person_login` switches the whole method off.
- **What a password session may do:** everything the account's role
  allows (the same session as after Google sign-in).
- **What "event logging off" stops:** the general event log and
  publishing. The data-access log (`App.Audit.AccessLog`: who read medical,
  vetting, clearance data, national IDs) is not affected: a sensitive
  value is shown only after its read is logged.

## 1. Event names

`hrda.<domain>.<subject>.<action>` — always four lower-case segments,
`snake_case` inside a segment:

| segment | meaning | examples |
|---|---|---|
| `hrda` | the system that emits it | — |
| domain | the part of the system it comes from | `auth`, `accounts`, `events`, `privacy`, `documents`, `people` |
| subject | what it is about | `session`, `sign_in`, `password`, `user`, `logging`, `export` |
| action | what happened — past tense, the outcome included | `started`, `failed`, `set`, `created`, `enabled`, `downloaded` |

So `hrda.auth.sign_in.failed`, never `login_error` or `auth.failed_login`.
A subscriber binds to a prefix: `hrda.auth.#` is everything about access,
`hrda.*.*.failed` every failure. A new event is declared first in
`priv/events.json` (type, severity, published or not, the fields of its
data, a description) — emitting an undeclared type raises, as with
permissions.

Severity: `info` (routine), `notice` (key events), `warning` (something
went wrong, e.g. a failed sign-in), `critical` (security-relevant, e.g. an
account locked, the event log switched off). Key and critical events are
the ones marked `"publish": true`.

## 2. The packet (CloudEvents 1.0, JSON)

Every event is one [CloudEvents 1.0](https://cloudevents.io) structured
JSON object — the open standard for this, so subscribers can use existing
tools:

```json
{
  "specversion": "1.0",
  "id": "0199d0c2-…",                       // UUIDv7, also the AMQP message id
  "type": "hrda.auth.sign_in.failed",
  "source": "/hrda/staging/auth",           // /hrda/<instance>/<domain>
  "subject": "user/0199…",                  // <kind>/<id>, when it is about one thing
  "time": "2026-10-09T12:00:00.123Z",
  "datacontenttype": "application/json",
  "dataschema": "urn:hrda:event:hrda.auth.sign_in.failed:1",
  "severity": "warning",                    // extension attributes
  "actorid": "0199…",                       // the user who did it, if any
  "data": { "method": "person_id", "reason": "bad_password", "ip": "203.0.113.5" }
}
```

`type` and `source` say what and where from without reading `data`. Data
holds ids, codes and outcomes — never names, PersonIDs, contact details
or record contents. An attempted PersonID is kept as its HMAC digest
(`App.Search.Digest`), so repeated attempts on the same ID can be seen
without storing it. The IP address is kept for access events (security).

## 3. The event log (EVENTS.1)

- `App.Events.emit/3` is the only way in. Behind it, a sink: today
  `App.Events.Event` rows in Postgres (append-only; no update except being
  marked published, no destroy). Later the sink can publish straight to
  the queue for a separate event-log service — callers and the packet
  stay as they are. Reading for the page goes through `App.Events.Query`,
  the other seam.
- Settings: `events.logging` (default on) and `events.publishing`
  (default off). With logging off nothing is written except the
  `hrda.events.*` events — switching logging or publishing on or off is
  always written, with who did it. Publishing needs logging (the log is
  the outbox).
- Page `/events` (permission `audit.read`): the access events (`auth.*`,
  `accounts.*`) as their own tab, all events on another, filters by type
  prefix and severity, the packet of each. The switches (needs
  `settings.manage`) are on the same page.

## 4. Publishing (EVENTS.2)

`App.Events.Publisher` (only with `RABBITMQ_URL`, like the notifications
outbox): every few seconds publishes unpublished events marked for
publishing to the topic exchange `hrda.events` (durable), routing key =
the event type, content type `application/cloudevents+json`, persistent,
message id = event id; then marks them published. While RabbitMQ is down
nothing is lost. A subscriber declares its own queue and binds it, e.g.
`hrda.auth.#`.

## 5. Users and roles (USERS)

`/users` (admin): users with role, profiles, linked person, sign-in
methods (Google, PersonID) and last sign-in; a "Roles" view with each
base role and access profile, what it allows and who has it.

## 6. PersonID sign-in (PERSON-LOGIN.1)

- `User.login_id` (= the linked person's PersonID, unique) and
  `hashed_password` (bcrypt); AshAuthentication's password strategy with
  `login_id` as identity, no self-registration, reset tokens for setting
  the password. New base role `person` (no permissions; own data only).
- First sign-in: `/sign-in/person` → "Set or reset password" → PersonID →
  always the same answer ("if this PersonID can sign in, a message was
  sent to its contact address") so PersonIDs can't be probed. If the
  person has an e-mail in a contact record: their account (created if
  missing: role `person`, linked) gets a single-use link valid for 30
  minutes by e-mail. The link opens "Set password" (at least 12
  characters, twice) and signs the person in.
- Sign-in: PersonID + password. Five failures for one PersonID in 15
  minutes lock it for 15 minutes; 30 from one address lock that address.
- Events: `auth.first_sign_in.requested`, `auth.password.set`,
  `auth.session.started`/`ended`, `auth.sign_in.failed`/`locked`,
  `accounts.user.created`.

## 7. My data (PERSON-LOGIN.2)

`/me` for anyone whose account is linked to a person: their person,
assignments, records (every category, as the personal FHIR token) and
own documents. Downloads — PDF, Markdown, JSON — need a fresh
confirmation: the password (or, for accounts without one, a Google
sign-in within the last five minutes). Each download is an event
(`privacy.export.downloaded`), and reading sensitive records writes the
data-access log as everywhere.

## Done (2026-10-09)

EVENTS.1–3, USERS, PERSON-LOGIN.1–2 as above. Notes from building it:

- **Where things are:** `App.EventLog` (emit, switches), `App.Events.*`
  (catalog, event, envelope, publisher), `AppWeb.EventsLive.Index`;
  `App.Accounts.PersonLogin`, `SetPasswordSender`, `Throttle`,
  `AppWeb.SignInLive`, `AppWeb.AuthController`; `AppWeb.MyData`,
  `AppWeb.MyDataLive`, `AppWeb.MyDataController`.
- **Subscribing:** declare a durable queue, bind it to the topic exchange
  `hrda.events` with a pattern (`hrda.auth.#`, `hrda.*.*.failed`, `#`).
  Each message: body = the CloudEvents JSON, `content_type`
  `application/cloudevents+json`, `message_id` = event id (deduplicate on
  it: a message may come twice if the app stops between publishing and
  marking).
- **The e-mail of a PersonID sign-in** is the newest e-mail in the
  person's contact records, else the person's own e-mail field. The link
  is sent only with `RABBITMQ_URL` and an e-mail sender
  (`NOTIFY_EMAIL_URL`); without them it waits in the outbox.
- **Lockout counters are in memory** (one application server); a restart
  forgets them.
- **Moving the log out:** replace the sink in `App.EventLog.write/4` (e.g.
  publish straight to the queue) and the reads of `/events` with the
  service's API; the packet and the catalog stay.
- **Not yet:** retention of old events; passwords for staff accounts
  require the person link (login is the PersonID).
