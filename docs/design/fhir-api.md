# FHIR read API

Status: **phases 1 and 2 done** (2026-09-30). Product direction item 7.

## Decisions (user, 2026-09-30)

- Readers: **our own tools and integrations**, **external medical
  systems**, and **people reading their own data** (patient access).
- Resources (FHIR **R5**, read-only): Patient, Practitioner,
  Organization; Encounter, Observation, Condition, AllergyIntolerance;
  MedicationStatement, MedicationAdministration, Procedure;
  ServiceRequest, Composition, DocumentReference.
- Qualified signatures: later.

## Phases

1. **Service accounts and own-data access** (this step). An admin creates
   an API client with access profiles; it gets a token shown once (only
   its SHA-256 is stored). A person creates a **personal token** that
   reads only their own record. Requests carry `Authorization: Bearer`.
2. **External medical systems**: SMART on FHIR backend services (OAuth2
   client credentials with a signed JWT), one client per care provider
   from the register, and reads limited to patients referred to that
   provider, under a data-sharing agreement. SMART patient launch for
   apps may follow.

## Rules

- A service client is an actor like a user: role viewer plus its
  profiles, read through the same policies, so it sees exactly what those
  profiles allow. Global profiles only (a client belongs to no unit); a
  new profile `health_data_reader` gives read access to clinical data for
  integrations.
- A personal token reads only the owner's person, all categories, and
  nothing else.
- Every read of a sensitive record is written to the access log with the
  client as the actor (`api:<name>`), like any user read.
- Resources are built from our data (`App.Fhir.*`) and tested against the
  official R5 JSON Schema (`priv/fhir/R5/fhir.schema.json`).
- `GET /fhir/R5/metadata` (CapabilityStatement) is public; everything else
  needs a token. Search: `Patient?identifier=|name=`, clinical resources
  by `?patient=`; results are `searchset` Bundles.

## Implementation, phase 1 (2026-09-30)

- `App.Api.Client` (`:service`, `:personal`), tokens `hrda_…` shown once,
  SHA-256 stored; `App.Api.actor_for_token/1`; page `/api-access` (account
  menu): own tokens, and service clients for admins. Profile
  `health_data_reader` (global) for clinical integrations.
- `App.Fhir` (reads, personal scope), `App.Fhir.Map` (pure mapping,
  validated in tests against the official R5 schema), routes under
  `/fhir/R5` (`AppWeb.FhirController`, `AppWeb.Plugs.FhirAuth`):
  `metadata`, read, search, `Binary/:id` (signed PDF by a short-lived link).
- Local clinical times get the offset of `APP_TIME_ZONE` (default
  Europe/Kyiv; `tz` library).

## Implementation, phase 2 (2026-09-30)

- External systems: `App.Api.Client` kind `:external` — a care provider
  from the register (not our own unit) with a data-sharing agreement on
  file and not ended (`agreement_ref`, `agreement_until`), its public keys
  (JWK Set: RSA or EC, no private part) and the resource types allowed
  (Practitioner never). Registered on `/api-access` by admins; the system
  gets its `client_id` and the token endpoint, no secret.
- Token endpoint `POST /fhir/auth/token` (`App.Api.Smart`): client
  credentials with a signed client assertion (RS384/ES384; `iss` = `sub`
  = client id, `aud` = the token endpoint, `exp` ≤ 5 min, `jti` once —
  kept in `api_used_jtis`); answers a 5-minute access token (`hrda_at_…`,
  SHA-256 stored in `api_access_tokens`) for the requested types it may
  have. Discovery: `/fhir/R5/.well-known/smart-configuration`; the token
  URL is also in the CapabilityStatement (oauth-uris).
- What it reads: patients with a signed referral to its provider
  (`Document.recipient_provider_id`, plain, filled from the fields and
  backfilled after migrations), documents addressed to its provider, the
  clinical resources of those patients; Patient without national IDs.
  A lapsed agreement stops both new and current tokens.
- Tested: EC and RSA keys; replay, foreign key, wrong audience, expired
  and too-long assertions, `alg: none` and HMAC-with-the-public-key are
  refused; verified end to end on the local copy of staging.
- Not yet: fetching keys from a `jwks_uri` (keys are pasted); patient
  consent beyond the referral; SMART app launch for patients' apps.
