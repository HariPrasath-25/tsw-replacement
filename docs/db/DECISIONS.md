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
   | fk-name | 18 | convention 2, kept strict (M1/M7; see item 7) |
   | json | 15 | D9 (M1) |
   | enum-lookup | 9 | N1, G9 (M2) |
   | hash | 9 | D10 (M1); 2 standing exceptions |
   | bool-name | 7 | convention 6 (M1) |
   | autoincrement | 4 | P4 (M1/M5) |
   | without-rowid | 2 | standing exception |

6. **Standing exceptions recorded here.** These are expected to stay allowlisted:
   - `telemetry` and `gateway_telemetry` are WITHOUT ROWID (convention 1). They're high-volume raw readings with a natural composite key `(device_id|gateway_id, telemetry_key_id, ts)`, never FK-referenced, and always read by that key prefix. That's roughly half the size of `id` plus a UNIQUE index.
   - `user_account.password_hash` and `pin_hash` hold Argon2id PHC strings (req 65), not SHA-256 hex digests, so the hash rule doesn't apply. D7/M7 adds algorithm-parameter versioning.
7. **Foreign-key naming stays strict** (decided 2026-11-05 by the schema owner). A foreign-key column is named `<table>_id` or `<role>_<table>_id`. There's no alias for `user_account` (`user_id`) and no `*_by` shorthand. The 18 baseline columns get renamed when their milestone touches the table, for example `user_id` → `user_account_id`, `acked_by` → `acked_by_user_account_id` and `space.parent_id` → `parent_space_id`. M1 does the cross-cutting `*_by` audit columns and M7 does the identity tables. The lint rule doesn't change.

**Alternatives.**
- *Keep a single file and diff it.* Rejected: every milestone would rewrite one large file, reviews would be noisy, and smoke tests couldn't map to areas.
- *Migrations from day one.* Rejected: before schema freeze, CLAUDE.md wants the modules to be the truth and migrations only after the freeze.
- *Fix the lint findings in M0.* Rejected: M0 makes no schema changes, and each fix belongs to the milestone that owns its finding.
- *Python `sqlite3` harness.* Not needed: Node 20+ with better-sqlite3 13.0.3 (SQLite 3.53.4) installs cleanly on the target. better-sqlite3 13 ships N-API prebuilds (`gypfile: false`), but `npm ci` still tries a node-gyp build from the lockfile, which needs Visual Studio. The repo's `.npmrc` therefore sets `ignore-scripts=true`. No dependency needs an install script, and this also blocks dependency install scripts (req 104).

**PostgreSQL portability.** The module and lint structure carries over unchanged. Lint would read `information_schema` / `pg_catalog` instead of SQLite pragmas. STRICT maps to native typing, WITHOUT ROWID maps to a composite PK (optionally clustered with BRIN or partitioning), and `json_valid` CHECKs map to `jsonb` columns.

---

## ADR-001 ON DELETE policy

- **Status:** Accepted
- **Date:** 2026-11-05 · **Milestone:** M1 · **Closes:** D11 · **Requirements:** 49, 50, 51, 97, G7

**Context.** In Draft v2, 78 of 80 FKs use the implicit `NO ACTION`. The other two are `CASCADE`: `plan_placement.floor_plan_id` and `user_role.user_id`. Both could silently delete rows with history value. CLAUDE.md convention 3 asks for a deliberate policy. The schema owner decided the history-loss cases on 2026-11-05: RESTRICT for actor columns, RESTRICT for the two former CASCADEs, and RESTRICT for ops links.

**Decision.** Every FK declares `ON DELETE`. The default is `RESTRICT`. It fails at the statement, not at COMMIT the way deferred NO ACTION does. Master data (tenant, site, space, gateway, controller, device, user_account, floor_plan) is soft-deleted (`status`, `discovery_state`, `is_current`), so a RESTRICT is never hit in normal operation. It only stops a buggy or manual hard delete.

