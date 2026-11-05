# Schema review — fire_workstation_schema Draft v2 vs Architecture & Roadmap v1.2

Reviewed: 5 Nov 2026 · Baseline: `db/reference/fire_workstation_schema_draft_v2.sql` (48 tables, loads cleanly on SQLite 3.53, `foreign_key_check` clean)
Reference: `docs/reference/architecture_roadmap_v1.2.md` (SOW requirements 1–123, targets T1–T18, Gateway Management G01–G12)

Draft v2 is a strong start. It already uses STRICT tables, a WITHOUT ROWID composite key for telemetry, partial unique indexes for "current" rows, append-only triggers, a hashed audit chain, and logical-vs-physical splits for gateways and devices. The findings below are what is still needed for an enterprise-grade, requirement-complete schema.

Severity: **C** = blocks a P1 requirement or risks data loss or integrity · **H** = blocks P2/G-tests or is a significant integrity gap · **M** = quality, performance or maintainability.

---

## 1. Coverage gaps against the architecture document

| # | Sev | Requirement | Gap in Draft v2 |
|---|---|---|---|
| G1 | C | 22, 24, T12 Source-loss / network Trouble alarms for gateway, panel **and broker** | `alarm.raised_event_id` is NOT NULL and `event.gateway_hardware_id` is NOT NULL, so a service-generated alarm (broker lost, gateway silent) cannot be represented. No `broker` entity exists, and `alarm` has no `gateway_id`. |
| G2 | C | 92, Section 12 hybrid, five topologies | No `broker` table (address, TLS, credentials, topic scope, QoS, authoritative-for). There is also no "received via broker" on `event`, so the two-broker merge and reconciliation rule cannot be audited. |
| G3 | C | Section 13, G01–G12 Gateway Management | Not modelled at all: module catalogue/versions/entitlements, per-gateway module lifecycle (installed → configured → enabled → running), central one-time elevation grants (single-use, consumed state surviving reboot), network-change timed confirm/rollback, allowlisted service operations, gateway audit sync without loss or duplication. |
| G4 | H | Section 13 "gateway permissions separate from fire permissions" | `permission` has no domain, and `user_role` cannot scope to a gateway. |
| G5 | H | 26, 27, 28 Firmware/runtime version history, outdated flag, change audit | Only current `runtime_version` / `firmware_version` columns. There's no history and no "available version" with a "no comparison available" state. |
| G6 | H | 18 Discovery review | No `discovery_run` / `discovery_result` tables to hold additions and absences pending operator review. |
| G7 | H | 39 Plan replacement with recoverable previous plan | `floor_plan.is_current` has no partial unique index, so several plans can be current for one space. Placements aren't versioned per plan revision, so rejecting a replacement can't restore them. |
| G8 | H | 44–48, 52 Exports and scheduled reports | `retention_policy` lists `'export'`, but there is no export table. Nothing holds provenance, filter snapshot, progress, cancel, no-partial-file status or file hash, and there is no report schedule. |
| G9 | H | 41, 43 Condition statistics | `event.condition` is free text with no dictionary and no index. Statistics would need full scans, and "unknown condition counted under its reported name" can't be managed. |
| G10 | H | 8, 13 Group acknowledge, operator notes | One `acked_by`/`note` per alarm. Notes need to be append-only rows with user and time, and should carry into reports. |
| G11 | H | 55 Tenant isolation across views, search, export, **logs** | `event`, `audit_log`, `quarantine` and `command` have no tenant/site column, so scope filtering needs multi-join paths. Isolation can't be enforced by one indexed predicate. |
| G12 | H | 56 Never zero manage-users holders | No guard. |
| G13 | H | 67, 75 Settings with before/after values and portability | `setting` is global only (no tenant/site scope), has no value validation and no "exclude from export / secret" flag. |
| G14 | H | 72, 76 Acceptance stored on licensing platform; licence re-hosting | No sync outbox, no link from acceptance to licence, no licence status or re-host history. |
| G15 | H | 112, 114, 119 Available updates, maintenance window, interruption at every stage | `update_history` has no stage checkpoint, and there's no maintenance window or available-update table. |
| G16 | M | 110 Guided first run (resumable) | No first-run step state. |
| G17 | M | 15 Searchable device register (label, space, type, state) at 100k devices | No search index (FTS5) and no index on labels. Arabic search needs the `unicode61 remove_diacritics` tokenizer. |
| G18 | M | 98 Source secrets encrypted at rest | No place for broker or agent credentials (DPAPI `BLOB`) and no certificate fingerprints for agent trust (81). |
| G19 | M | 102 Technical log | `retention_policy` names `technical_log`, but it doesn't exist. Decide whether it's file-based (recommended) and drop it from the CHECK list or model it. |
| G20 | M | Scope control | `command_schedule`, telemetry roll-ups and multi-system (`bms`, `energy`, `cctv`…) go beyond the December scope (Appendix C excludes BMS/CCTV/access). Keep the extensibility, but mark them as not in release 1 and don't build service logic for them now. |

