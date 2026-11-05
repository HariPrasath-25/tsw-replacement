# CLAUDE.md — Omniconn TSW Replacement · Workstation database

This repository holds the SQLite schema for the Omniconn Fire Alarm Workstation monitoring service. Read this file fully before every task.

## What this database is

- It is the local store for the background Windows monitoring service on the MS-01. **The service is the single writer.** The desktop UI never opens the file; it talks to the service over authenticated IPC.
- It holds the alarm log (append-only), the audit log (append-only, hash-chained, never deleted), the device register, floor plans, commands, users/RBAC, telemetry, retention, backup, update, licence and Gateway Management records.
- It's a life-safety system. Losing a committed event, showing stale data as current, or executing a command twice are **Critical** defects.

## Source documents (read-only, never edit)

| File | Use |
|---|---|
| `docs/reference/architecture_roadmap_v1.2.md` | Requirements 1–123, targets T1–T18, Gateway Management G01–G12. Cite IDs as `req 51`, `T7`, `G05`. |
| `db/reference/fire_workstation_schema_draft_v2.sql` | Frozen Draft v2 baseline. Never modify it; it's the diff reference. |
| `docs/db/SCHEMA_REVIEW.md` | Review findings with IDs (G1…, D1…, N1…, P1…). Every change cites the finding ID it closes. |
| `docs/db/MILESTONES.md` | The milestone plan. Do only the milestone you were asked for. |

## Repository layout (target)

```
db/
  reference/                 frozen Draft v2 (read-only)
  schema/NN_<area>.sql       ordered DDL modules = the v3 schema (source of truth)
  seed/NN_<area>.sql         reference data (alarm classes, permissions, lookups)
  migrations/                forward-only migrations, used only after schema freeze
  tools/                     build, lint, test and benchmark scripts
  tests/                     constraint, trigger, query-plan and durability tests
docs/db/
  SCHEMA_REVIEW.md  MILESTONES.md  DECISIONS.md (ADRs)
  TRACEABILITY.md (requirement -> table/column/constraint/test)
  DATA_DICTIONARY.md  ERD.md (Mermaid)  CONNECTION_PROFILE.md
```

## Toolchain

- Runtime target: SQLite **≥ 3.45**, as bundled by `better-sqlite3` (STRICT, JSONB, `RETURNING`, `UPSERT`, generated columns, FTS5).
- Tests: Node 20+ with `node:test` and `better-sqlite3`. Commands are defined in M0 and must be kept in `package.json`:
  - `npm run db:build` builds a fresh `build/workstation.db` from `db/schema` + `db/seed`.
  - `npm run db:lint` runs the schema linter (rules below).
  - `npm test` runs all DB tests.
  - `npm run db:bench` runs the ingest/query benchmarks (M12).
- Never test against a hand-edited DB. Always rebuild from scripts.

## Schema conventions (enforced by `db:lint`)