| Table.column → parent | ON DELETE | Why |
|---|---|---|
| site.tenant_id, space.site_id, space.parent_id, floor_plan.space_id | RESTRICT | Master-data hierarchy; soft-deleted |
| plan_placement.floor_plan_id | RESTRICT (was CASCADE) | Placements must survive for plan rollback (G7, req 39) |
| plan_placement.device_id / controller_id / gateway_id | RESTRICT | Placement history of master data |
| gateway.space_id, controller.space_id, device.space_id | **SET NULL** | Optional by design; a mutable "where installed" pointer, not history. Location history lives in plan_placement and audit_log |
| gateway.site_id, controller.gateway_id, device.controller_id, device.device_type_id, device_type.device_category_id, vendor_type_map.device_type_id | RESTRICT | Master/reference data |
| gateway_hardware.gateway_id, device_hardware.device_id / controller_id | RESTRICT | Hardware history (req 26–28) |
| device_tag.device_id | CASCADE | Pure child, no meaning alone |
| device_state.device_id | CASCADE | Current-value cache; history is device_state_history |
| device_state_history.device_id | RESTRICT | History (req 17) |
| event.* (gateway, gateway_hardware, controller, device, alarm_class) | RESTRICT | Alarm log (req 49) |
| alarm.* (raised/cleared event, site, controller, device, alarm_class) | RESTRICT | Alarm history; retention removes alarms before their events (M11) |
| device_type_telemetry.device_type_id | CASCADE | Config child of a device type |
| device_type_telemetry / vendor_key_map / telemetry / gateway_telemetry / telemetry_rollup .telemetry_key_id | RESTRICT | Reference data with history attached |
| telemetry.device_id, gateway_telemetry.gateway_id, gateway_health.gateway_id, quarantine.gateway_id | RESTRICT | Readings and integrity history (req 95) |
| command_type.permission_id, command_schedule.*, schedule_run.command_schedule_id | RESTRICT | Config with history attached |
| command.* incl. session_id, schedule_run_id | RESTRICT | Command log (req 9–12, 50) |
| role_permission.role_id | CASCADE | Pure link row; role changes are audited |
| role_permission.permission_id | RESTRICT | A permission in use cannot vanish |
| user_role.user_id | RESTRICT (was CASCADE) | Users are disabled, not deleted |
| user_role / directory_group_role .role_id, tenant_id, site_id, space_id | RESTRICT | Scope must stay resolvable |
| session.user_id, document_acceptance.user_id | RESTRICT | Identity history (req 72) |
| audit_log.user_id, audit_log.session_id | RESTRICT | Audit is never deleted (req 50), so sessions it references are kept too |
| update_history.backup_run_id | RESTRICT | Update provenance (req 116–120) |
| every `*_by_user_account_id` actor column | RESTRICT | Attribution must never be lost |

**Alternatives.** *SET NULL on actor columns:* rejected, it loses attribution. *SET NULL on session/backup links so retention can purge them:* rejected; the rows are small, and the audit link has more value. *Keep NO ACTION:* rejected, because it's implicit and is checked only at COMMIT.

**PostgreSQL portability.** The same `ON DELETE RESTRICT | CASCADE | SET NULL` clauses work unchanged.

## ADR-002 FK-index exceptions

- **Status:** Accepted
- **Date:** 2026-11-05 · **Milestone:** M1 · **Closes:** P5 (part 1) · **Requirements:** 99, T1, T7, T8

**Context.** Convention 4 wants an index on every FK. Draft v2 had 60 FK columns without one, and M1 adds about 30 actor columns. The CLAUDE.md alarm-path rule requires a benchmark for any new index on a hot table, and M1 has no benchmark harness yet (M12).

**Decision.** M1 indexes every FK on config, master and low-volume history tables, using partial `WHERE col IS NOT NULL` indexes for optional columns. The rest stay in `lint-allow.json` with this ADR:
- **Standing:** `*_by_user_account_id` actor columns. user_account is never hard-deleted, so the RESTRICT parent check never runs, and "what did user X do" is answered from audit_log.
- **Standing:** `telemetry`, `gateway_telemetry` and `telemetry_rollup` `.telemetry_key_id`. telemetry_key is reference data, and an extra index on a WITHOUT ROWID raw table roughly doubles its write cost.
- **Deferred (tag `deferred`, milestone in the entry):** FKs on `event`, `alarm` (M5), `command` (M6) and `audit_log` (M9). Those milestones choose the access-path indexes (P5) with a benchmark.