## 2. Integrity and constraint defects

| # | Sev | Finding |
|---|---|---|
| D1 | C | **Retention floors are editable.** `CHECK (keep_days >= min_days)` uses a column the admin can lower. Req 51 floors must be literals: `event` ≥ 365 days, `audit_log` never deleted. |
| D2 | C | **`event` can be deleted by any code path.** Only UPDATE is blocked. `alarm`, `command` and `device_state_history` have no guards at all. Deletes need to be gated so only the retention job can run them. |
| D3 | C | **Alarm lifecycle isn't enforced.** Nothing checks `acked_at` against `state`, `cleared_at` against `cleared_event_id`, or legal transitions. "Cleared but unacknowledged" (common in fire) isn't representable, and two open alarms can exist for the same device and class. |
| D4 | C | **Command safety isn't enforced in the schema.** There's no "exactly one of controller/device", no check that the target matches `command_type.target`, no terminal-state immutability, no `unknown` outcome, no `dispatched_at` (T2), and nothing stops a second pending command for the same target. |
| D5 | H | Missing UPDATE scope trigger on `directory_group_role`. Only the INSERT trigger exists. |
| D6 | H | No cross-hierarchy consistency checks. A space's parent can be in another site, and a space can be its own ancestor (a cycle). `device.space_id`, `plan_placement` and `alarm.site_id` can point at a different site than the device's controller → gateway → site. `event.device_id` may not belong to `event.controller_id`. |
| D7 | H | `user_account.is_fallback` isn't restricted to `auth_type='local'`, and multiple fallbacks are allowed. PIN and password share one `failed_attempts` counter, there's no hash-algorithm/parameter version (65), and there's no `pin_set_at`. |
| D8 | H | `trg_schedule_allowed` only guards `command_schedule`. Setting `command_type.allow_schedule = 0` later leaves live schedules running. |
| D9 | M | About 20 `*_json` columns have no `json_valid()` CHECK (`address_json`, `attributes_json`, `raw_json`, `value_json`, `ui_prefs_json`, `manifest_json`, `entitlements_json`, `enum_map_json`, `before_json`/`after_json`, `detail_json`…). |
| D10 | M | Hashes, UUIDs and times have no domain checks: `sha256` TEXT without length/hex CHECK, `correlation_id` free text, timestamps with no `> 0` check, `window_start`/`window_end` with no `HH:MM` pattern and no both-or-neither rule, `rotation_deg` and `decimals` unbounded, `retention_run.data_type` without CHECK, `session.end_reason` without `ended_at` consistency. |
| D11 | M | **Every FK uses the default `NO ACTION`.** There's no deliberate ON DELETE policy (RESTRICT for history, CASCADE for pure children, soft-delete for master data). |
| D12 | M | `telemetry_rollup` (`source_kind`, `source_id`) is polymorphic with no FK. `gateway_health` duplicates `gateway_telemetry` (CPU, memory, buffer). |

## 3. Normalisation

