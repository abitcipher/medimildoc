# FHIR R5 — vendored reference schema

`fhir.schema.json` — the official combined JSON Schema for HL7 FHIR
**R5** (all 857 resource + datatype definitions in one file, JSON Schema
draft-06). Source: https://hl7.org/fhir/R5/downloads.html ("JSON
Schema" download).

This is reference material, not something the app parses at runtime
(yet) — see for how/when it gets used to build out
`App.People.PersonRecord` kinds, Ash resources, and UI for the personnel
system (HL7 FHIR).

Note: our own hand-authored schemas (`priv/form_schemas/`,
`priv/person_record_schemas/`) declare `$schema: draft-07`; this file is
draft-06 — not yet confirmed whether `ex_json_schema` (existing dep)
needs anything special for that difference. Check before validating
against it programmatically.

Deliberately NOT vendored here: FHIR's XML
artifacts (`.xsd`/`.sch` — our stack is JSON-only end to end) and the
~2900 example resource instances (`examples-json/`/`examples-ndjson/`
from the same HL7 download) — those are re-fetchable from the URL above
on demand, and mostly irrelevant to personnel tracking specifically.