**Alternatives.** *Index everything now:* rejected. It adds about 70 indexes, including on hot ingest paths, with no measurement.

**PostgreSQL portability.** PostgreSQL also doesn't index FKs automatically, so the same list applies. Partial indexes map one to one.

## ADR-003 Connection profile and checkpoint ownership

- **Status:** Accepted (the numbers are proposed defaults, to revisit after the M12 benchmarks)
- **Date:** 2026-11-05 · **Milestone:** M1 · **Closes:** P1 · **Requirements:** 97, 99, T1, T7

**Context.** Draft v2 stated the durability pragmas in a comment only. Req 97 says nothing is acknowledged before it's durable. The single writer runs with `wal_autocheckpoint=0`, so the service must own checkpointing, or the WAL grows without bound.

**Decision.** `db/tools/connection.js` is the reference profile. `openWriter` and `openReader` set and then **assert** every setting. `assertProfile` throws on any mismatch, and the service must refuse to start on a failure. The settings, the checkpoint policy (PASSIVE every 30 s or at 1,000 WAL pages, TRUNCATE after 60 s idle, WAL-size warning at 64 MB and Trouble at 256 MB) and the commit-before-ack rule are in `docs/db/CONNECTION_PROFILE.md`. DEFENSIVE comes from better-sqlite3 (on by default, `unsafeMode()` is never called) and is asserted by behaviour. `mmap_size=0`, because an I/O fault on a mapped page crashes the process instead of returning `SQLITE_IOERR`.

**Alternatives.** *`wal_autocheckpoint=1000` (the SQLite default):* rejected. The checkpoint would run inside an ingest commit and add latency to the alarm path (T1). *`synchronous=NORMAL` in WAL:* rejected. It can lose the last transactions on power loss, which conflicts with req 97.

**PostgreSQL portability.** It maps to `synchronous_commit=on`, `fsync=on` and `full_page_writes=on`. Checkpointing belongs to the server (`checkpoint_timeout`, `max_wal_size`). There's no DEFENSIVE equivalent; role privileges cover it.

## ADR-004 user_version as schema version; schema_version as migration log

- **Status:** Accepted
- **Date:** 2026-11-05 · **Milestone:** M1 · **Closes:** N5, P3 · **Requirements:** 97, 116–120

**Context.** Draft v2 kept the version in a `schema_version` table and never set `PRAGMA user_version`. That leaves two sources of truth and no proof of which DDL was applied.

**Decision.** `PRAGMA user_version` is the schema version of record. It's 3 for the v3 schema under development. `00_header.sql` declares it. The build sets it last, inside the build transaction, after `foreign_key_check`, so a failed build leaves 0. `schema_version` becomes an append-only migration log, blocked by triggers, with these columns: `(version, module, checksum = sha256 of the module text, applied_at, applied_by = process identity, description)` and `UNIQUE(version, module)`. `applied_by` is TEXT because migrations are applied by a process, not by a user. `PRAGMA application_id = 0x4F4D4E49` ('OMNI') marks Omniconn files. After the schema freeze, each migration is one transaction that appends its row and bumps `user_version`.

**Alternatives.** *Keep the version in the table only:* rejected. `user_version` sits in the file header and can be read without parsing the schema.

**PostgreSQL portability.** There's no `user_version`; a one-row `schema_meta` table or a migration tool's table replaces it. The `application_id` check turns into a database comment or that metadata table.

## ADR-005 Lookup tables for extensible domains; match_key normalisation; fixed seed ids

- **Status:** Accepted
- **Date:** 2026-11-06 · **Milestone:** M2 · **Closes:** N1, N6 · **Requirements:** 6, 41, T14

**Context.** Draft v2 repeated `system IN ('fire','bms','energy','access','cctv','other')` in four tables: `controller`, `device_category`, `alarm_class` and `command_type`. SCHEMA_REVIEW N1 says six, but Draft v2 and v3 have four. It also kept `vendor` as free text in `controller`, `vendor_type_map` and `vendor_key_map`, and `protocol` as free text in `controller`. Adding a system or protocol meant a schema change, and vendor spelling drifted. Reference names were English only (N6, T14).

