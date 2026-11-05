# Architecture decision records — workstation database

Short ADRs for schema decisions. Each one has a stable id (`ADR-NNN`) that commits, `db/tools/lint-allow.json` and TRACEABILITY.md can cite. Statuses: **Proposed** (needs a human decision, not implemented), **Accepted**, **Superseded by ADR-NNN**.

The linter accepts an allowlist entry only if its ADR heading exists in this file.

---

## ADR template

```markdown
## ADR-NNN <title>

- **Status:** Proposed | Accepted | Superseded by ADR-NNN
- **Date:** YYYY-MM-DD · **Milestone:** M<n> · **Closes:** <finding IDs> · **Requirements:** <req / T / G IDs>

**Context.** What problem or constraint forces a decision. Cite the finding and requirement IDs.

**Decision.** What we do, stated precisely (objects, constraints, triggers, lint rules affected).

**Alternatives.** What else was considered, and why it was rejected.

**PostgreSQL portability.** How this maps to PostgreSQL if the Section 6 gate selects it
(equivalent feature, rewrite needed, or no equivalent).
```

---

## ADR-000 Schema modules + lint as gate

- **Status:** Accepted
- **Date:** 2026-11-05 · **Milestone:** M0 · **Closes:** none (harness) · **Requirements:** 97 (durability gate at build), supports all

**Context.** Draft v2 (`db/reference/fire_workstation_schema_draft_v2.sql`) is one 782-line file with no build, test or lint tooling. SCHEMA_REVIEW.md lists more than 50 findings to close over M1–M12. Each of those changes has to be reviewable, start from a fresh build, and come with proof that nothing else changed. CLAUDE.md conventions 1–15 have to be enforced by a machine, not by memory.

**Decision.**

1. **Modules are the source of truth.** The v3 schema is the ordered list `db/schema/NN_<area>.sql`, followed by `db/seed/NN_<area>.sql`. In M0 the modules are a verbatim split of Draft v2. Each module adds only a one-line banner, and `trg_event_no_update` moves from §6 into `03_events_alarms` next to `event`. Draft v2 stays frozen as the diff reference.
2. **Equivalence proof.** `npm run db:equiv` (also run as a test) builds Draft v2 and the modules into separate databases. It compares the normalised `sqlite_schema` (comments stripped, whitespace collapsed, rootpage ignored) and the `table_list` / `table_xinfo` / `foreign_key_list` / `index_list` / `index_xinfo` pragmas of every table. In M0 they're identical: 48 tables, 27 indexes, 8 triggers (83 objects). From M1 on, `node db/tools/equiv.js --diff` lists the intended differences.
3. **One build path.** `db:build`, `db:lint`, `db:equiv` and the test helper `freshDb()` all use `db/tools/lib/schema.js`. Every build runs these steps in order:
   - assert SQLite ≥ 3.45;
   - start from an empty file;
   - run file-creation `PRAGMA`s from `00_header.sql` (one per line) before any DDL, and assert that nothing has been created yet;
   - run all modules and seeds in one `BEGIN IMMEDIATE` transaction with `foreign_keys=ON`;
   - require `foreign_key_check` to return nothing and `quick_check` to return `ok`.

   M0 defines no pragma values; M1 sets `page_size`, `auto_vacuum` and `application_id` (P2, P3).
4. **Lint as a ratchet.** `npm run db:lint` checks CLAUDE.md conventions 1–9 and 13 against a fresh build. It reads `sqlite_schema`, the pragmas, and the CREATE text (for ON DELETE, CHECK and AUTOINCREMENT). The rules are `strict`, `without-rowid`, `pk-id`, `autoincrement`, `fk-name`, `fk-on-delete`, `fk-index`, `time-type`, `time-positive`, `bool`, `bool-name`, `json`, `hash`, `uuid`, `enum-lookup` and `naming`. Every violation has a stable key `rule:object`. `db/tools/lint-allow.json` lists accepted violations, and each entry needs a `reason` and an `adr` that exists in this file. Lint **fails on any new violation and on any stale entry**, so the count can only go down. When a milestone fixes something, it deletes the matching entries in the same commit.
5. **Baseline.** Draft v2 has **280** violations, all allowlisted with `tag: "baseline"` and this ADR:

   | rule | count | closed by |
   |---|---|---|
   | fk-on-delete | 80 | D11 (M1) |
   | fk-index | 60 | P5 (M1–M12) |
   | time-positive | 57 | D10 (M1) |
   | naming | 19 | convention 13 (M1) |
   | fk-name | 18 | convention 2 (M1/M7) |
   | json | 15 | D9 (M1) |
   | enum-lookup | 9 | N1, G9 (M2) |
   | hash | 9 | D10 (M1); 2 standing exceptions |
   | bool-name | 7 | convention 6 (M1) |
   | autoincrement | 4 | P4 (M1/M5) |
   | without-rowid | 2 | standing exception |

6. **Standing exceptions recorded here.** These are expected to stay allowlisted:
   - `telemetry` and `gateway_telemetry` are WITHOUT ROWID (convention 1). They're high-volume raw readings with a natural composite key `(device_id|gateway_id, telemetry_key_id, ts)`, never FK-referenced, and always read by that key prefix. That's roughly half the size of `id` plus a UNIQUE index.
   - `user_account.password_hash` and `pin_hash` hold Argon2id PHC strings (req 65), not SHA-256 hex digests, so the hash rule doesn't apply. D7/M7 adds algorithm-parameter versioning.

**Alternatives.**
- *Keep a single file and diff it.* Rejected: every milestone would rewrite one large file, reviews would be noisy, and smoke tests couldn't map to areas.
- *Migrations from day one.* Rejected: before schema freeze, CLAUDE.md wants the modules to be the truth and migrations only after the freeze.
- *Fix the lint findings in M0.* Rejected: M0 makes no schema changes, and each fix belongs to the milestone that owns its finding.
- *Python `sqlite3` harness.* Not needed: Node 20+ with better-sqlite3 13.0.3 (SQLite 3.53.4) installs cleanly on the target. better-sqlite3 13 ships N-API prebuilds (`gypfile: false`), but `npm ci` still tries a node-gyp build from the lockfile, which needs Visual Studio. The repo's `.npmrc` therefore sets `ignore-scripts=true`. No dependency needs an install script, and this also blocks dependency install scripts (req 104).

**PostgreSQL portability.** The module and lint structure carries over unchanged. Lint would read `information_schema` / `pg_catalog` instead of SQLite pragmas. STRICT maps to native typing, WITHOUT ROWID maps to a composite PK (optionally clustered with BRIN or partitioning), and `json_valid` CHECKs map to `jsonb` columns.
