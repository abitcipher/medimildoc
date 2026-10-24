# Global search, person timeline, notifications

Status: **done** (2026-09-30); channels wait for their sender credentials. Product direction item 6.

## Decisions (user, 2026-09-30)

- **Search** (header) finds people by name, Person ID and e-mail;
  documents by number; units, posts and care providers; and a person by
  a **national ID or identity-document number** (exact match).
- **Timeline**: everything the viewer may see about the person.
- **Notifications** only for events the user **subscribed** to, plus a
  **registration confirmation**. Delivery through a **self-hosted
  aggregator: Apprise API**, with routing and queuing through
  **RabbitMQ**; our app is the single control point. First channels:
  **e-mail (SMTP), Telegram, Signal / Matrix**.

## Search

- `App.Search.run(actor, text)`: each group is read **as the actor**
  (policies decide), so a result never reveals what the viewer may not
  read. Names: every word of the query must match a name part.
- National IDs and document numbers are encrypted, so the database can't
  compare them. A **keyed hash** (HMAC-SHA256, key derived from the
  current `CLOAK_KEY`) of the normalized value is stored beside each
  (`value_digest`, `number_digest`); the search hashes the query the
  same way. Only for actors who may read identifiers
  (`people.private.read`); **each match is written to the access log**
  (`search:identifier`). Re-encryption after a key rotation recomputes
  the hashes.

## Timeline

One chronological list per person on the person page, built from:
assignments (start, end, the order), signed documents, person records
by their date (leave, rank, fitness, family, clinical…), files. Every
source is read as the viewer, so hidden categories simply don't appear.

## Notifications

```
event (document waits, returned, signed, incident, registration)
  → App.Notify: who subscribed (Subscription: user, event, channel)
  → Notification rows (outbox, Postgres, same transaction)
  → publisher → RabbitMQ exchange "notify" (routing key = channel)
  → dispatcher (consumer) → Apprise API (per-channel URL)
  → delivered / failed (retries with backoff, then dead-letter)
```

- Messages never carry personal or medical details: what happened and a
  link.
- Each user manages their channels (e-mail address, Telegram chat,
  Signal number, Matrix room) and subscriptions on their account page.
- The registration confirmation goes to the new user's sign-in e-mail.
- Channels need credentials (SMTP account, Telegram bot, Signal relay,
  Matrix account); until they are set, messages stay in the outbox and
  appear in the app.

## Implementation (2026-09-30)

- `App.Search` (+ `App.Search.Digest`, `SetDigest` on identifiers,
  backfill after migrations), page `/search`, magnifier in the header.
- `App.Timeline` (+ `App.People.RecordDates`: `effective_on` from the
  record's data on save, backfill after migrations), tab "Timeline" on
  the person page.
- `App.Notify` (Channel, Subscription, Notification = outbox; events from
  document actions, incidents and first sign-in), `App.Notify.Outbox`
  (publisher, 5 s), `App.Notify.Dispatcher` (Broadway, RabbitMQ),
  `App.Notify.Delivery` + `App.Notify.Apprise`; retries after 1, 5, 30
  min, 2 h, 12 h. Page `/notifications` (account menu). Workers start
  only with `RABBITMQ_URL` and never in release tasks.
- Verified end to end on the local copy of staging: outbox → RabbitMQ →
  dispatcher → Apprise → a test receiver (`json://`), status `sent`.
- Messages are in English; the app shows their titles translated.