**Decision.**
- **Lookup tables.** New tables `system`, `vendor` and `protocol`, each with `id INTEGER PRIMARY KEY`, audit columns and `row_version`. The nine columns become `<lookup>_id` FKs with `ON DELETE RESTRICT`, each recorded as a rename in `db/tools/equiv.js`.
- **Vendor matching.** `vendor.match_key` is `GENERATED ALWAYS AS (upper(trim(name))) STORED` with `ux_vendor_match_key`. The service looks vendors up by `match_key`, so `'Simplex'`, `'SIMPLEX'` and `' simplex '` are one vendor. `vendor_type_map.vendor_type` gets `CHECK (vendor_type = upper(trim(vendor_type)))`, so the documented upper-case rule is enforced.
- **name_key.** Every user-visible reference table gets `name_key`: `system`, `protocol`, `condition`, `device_state_code`, `alarm_class`, `permission`, `role`, `device_category`, `device_type`, `command_type` and `telemetry_key`. It's `TEXT UNIQUE CHECK (name_key GLOB '[a-z]*' AND name_key NOT GLOB '*[^a-z0-9._]*')`, for example `alarm_class.fire`. It's nullable, and a NULL means "display the stored name as typed" (custom roles, runtime-discovered conditions). The UI resolves keys to EN/AR text. The database holds keys, not translations. `db:lint` rule `name-key` enforces the format.
- **Fixed seed ids.** `system` 1 = fire, so `controller.system_id` and `device_category.system_id` can `DEFAULT 1`. Seeds use `INSERT … ON CONFLICT DO NOTHING`, so running them twice is a no-op (`seed.test.js`). Seeds build fresh databases. After the schema freeze, reference-data changes ship as migrations.
- `protocol` will FK the Section 13 module catalogue in M8.

**Alternatives.**
- *Keep CHECK lists:* rejected. Convention 9 says an extensible domain needs a lookup table.
- *`COLLATE NOCASE` instead of match_key:* rejected. It ignores surrounding spaces, and its ASCII-only folding is implicit. A visible key column is explicit and portable.
- *A translation table instead of `name_key`:* deferred. T14 asks for externalised text, which the UI resource bundles already provide. A table can be added later if translations must be editable at runtime.

**PostgreSQL portability.** Lookup tables and FKs map directly. `match_key` becomes a `GENERATED ALWAYS AS (upper(btrim(name))) STORED` column, or a unique index on `upper(btrim(name))`. `citext` is an alternative. The `GLOB` checks become `name_key ~ '^[a-z][a-z0-9._]*$'`.

## ADR-006 Condition dictionary with first-sight UPSERT

- **Status:** Accepted
- **Date:** 2026-11-06 · **Milestone:** M2 · **Closes:** G9 (dictionary part; statistics access path in M5) · **Requirements:** 41, 43

**Context.** `event.condition` was free text. Req 41 needs eight named conditions counted separately, and an unknown reported condition "counted under its reported name rather than discarded". Free text can't be managed or filtered cheaply (req 43).

**Decision.**
- **Table.** `condition(id, code, raw_name, match_key GENERATED upper(trim(raw_name)) UNIQUE, is_reported_unknown, name_key, audit columns)`, with `CHECK (is_reported_unknown = 1 OR (code IS NOT NULL AND name_key IS NOT NULL))`.
- **Seed.** The eight req-41 conditions.
- **Event column.** `event.condition` becomes `event.condition_id` (FK RESTRICT, nullable). The raw text stays in `event.raw_json`.
- **Ingest pattern**, inside the ingest transaction, before the event INSERT:
  ```sql
  INSERT INTO condition (raw_name, is_reported_unknown, created_at, updated_at)
    VALUES (:raw, 1, :now, :now) ON CONFLICT (match_key) DO NOTHING;
  SELECT id FROM condition WHERE match_key = upper(trim(:raw));
  ```
  `RETURNING` yields no row on conflict, so the SELECT is needed (tested in `reference.test.js`). Conditions are never deleted, so the service may cache `match_key → id` and skip both statements on a hit.