1. **Every table is `STRICT`.** `WITHOUT ROWID` only for high-volume tables with a natural composite key that are never referenced by FK. Record each case in DECISIONS.md.
2. **Keys:** `id INTEGER PRIMARY KEY`. Use `AUTOINCREMENT` on tables whose ids leave the database (archives, exports, central sync): `event`, `alarm`, `command`, `audit_log` and similar. Natural keys get `UNIQUE`. FK columns are named `<table>_id`.
3. **Foreign keys** always declare `ON DELETE`. Use `RESTRICT` for history and log references, `CASCADE` only for pure child rows with no meaning alone, and `SET NULL` only where the column is optional by design. Master data (tenant, site, space, gateway, controller, device, user) is soft-deleted (`status` / `archived_at`), never hard-deleted.
4. **Every FK column has an index**, either its own or as the leading column of another index. Exceptions are listed in DECISIONS.md with the reason.
5. **Times** are `INTEGER` UTC milliseconds, `CHECK (col > 0)`. Use `src_time` for source/controller time and `rcv_time` for service receipt time. Never store local time.
6. **Booleans** are `INTEGER NOT NULL CHECK (col IN (0,1))` and named `is_*` / `has_*` / `can_*`.
7. **JSON** columns are named `*_json`, are TEXT with `CHECK (json_valid(col))`, and have a `json_type` check when the shape is fixed. JSON is for vendor or opaque data only. Anything filtered, joined or constrained gets a real column.
8. **Hashes:** `sha256` is TEXT, `CHECK (length(col)=64 AND col NOT GLOB '*[^0-9a-f]*')`. UUIDs are TEXT, lowercase, 36 characters, with a CHECK.
9. **Enumerations:** a closed state machine uses an inline `CHECK (col IN (...))`. An extensible domain (system, vendor, protocol, alarm class, condition, permission, device type) uses a lookup table with a FK.
10. **Mutable config tables** carry `created_at`, `updated_at`, `updated_by` and `row_version INTEGER NOT NULL DEFAULT 1`. Updates use optimistic concurrency (`WHERE id=? AND row_version=?`).
11. **Append-only tables** (`event`, `audit_log`, `device_state_history`, notes, grants consumed…) block UPDATE with a trigger. DELETE is allowed only through the retention gate (M11). `audit_log` blocks DELETE unconditionally.
12. **Cross-row and cross-table rules** that CHECK can't express (same-site hierarchy, state transitions, last admin) are enforced by `BEFORE` triggers with `RAISE(ABORT, '<table>: <rule>')`. Each trigger has a negative test.
13. **Naming:** tables are singular snake_case. Indexes are `ix_<table>_<cols>`, unique indexes `ux_…`, triggers `trg_<table>_<rule>`, views `v_…`.
14. Every table and every non-obvious column gets a one-line comment stating purpose and the requirement IDs it serves.
15. No secrets in plain text. Credentials and keys are DPAPI-encrypted `BLOB` columns named `*_enc`. Secret-bearing columns are listed in DATA_DICTIONARY.md so support bundles and exports can redact them (req 75, 98, 102).

## ACID and durability rules (req 97)

- Connection profile, set and **asserted** at open: `journal_mode=WAL`, `synchronous=FULL`, `foreign_keys=ON`, `trusted_schema=OFF`, `busy_timeout=5000`, DEFENSIVE on. Reader connections add `query_only=ON`. Full details live in `docs/db/CONNECTION_PROFILE.md`.
- File-creation-only settings must be applied before the first CREATE TABLE: `page_size`, `auto_vacuum=INCREMENTAL`, `application_id`.
- Writes use `BEGIN IMMEDIATE`. An event is acknowledged to the source or shown as recorded **only after COMMIT returns**.
- Ingest is idempotent: `INSERT … ON CONFLICT DO NOTHING RETURNING id`. Duplicates are harmless.
- Schema changes are transactional: one migration = one transaction, then `PRAGMA foreign_key_check` and `quick_check` must return nothing or OK, then bump `user_version`.

## Alarm-path protection (req 99, T1, T7, T8)

- Keep indexes on `event` and other hot ingest tables minimal. Every new index on a hot table needs a benchmark result in the PR or commit message.
- Reporting and statistics read from views or roll-ups and must not hold write locks.
- Hot query paths are checked with `EXPLAIN QUERY PLAN` tests: no `SCAN` of `event`, `alarm`, `device` or `audit_log`.

## Working rules for Claude Code

1. Start every milestone in **plan mode**. List the files you'll touch, the finding IDs you'll close, and any decision you need from a human. **Stop and ask** before:
   - changing alarm precedence, retention floors or audit immutability
   - removing a table or column from Draft v2
   - anything the architecture marks as an open design decision
2. Work on one milestone at a time, in small commits. A milestone is done only when `db:build`, `db:lint` and `npm test` all pass.
3. Every change updates TRACEABILITY.md (requirement → object → test) and DATA_DICTIONARY.md. Decisions go in DECISIONS.md as short ADRs: context, decision, alternatives, PostgreSQL portability note.
4. Don't invent requirements. If the architecture is silent, propose the change in DECISIONS.md as "Proposed", don't implement it, and ask.
5. Don't build service logic or UI. This repo is schema, seed data, tests and documentation only.
6. End each milestone with a summary covering findings closed, tests added, benchmark numbers where relevant, open questions, and the next milestone.

## Commit format

`db(M<n>): <summary>` with a body that lists the finding IDs and requirement IDs. Use one branch per milestone, `db/m<n>-<slug>`.