| # | Finding | Recommendation |
|---|---|---|
| N1 | The `system` domain is a repeated CHECK list in six tables. `vendor` is free text in four tables, and `protocol` is free text. | Use lookup tables (`system`, `vendor`, `protocol`). `protocol` should link to the Section 13 module catalogue. Keep inline CHECKs for closed state machines only. |
| N2 | `device_state.states_json` is a JSON array, which breaks 1NF, and `primary_state` has no vocabulary. | Use a `device_state_flag(device_id, state_code)` child table, or keep the JSON as a cache with a CHECK against the state vocabulary. Derive `primary_state` from a `device_state_code` lookup with precedence. Decide this in an ADR. |
| N3 | `device_state` has a surrogate `id` plus `device_id UNIQUE`. | Make `device_id` the primary key (one fewer B-tree). |
| N4 | `alarm.precedence` is copied from `alarm_class`. | Keeping it is fine for ordering speed, but make it trigger-maintained and document the denormalisation. Do the same for any `site_id`/`tenant_id` copied for isolation (G11). |
| N5 | Several version fields live in two places: `schema_version` table vs `PRAGMA user_version`, and the `installed_component` versions vs `update_history`. | Make `user_version` the source of truth. The migration log also stores a checksum. |
| N6 | Reference-data names are English only (T14). | Add `name_key` (externalised text key) or a translation table for user-visible reference names. |

## 4. SQLite physical design, ACID and durability

| # | Sev | Finding |
|---|---|---|
| P1 | C | Durability settings are in a comment only. The service must apply and **assert** them on every connection: `journal_mode=WAL`, `synchronous=FULL`, `foreign_keys=ON`, `trusted_schema=OFF`, `busy_timeout`, plus `SQLITE_DBCONFIG_DEFENSIVE`. Ingest must use `BEGIN IMMEDIATE` with the commit-before-ack order (req 97). With `wal_autocheckpoint=0`, the service owns checkpointing, and that needs a documented policy (PASSIVE on a timer, TRUNCATE when idle), or the WAL grows without bound. |
| P2 | H | `page_size` and `auto_vacuum=INCREMENTAL` must be set **before the first table is created**. With multi-year retention deletes on a fixed disk, the file will never shrink without them. |
| P3 | H | No `PRAGMA application_id` (to identify an Omniconn DB file) and no `user_version` stamping. |
| P4 | H | IDs referenced by archives and external systems (`event`, `alarm`, `command`, `audit_log`) should use `AUTOINCREMENT` so an id is never reused after deletes. |
| P5 | H | Indexes are missing for required access paths: history ordered by **source time** (25, 96); events and alarms by site (isolation and reports); `alarm(device_id)` for drill-through (21, 37); `command(device_id|controller_id)`; `audit_log(user_id, at)`; condition statistics. About 55 FK columns have no index (deletes and joins scan). Not all need one, so each choice should be recorded. |
| P6 | M | `event.raw_json` sits in the hot table. At T7/T10 scale (up to 4.7 bn rows over 3 years) this dominates size and cache. Split it into `event_payload` (1:1, WITHOUT ROWID or rowid-aligned) or store it as JSONB, and measure bytes per event. |
| P7 | M | Use more SQLite features: generated columns (for example an event day bucket for statistics, alarm time-to-ack), FTS5 for search, `ON CONFLICT DO NOTHING ... RETURNING` for idempotent ingest, recursive CTE or a closure table for space scope checks, `PRAGMA optimize` / `ANALYZE` (STAT4), `VACUUM INTO` / online backup API, and scheduled `quick_check` / `foreign_key_check`. |
| P8 | M | There are no `created_at`/`updated_at`/`updated_by` columns or `row_version` (optimistic concurrency) on the mutable configuration tables edited by multiple operator sessions (86). |
| P9 | M | `COLLATE NOCASE` only folds ASCII. Arabic names need a normalised search key or FTS5, not NOCASE. |

## 5. Housekeeping

- The header says "v1, draft" and "Electron UI", but the architecture leaves the desktop framework open. Make the comment framework-neutral.
- `site.timezone DEFAULT 'Asia/Dubai'` hard-codes a customer region. Make it required, with no default, and validate it in the service.
- There's no `UNIQUE (site_id, name)` on `gateway` and no sha256 dedupe on `floor_plan`.
- The SQLite vs PostgreSQL decision (Section 6) is still formally open. Keep a short portability note per SQLite-specific feature used, so the gate decision is evidence-based.