- **Index.** No index on `event.condition_id` yet. It's a hot table (CLAUDE.md alarm-path rule). It's deferred to M5 with the statistics access path (lint-allow entry, ADR-002).
- **Measured cost.** This is an ad-hoc probe, because `db:bench` is a stub until M12. File DB, WAL, `synchronous=FULL`, 50,000 events in batches of 500:
  - `condition_id` NULL: about 101–105k events/s
  - upsert + select + FK every event: about 77–78k events/s, roughly +3 µs per event

  With the in-memory cache the per-event cost drops to the FK parent lookup.

**Alternatives.**
- *Keep free text and add an index:* rejected. It's unmanaged, can't be translated, and the index is wider.
- *Reject unknown conditions:* rejected, because req 41 says they must be counted.
- *`DO UPDATE SET … RETURNING id`:* rejected. It writes the row on every event.

**PostgreSQL portability.** `INSERT … ON CONFLICT (match_key) DO NOTHING` is identical. In PostgreSQL, a `WITH ins AS (… RETURNING id) SELECT … UNION ALL SELECT …` can do it in one round trip.

## ADR-007 RBAC seed: permission domains, built-in roles and the approved matrix

- **Status:** Accepted (code list and both role matrices approved in chat, 2026-11-06)
- **Date:** 2026-11-06 · **Milestone:** M2 · **Closes:** G4 (permission-domain part; gateway-scoped assignment in M8) · **Requirements:** 6, 56, 57, 58, Section 13

**Context.** Req 57 lists the granular permissions. Req 56 needs four built-in roles composed from them and editable without a code change. Section 13 says gateway permissions are separate from fire permissions, and its role split is "proposed for approval". Draft v2 had no domain and no seed.

**Decision.**
- **`permission` columns.**
  - `domain` with `CHECK (domain IN ('fire','gateway','platform'))`. It's a closed boundary, not an extensible domain.
  - `CHECK ((domain = 'gateway') = (code GLOB 'gateway.*'))` and a lowercase dotted `code` format.
  - `is_central_grant_required` with `CHECK (is_central_grant_required = 0 OR domain = 'gateway')`. The milestone text calls it `requires_central_grant`. It's renamed for convention 6 (booleans are `is_/has_/can_`).
- **22 codes:**
  - fire: `alarm.view`, `alarm.acknowledge`, `panel.silence`, `panel.reset`, `device.disable`, `device.discover`, `plan.edit`
  - platform: `user.manage`, `tenant.manage`, `setting.manage`, `licence.manage`, `data.export`, `analytics.operator.view`, `audit.read`
  - gateway: `gateway.view`, `gateway.network.configure`, `gateway.service.manage`, `gateway.module.install`, `gateway.module.configure`, `gateway.module.activate`, `gateway.module.remove`, `gateway.access.approve`
  - The central grant is required for `service.manage` and `module.*`. It's not required for `view`, for `network.configure` (which must work offline for site repair) or for `access.approve` (exercised on the Omniconn server).
- **Built-in roles** (`is_builtin = 1`, `name_key` required). The fire roles are cumulative:

  | Role | Permissions |
  |---|---|
  | Viewer | `alarm.view` |
  | Operator | Viewer, plus `alarm.acknowledge`, `panel.silence`, `panel.reset`, `data.export` |
  | Engineer | Operator, plus `device.disable`, `device.discover`, `plan.edit` |
  | Administrator | Engineer, plus every platform permission |
  | Gateway Viewer | `gateway.view` |
  | Gateway Operator / Commissioning User | `gateway.view` |
  | Omniconn Gateway Administrator | `gateway.view`, `gateway.network.configure`, `gateway.service.manage`, `gateway.module.*` |
  | Central Access / Module Approver | `gateway.access.approve` only |

  No fire role holds a gateway permission, and approval is kept apart from execution.
- **Role triggers.** `trg_role_builtin_no_delete` and `trg_role_builtin_immutable` (name, name_key, is_builtin). Built-in roles' `role_permission` rows stay editable (req 56).
- **All four fire alarm classes** are `is_life_safety = 1` (approved), seeded with `is_builtin = 1`. `trg_alarm_class_fire_immutable` blocks changes to `system_id`, `code`, `precedence`, `is_life_safety` and `is_builtin` on fire classes, and `trg_alarm_class_builtin_no_delete` blocks deletion. `ux_alarm_class_system_id_precedence` makes precedence unique per system.
- **Last-admin rule.** Req 56 says "never no account with user.manage". That needs user assignments, so it's enforced in M7. M2 only guarantees that the Administrator role holds `user.manage`.

