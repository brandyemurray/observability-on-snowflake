# ADR 0002: Remove guest PII in the Collector, with a masking policy as a second layer

**Status:** Accepted

## Context
Payments handles guest emails and card numbers. Developers log them by accident; span attributes capture them by design. Once PII reaches a backend, it is copied into indexes, backups and exports that are hard to clean.

## Decision
- The Collector's `transform/redact` processor runs on traces and logs before any exporter:
  - `guest.email` is replaced with a SHA-256 hash, so unique guests can still be counted.
  - `payment.card_number` keeps only the last four digits.
  - Emails and card-like digit runs inside log text are replaced.
- In Snowflake, a masking policy on log text hides email, phone and long-number patterns from roles below `OBS_SRE`, as defense in depth.

## Consequences
- Verified: 0 emails and 0 card numbers in 6,217 log records after a full run (query 3 in `06_check.sql`).
- New kinds of PII need a new Collector rule; the masking policy limits the blast radius until then.
- Hashing is not anonymization: the hash is still a stable identifier and is treated as sensitive.