**Alternatives.**
- *View-per-area codes* (`device.view`, `plan.view`, `report.view`): offered, not chosen.
- *Reset as Engineer-only:* offered, not chosen.
- *Bundle `network.configure` into Gateway Operator:* offered, not chosen.

**PostgreSQL portability.** Tables, CHECKs and seeds map directly (`GLOB` becomes `LIKE`/`~`). The triggers become `BEFORE UPDATE/DELETE` trigger functions that `RAISE EXCEPTION`.

## ADR-008 device_state_code seed list

- **Status:** Proposed (table created and seeded in M2 for M4; the list needs product confirmation)
- **Date:** 2026-11-06 · **Milestone:** M2 · **Closes:** — · **Requirements:** 1, 6, 15, 18, 19

**Context.** M4 moves `device_state.primary_state` and `states_json` onto a lookup with precedence. The architecture names the alarm types (req 6), disabled devices (req 19), test (req 19) and missing devices (req 18). It gives no full state list or ordering.

**Decision (proposed).** `fire` 1, `priority2` 2, `supervisory` 3, `trouble` 4 (all `is_alarm = 1`, matching req 6). Then `disabled` 5, `test` 6, `missing` 7, `unknown` 8 and `normal` 99. Precedence is UNIQUE. To confirm before M4: the non-alarm ordering, and whether `unknown` belongs here or staleness stays the `is_stale` flag.

**Alternatives.** *Derive device state order from `alarm_class` only:* it can't express the non-alarm states.

**PostgreSQL portability.** Direct.

## ADR-009 Per-user grant of gateway.network.configure

- **Status:** Proposed (not implemented)
- **Date:** 2026-11-06 · **Milestone:** M2 · **Closes:** — · **Requirements:** 58, Section 13

**Context.** The approved gateway matrix leaves `gateway.network.configure` out of Gateway Operator / Commissioning User: it is "granted per user". The schema grants permissions only through roles (`role_permission`, `user_role`). Today a site would create a custom role holding that one permission and assign it alongside Gateway Operator.

**Decision (proposed).** Seed a fifth built-in add-on role, "Gateway Network Configurator" (`role.gateway_network_configurator`), holding only `gateway.network.configure`. It's assigned per user, and per gateway once M8 adds gateway scoping. Not implemented until a human chooses.

**Alternatives.** *Direct user grants (`user_permission`):* this is a second permission path, which works against req 58's single enforcement point. *A custom role per site:* this works today, with no schema change.

**PostgreSQL portability.** Direct.

## ADR-010 Space hierarchy rules and depth cap

- **Status:** Accepted (type pairs and depth cap approved in chat, 2026-11-06)
- **Date:** 2026-11-06 · **Milestone:** M3 · **Closes:** D6 (space part) · **Requirements:** 30, 54, 59

**Context.** In Draft v2, `space.parent_id` could point at a space in another site or at one of the space's own descendants (D6). Nothing constrained which type sits under which. Req 30 needs at least three levels per site. M3 also does the deferred rename `parent_id` → `parent_space_id` (ADR-000 item 7).

**Decision.**
- **Allowed type pairs** are reference data in `space_type_rule(parent_type, child_type)`. A NULL `parent_type` means the type is allowed at the root of a site. Seeded by `db/seed/04_space.sql`:

  | Parent | Allowed children |
  |---|---|
  | root | building, other |
  | building | floor, zone, other |
  | floor | zone, room, other |
  | zone | zone, room, other |
  | room | other |
  | other | any type |

- **Triggers abort with `space: <rule>`.**
  - `trg_space_hierarchy_ins` / `_upd` check four rules:
    - the parent is in the same site;
    - no self-parent and no cycle (a recursive CTE walks up from the new parent);
    - the type pair is allowed, including when a type change would orphan an existing child;
    - the depth cap holds, counting the moved subtree's height.
  - `trg_space_site_immutable` stops `site_id` from changing. Moving a space to another site means archiving it and creating a new one, so history keeps pointing at the right site.
- **`space.depth`** is 0 at the root and `CHECK (depth BETWEEN 0 AND 7)`, so a site can have up to 8 levels and always has the 3 that req 30 requires.
  - It's derived from `space_closure` by `trg_space_closure_ins` / `_move`.
  - `trg_space_depth_derived` rejects any write that disagrees with the closure.

**Alternatives.**
- *Strict building > floor > zone > room:* not chosen. Real sites have outdoor areas, plant rooms and wings that don't fit it.
- *Permissive (only the depth and cycle rules):* not chosen, because nonsense such as a building under a room would pass.
- *A `space_type` lookup table with `space_type_id`:* not chosen. The five types are a closed list used by the UI icons, and replacing `space.type` would remove a Draft v2 column.

**PostgreSQL portability.** The rule table maps directly, and `IFNULL` becomes `COALESCE`. The triggers become a `BEFORE INSERT OR UPDATE` trigger function. A recursive CTE inside a trigger is standard. `depth` could stay trigger-maintained, or `ltree` could replace both depth and the closure.

## ADR-011 space_closure (WITHOUT ROWID), trigger-maintained

- **Status:** Accepted
- **Date:** 2026-11-06 · **Milestone:** M3 · **Closes:** D6 (scope part) · **Requirements:** 55, 59

**Context.** A user_role scoped to a space applies to that space and everything beneath it (req 59). Every scope check and every isolation filter (req 55) would otherwise need a recursive walk, and a recursive walk can't be one indexed predicate.

**Decision.**
- **Table:** `space_closure(ancestor_space_id, descendant_space_id, depth)`.
  - `PRIMARY KEY (ancestor_space_id, descendant_space_id)`, **WITHOUT ROWID**. This is a convention 1 exception: a natural composite key, never referenced by an FK, always read by key prefix. It's 2 integers and a depth, so a rowid plus a separate unique index would double its size.
  - It includes the self row at depth 0, so `ancestor = :space` alone covers "this space and beneath".
  - `ix_space_closure_descendant_space_id (descendant_space_id, depth)` covers the reverse lookup ("all ancestors of X", used by scope checks).
  - Both FKs are `ON DELETE CASCADE` because the rows are pure derived data.
- **Maintenance**, by triggers on `space`:
  - `trg_space_closure_ins` writes the self row plus one row per ancestor of the parent.
  - `trg_space_closure_move` (AFTER UPDATE OF parent_space_id) deletes the links from the old ancestors to the subtree, inserts the cross product of the new ancestors and the subtree, then re-derives `depth` for the subtree.
- **Scope check, one indexed join:**

  ```sql
  SELECT 1 FROM user_role ur
  JOIN space_closure sc ON sc.ancestor_space_id = ur.space_id
  WHERE ur.user_id = :u AND sc.descendant_space_id = :space
  ```

- **Write protection.** SQLite triggers can't tell maintenance writes apart from direct ones without a flag table. So the rule is that only the triggers write `space_closure`; the service never does. `tenancy.test.js` checks the table against a recursive-CTE oracle: a random tree of 2,000 spaces plus 200 random moves.

**Alternatives.**
- *Recursive CTE at query time:* rejected. It isn't one indexed predicate, and its cost grows with depth on every scope check.
- *Materialised path (`/1/5/17/`) with a LIKE prefix:* rejected. LIKE prefix use of an index is fragile in SQLite (case-sensitivity pragmas), and moves rewrite strings.
- *Nested sets:* rejected. Every insert renumbers half the tree.

**PostgreSQL portability.** The same table works as an ordinary table with a composite PK, maintained by trigger functions. `ltree` with a GiST index is a native alternative.

## ADR-012 Floor plan revisions and draft-first replacement

- **Status:** Accepted (flow, confirm-all rule and dedupe scope approved in chat, 2026-11-06)
- **Date:** 2026-11-06 · **Milestone:** M3 · **Closes:** G7 · **Requirements:** 29, 31, 34, 39

**Context.** Draft v2 allowed several `is_current = 1` plans per space, and placements weren't tied to a plan revision, so rejecting a replacement couldn't restore anything (G7). Req 39: placements are shown against the new image for confirmation *before* the replacement is committed, and the previous image and placements are recoverable if the replacement is rejected.

**Decision.**
- **New `floor_plan` columns:**
  - `revision_no`: per space, assigned max + 1 by trigger, with `ux_floor_plan_space_id_revision_no`.
  - `replaces_floor_plan_id`: must be the space's current plan at upload.
  - `status`: draft / current / superseded / rejected.
  - `status_changed_at`.
- **`is_current`** stays for Draft v2 readers as `GENERATED ALWAYS AS (status = 'current') VIRTUAL`. A generated column can't be written, so the lint `bool` CHECK doesn't apply (allowlisted under this ADR).
- **Indexes:**
  - `ux_floor_plan_current` and `ux_floor_plan_draft`: at most one current and one pending draft per space.
  - `ux_floor_plan_space_id_sha256 … WHERE status IN ('draft','current')`: dedupe over live revisions only, so an image that was rejected or superseded once can be uploaded again.
- **State machine** (`trg_floor_plan_status`): draft → current | rejected, and current → superseded. Superseded and rejected are final.
  - Current → superseded needs a pending draft that replaces the plan.
  - Draft → current needs the replaced plan to be superseded first, and **no placement on the draft may be `needs_review`** (confirm-all).
  - A new revision is inserted as `draft`, or as `current` only when the space has no current plan.
- **Immutability:** revision content (file, dimensions, hash, space, revision_no, uploader) can't change (`trg_floor_plan_content_immutable`).
- **Placements belong to one revision.**
  - The placement triggers freeze placements of superseded and rejected revisions (no insert, update or delete) and forbid moving a placement to another revision.
  - `needs_review` is allowed only on a draft.
- **Flow.** The replacement is draft-first. The current revision and its placements are never modified, so a rejected draft leaves them exactly as they were: that is the req 39 restore. The transaction script is in `docs/db/PLAN_REPLACEMENT.md`, and its SQL is executed by `tenancy.test.js`.

**Alternatives.**
- *Promote while some placements still need review:* not chosen; req 39 confirms before commit.
- *A post-commit rollback path (superseded → current):* not chosen; not required, because rejection happens before commit.
- *Full `UNIQUE (space_id, sha256)`:* not chosen; it blocks re-uploading an image that was rejected once.
- *Drop `is_current`:* rejected, because removing a Draft v2 column needs a human decision and the generated column costs nothing.

**PostgreSQL portability.** Partial unique indexes and the generated column (`GENERATED ALWAYS AS … STORED`) map directly. The triggers become trigger functions. The draft/current swap needs the same order (supersede, then promote), or a `DEFERRABLE` exclusion constraint.

## ADR-013 Arabic/Latin name search keys deferred to the M4 FTS5 design (P9)

- **Status:** Accepted (deferral approved in chat, 2026-11-06)
- **Date:** 2026-11-06 · **Milestone:** M3 · **Closes:** — (P9 deferred to M4) · **Requirements:** 15, 55, T14

**Context.** `COLLATE NOCASE` folds only ASCII (P9). Site, space and device names are typed in English or Arabic, and search must match them regardless of case, diacritics and letter variants. SQLite generated columns can't call an app-defined normaliser safely: the function would have to be registered on every connection, and `trusted_schema=OFF` (ADR-003) blocks app functions in schema expressions.

**Decision.** M3 adds no search column. M4 designs one FTS5 search for devices, spaces and sites (req 15), scoped by site so that isolation holds (req 55). Its normalisation, applied by the service when it writes the index and when it builds the query, is:
1. Unicode NFKC.
2. Case-fold.
3. Strip Arabic tashkeel (U+064B–U+065F, U+0670) and tatweel (U+0640).
4. Unify the alef forms أ إ آ ٱ → ا, ى → ي, and ة → ه.
5. Map Arabic-Indic digits to ASCII.

FTS5 `unicode61 remove_diacritics 2` handles Latin diacritics.

**Alternatives.** *A service-maintained `name_search` column now:* not chosen. It would be superseded by the M4 FTS5 table.

**PostgreSQL portability.** `unaccent` and a custom normalising function behind a `GENERATED` column with a `pg_trgm` or `tsvector` index.
