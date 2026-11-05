# Schema improvement milestones — Claude Code prompts

How to use this file:

1. Put `CLAUDE.md` at the repo root. Put the reference files where CLAUDE.md lists them.
2. Run the milestones **in order**, one Claude Code session each (`/clear` between them). Paste the prompt block as-is.
3. Each prompt starts in plan mode. Review the plan, answer the "stop and ask" questions, then let it implement.
4. Review the commit before moving on. Every milestone leaves the build green.

| M | Title | Closes (SCHEMA_REVIEW IDs) | Roadmap gate |
|---|---|---|---|
| M0 | Foundation: harness, linter, traceability | — | Design (23 Oct, catch-up) |
| M1 | Physical design, conventions, ACID profile | P1–P4, P8, D9, D10, D11, N5 | Design |
| M2 | Reference data and normalisation | N1, N6, G9 (dictionary), G4 (permission domain) | Design |
| M3 | Tenancy, sites, spaces, floor plans | D6 (space), G7, G11 (partial), P9 | Commissioning |
| M4 | Sources and topology: broker, gateway, controller, device | G2, G5, G6, G17, G18, D6, N2, N3 | Connectivity |
| M5 | Event and alarm core (alarm path) | G1, G9, G10, G11, D2, D3, N4, P4, P5, P6 | Connectivity / Operations |
| M6 | Commands and control safety | D4, D8, G20 (schedule scope) | Operations |
| M7 | Identity, RBAC, sessions, credentials | G12, D5, D7, G4, G16 | Operations |
| M8 | Gateway Management (Section 13) | G3, G4 | 20 Nov / 4 Dec GMA gates |
| M9 | Audit, integrity, quarantine, telemetry cleanup | G11 (audit), D12, G19 | Operations |
| M10 | Reporting, exports, statistics views | G8, G9 (stats), req 35, 53 | Commissioning |
| M11 | Retention, archive, backup, update, licence, settings | D1, D2 (gate), G13, G14, G15, G16 | Acceptance |
| M12 | Verification, performance, durability, handover | P5, P6, P7, all | Acceptance / Release |

---

## M0 — Foundation: harness, linter, traceability

```text
Read CLAUDE.md, docs/db/SCHEMA_REVIEW.md and skim docs/reference/architecture_roadmap_v1.2.md.
Milestone M0. Start in plan mode. NO schema changes in this milestone.

Goal: a repeatable build, lint and test harness so later milestones can change the schema safely.

Tasks
1. Create the layout in CLAUDE.md. Split db/reference/fire_workstation_schema_draft_v2.sql
   UNCHANGED into ordered modules under db/schema/ (00_header, 01_tenancy, 02_sources,
   03_events_alarms, 04_telemetry, 05_commands, 06_identity, 07_audit, 08_integrity,
   09_ops, 10_licence). Prove equivalence: build both and diff the normalised `sqlite_schema`.
2. package.json with better-sqlite3 and the scripts db:build, db:lint, test, db:bench (stub).
   db:build creates build/workstation.db from scratch, applying file-creation pragmas first.
   Print sqlite_version() and fail if < 3.45.
3. db/tools/lint: a script that reads sqlite_schema and pragma table_info/foreign_key_list/
   index_list and reports violations of CLAUDE.md conventions 1-9, 13: non-STRICT table, FK without
   index, FK without explicit ON DELETE, *_json without json_valid CHECK, time column without
   > 0 CHECK, boolean without IN (0,1), naming. Support an allowlist file
   (db/tools/lint-allow.json) where each entry needs a reason and a DECISIONS.md ADR id.
   Run it against the baseline and record the current violation count. Don't fix them yet;
   add them all to the allowlist tagged "baseline" so the count can only go down.
4. Test helpers (db/tests/helpers): freshDb(), expectAbort(sql, messageFragment), explain(sql)
   returning the query plan, insertFixtures() for a minimal tenant/site/gateway/controller/device graph.
   Write one smoke test per module (every table accepts a valid row).
5. docs/db/TRACEABILITY.md: one row per requirement 1-123, T1-T18 and G01-G12 with columns
   Req | Priority | DB relevant? (Y/N) | Objects | Constraint/trigger | Test | Status.
   Pre-fill from the current schema and mark the gaps from SCHEMA_REVIEW.md.
6. docs/db/DECISIONS.md with an ADR template and ADR-000 "Schema modules + lint as gate".

Acceptance
- npm run db:build && npm run db:lint && npm test all pass on a clean clone.
- The equivalence check shows modules == Draft v2.
- TRACEABILITY.md covers every ID in the architecture appendices.
Stop and ask if: the Node toolchain can't be installed (propose the Python sqlite3 alternative).
```

---

## M1 — Physical design, conventions, ACID profile

```text
Read CLAUDE.md and SCHEMA_REVIEW.md (P1-P4, P8, D9, D10, D11, N5). Milestone M1. Plan mode first.

Goal: apply the cross-cutting conventions to every existing table and lock in durability settings.

Tasks
1. 00_header.sql: file-creation pragmas (page_size, auto_vacuum=INCREMENTAL, application_id =
   a fixed Omniconn constant, user_version). Rewrite the header comment so it doesn't name a
   framework (no "Electron"). Make user_version the schema version truth. Turn schema_version into
   a migration log with checksum (sha256 of the module text) and applied_by (N5).
2. docs/db/CONNECTION_PROFILE.md and db/tools/connection: the writer and reader connection
   settings, DEFENSIVE, trusted_schema OFF, busy_timeout, wal_autocheckpoint policy (who
   checkpoints, PASSIVE interval, TRUNCATE when idle, max WAL size alarm), journal_size_limit,
   temp_store, cache/mmap sizing guidance, and BEGIN IMMEDIATE + commit-before-ack rule (req 97).
   Add a test that opens via the profile and asserts every pragma value.
3. Apply conventions to all tables:
   - explicit ON DELETE on every FK using the CLAUDE.md policy (D11); table-by-table rationale in ADR
   - json_valid CHECKs on every *_json column (D9); json_type where shape is fixed
   - sha256/uuid/time/HH:MM domain CHECKs, both-or-neither window, bounds on rotation_deg,
     decimals, interval_sec, keep_days, retention_run.data_type, session.end_reason vs ended_at (D10)
   - created_at/updated_at/updated_by/row_version on mutable configuration tables (P8)
   - indexes for FK columns per lint, or allowlist with reason (P5 part 1)
   - AUTOINCREMENT on event, alarm, command, audit_log (P4)
   - remove site.timezone default; gateway UNIQUE(site_id, name)
4. Remove the "baseline" lint allowlist entries that are now fixed. The remaining entries need ADRs.
5. Tests: a negative test for every new CHECK (one invalid insert each).

Acceptance: lint has no baseline entries left for these rules. Every CHECK has a failing-insert test.
The pragma assertion test passes.
Stop and ask: the ON DELETE choice for any table where history could be lost.
```

---

## M2 — Reference data and normalisation

```text
Read CLAUDE.md and SCHEMA_REVIEW.md (N1, N6, G9, G4). Milestone M2. Plan mode first.

Goal: replace repeated free-text and CHECK domains with lookup tables, and seed the fixed
reference data.

Tasks
1. Lookup tables: system, vendor, protocol (protocol will link to the M8 module catalogue).
   Replace the six repeated system CHECK lists and the free-text vendor/protocol columns with FKs.
   Vendor matching stays case-insensitive through an upper-cased normalised key column.
2. condition dictionary (G9): condition(id, code, raw_name UNIQUE, is_reported_unknown,
   name_key). Seed the 8 conditions in req 41 (Head Missing, No Answer, Abnormal, Output Abnormal,
   Bad Answer, Disabled Device, Sensor Dirty, Open Circuit Reporting). An unknown raw name gets
   inserted on first sight (document the UPSERT pattern) so it's counted, not discarded.
3. device_state_code lookup (code, precedence, is_alarm, name_key), used by M4.
4. alarm_class seed: Fire=1, Priority 2=2, Supervisory=3, Trouble=4 (req 6). Add a trigger that
   blocks UPDATE of code/precedence/is_life_safety for system='fire' and DELETE of seeded rows.
   Precedence UNIQUE per system.
5. permission: add domain CHECK ('fire','gateway','platform'), requires_central_grant flag (M8),
   name_key. Seed the req 57 permissions and the Section 13 gateway permissions (gateway.view,
   gateway.network.configure, gateway.service.manage, gateway.module.install/.configure/.activate/
   .remove, gateway.access.approve) as separate codes. Seed the four built-in roles (req 56)
   and the four Gateway roles. Built-in roles get is_builtin=1, and a trigger stops their deletion.
6. name_key on user-visible reference tables for EN/AR externalised text (N6, T14).
7. db/seed/*.sql is idempotent (INSERT ... ON CONFLICT DO NOTHING). db:build applies it.

Acceptance: no repeated domain CHECK lists remain. Running the seeds twice is idempotent.
Tests prove fire precedence is immutable. TRACEABILITY updated for req 6, 7, 41, 56, 57.
Stop and ask: the final permission code list and the Gateway role-to-permission matrix
(it's "proposed for approval" in Section 13).
```

---

## M3 — Tenancy, sites, spaces, floor plans

```text
Read CLAUDE.md and SCHEMA_REVIEW.md (D6, G7, G11, P9). Milestone M3. Plan mode first.

Goal: a correct, scope-checkable hierarchy (req 30, 54, 55, 59) and recoverable plan
replacement (req 29, 39).

Tasks
1. tenant/site: site.status (active/suspended/archived) and archived_at. Suspension removes
   access only; ingest continues (req 54). Document this in comments.
2. space: triggers so that parent_id is in the same site, there are no cycles (recursive CTE
   check on INSERT/UPDATE of parent_id), and the type order is sensible (floor under building
   etc.; make the allowed parent/child pairs a small lookup). Add depth as a trigger-maintained
   column with a CHECK that the site has at least 3 levels available (req 30).
3. space_closure(ancestor_id, descendant_id, depth) WITHOUT ROWID, maintained by triggers, so
   "role applies to this space and everything beneath" (user_role scope) is one indexed join.
   Test it against a recursive CTE oracle on a random tree of 2,000 spaces.
4. floor_plan: partial unique index for one current plan per space. Add plan revision
   (revision_no, replaces_floor_plan_id, status: draft/current/superseded/rejected) and a
   sha256 dedupe per space. Placement re-confirmation (req 39): plan_placement belongs to a plan
   revision. Replacing a plan copies placements to the draft revision as needs_review, and
   rejecting it restores the previous current revision. Specify this as a transaction script in
   docs, and test it.
5. Cross-site guards: plan_placement target must be in the plan's site. Mapping completeness
   (req 35) view stub.
6. Text search keys for Arabic/Latin names: a normalised search column or a deferral to the M4
   FTS5 design (P9).

Acceptance: negative tests for cross-site parent, cycle, a second current plan and
cross-site placement. The closure table matches the CTE oracle. The plan replace/reject test passes.
```

---

## M4 — Sources and topology: broker, gateway, controller, device

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G2, G5, G6, G17, G18, D6, N2, N3) and architecture Section 5
(contracts) and Section 12 (topologies). Milestone M4. Plan mode first.

Goal: model every source the service supervises, with history, discovery review and search.

Tasks
1. broker (G2): site or installation scope, host, port, tls flag, ca/cert fingerprint, topic
   scope, qos, credential_enc BLOB (DPAPI, req 98), role ('local','customer','omniconn_cloud'),
   is_authoritative per site for hybrid, conn_state, last_contact. Add gateway_broker link if a
   gateway publishes to more than one broker.
2. gateway: tenant reachable via site; agent endpoint (host/port), agent_cert_fingerprint
   (req 81), arch ('arm64','x86_64') on gateway_hardware for module compatibility, contract_version.
3. Version history (G5, req 26-28): component_version_history(source_kind gateway|controller,
   source_id with real FKs (split tables or exactly-one-FK CHECK), component, version, observed_at,
   previous_version). available_version(component, version, published_at, source) and a view
   v_gateway_version_status that returns 'current' / 'outdated' / 'no_comparison' (req 27).
   Writing a version change must also allow an audit row (M9 links).
4. controller: fire network view (req 21) needs node topology. Add controller_link
   (controller_a, controller_b, link_type) if the contract provides it. Otherwise record an ADR.
   conn_state history in source_connection_history (gateway/controller/broker) for T12 evidence.
5. device: same-site/same-controller consistency triggers (D6). device_hardware.controller_id
   must belong to the same gateway lineage.
6. device_state (N2, N3): device_id becomes the primary key. Pick an ADR option: (a) a
   device_state_flag child table with a FK to device_state_code, or (b) keep states_json with a
   CHECK that every element exists in device_state_code. primary_state gets a FK to
   device_state_code and is trigger-maintained from precedence. is_stale is kept with stale_since.
7. Discovery (G6, req 18): discovery_run(requested_by, controller, started/finished, status) and
   discovery_result(run, address, outcome 'added'|'missing'|'changed'|'unchanged', review_state
   'pending'|'accepted'|'rejected', reviewed_by/at). A device is never deleted; missing → review.
8. Device search (G17, req 15): FTS5 external-content table over source_label, local_label,
   space name, type name, address, using tokenizer 'unicode61 remove_diacritics 2', kept in sync
   by triggers. Test English and Arabic queries.
9. Mapping import (req 40): mapping_import(job, file sha, status, preview counts) and
   mapping_import_row(row_no, input_json, resolved_device_id, target_space_id, error).

Acceptance: negative tests for cross-site and orphan topology. Discovery never deletes. FTS
returns expected rows for EN and AR fixtures. EXPLAIN shows the FTS index is used.
Stop and ask: the device_state ADR option, and whether controller_link exists in the gateway contract.
```

---

## M5 — Event and alarm core (alarm path)

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G1, G9, G10, G11, D2, D3, N4, P4-P6) and requirements 1-14, 22,
24, 25, 49, 95-97, 99, T1, T4, T7, T8, T10, T12. Milestone M5. Plan mode first. This is the
alarm path: be conservative, benchmark everything.

Tasks
1. event:
   - add site_id (trigger-copied from gateway → site, for isolation, G11), broker_id (received via),
     contract_version, condition_id (FK, G9).
   - move raw_json to event_payload(event_id PK, raw_json or raw_jsonb). ADR with measured
     bytes/event for both (P6).
   - indexes: (site_id, src_time), (device_id, src_time) for history ordering (req 25, 96),
     (condition_id, src_time) only if the stats benchmark needs it. Keep rcv_time for the live view.
   - consistency trigger: device belongs to controller, controller belongs to gateway.
   - ingest pattern: INSERT ... ON CONFLICT(gateway_hardware_id, source_event_id) DO NOTHING
     RETURNING id. Document it and test duplicates and replays (req 95).
2. Service-generated alarms (G1, req 22, 24): allow alarm origin 'source' | 'service'.
   raised_event_id is required only for 'source'. Alarm target is exactly one of device,
   controller, gateway or broker (CHECK on the count of non-NULLs). Choose between nullable
   raised_event_id and a synthetic 'service' event type with gateway_hardware_id nullable, and
   record the ADR.
3. Alarm lifecycle (D3): states active_unacked, active_acked, cleared_unacked, closed (or the
   equivalent agreed in plan mode). A transition trigger allows only legal moves. CHECKs tie
   acked_at/acked_by and cleared_at to state. A partial unique index allows one open alarm per
   (target, alarm_class). precedence and site_id are trigger-copied (N4).
4. alarm_ack(alarm_id, user_id, session_id, at, group_ack_id) for group acknowledgement (req 8)
   and alarm_note(alarm_id, user_id, at, text) append-only (req 13).
5. Append-only and delete gate (D2): block UPDATE on event, alarm_ack, alarm_note,
   device_state_history. Block DELETE unless a row exists in a retention_gate table set
   inside the retention job transaction (finished in M11; create the gate table here).
6. Covering index for the active alarm list (req 5, T4): open alarms ordered by precedence,
   raised_at, filtered by site.
7. Tests: lifecycle legal and illegal transitions; duplicate event ignored; late flag; service
   alarm with no event; one open alarm per target and class; delete blocked outside retention.
8. Benchmarks (db:bench): insert 50 ev/s for 10 min and 500 ev/s for 60 s, each in batched
   IMMEDIATE transactions, synchronous=FULL, on a WAL DB pre-filled with 10 M events. Report p50
   and p99 commit latency and bytes/event, and the T4 active-list and history queries with
   EXPLAIN QUERY PLAN.

Acceptance: all tests pass. The benchmark report is committed to docs/db/benchmarks/M5.md. No
SCAN on hot queries.
Stop and ask: the alarm state names and the rule for backfilled events
("no re-annunciation of old conditions", Section 5).
```

---

## M6 — Commands and control safety

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (D4, D8, G20) and requirements 9-12, 19, 36, 63, T2,
Section 5 "Control semantics". Milestone M6. Plan mode first.

Tasks
1. command:
   - CHECK exactly one of controller_id/device_id. A trigger checks the target matches
     command_type.target and the site is within the user's scope at insert (scope via M7 views,
     or defer with an ADR).
   - statuses: refused, pending, dispatched, success, rejected, failed, timeout, unknown
     ('unknown' = outcome not confirmed after restart). Add dispatched_at (T2), confirmation_text
     (the panel name the user confirmed, req 9-10), refusal_reason codes
     (source_offline, no_permission, pin_required, pin_failed, duplicate_pending, expired),
     panel_response_json.
   - state transition trigger. Terminal states are immutable. completed_at is required for
     terminal states, and expires_at > requested_at.
   - partial unique index: one pending/dispatched command per (target, command_type) (duplicate
     suppression). Never retried: no column or state allows requeue (req 12).
   - session_id required for user commands, and schedule_run_id for scheduled ones (CHECK).
2. command_schedule (G20): mark it "not in release 1" in comments and DECISIONS.md, but fix it:
   a trigger on command_type UPDATE OF allow_schedule disables dependent schedules or aborts
   (D8, ask which). Window both-or-neither CHECK, HH:MM CHECK. command_schedule_target table
   instead of target_filter_json if filters must be validated.
3. Tests: every illegal transition, duplicate pending, wrong target kind, offline refusal row,
   terminal immutability.

Acceptance: tests pass. TRACEABILITY covers req 9-12, 19, 36, 63, T2.
Stop and ask: the timeout and unknown-outcome semantics, and D8 (disable vs abort).
```

---

## M7 — Identity, RBAC, sessions, credentials

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G12, D5, D7, G4, G16) and requirements 54-66, 85, 86, 98.
Milestone M7. Plan mode first.

Tasks
1. user_account (D7): is_fallback only when auth_type='local'. A partial unique index allows one
   fallback (ask whether more are allowed). Separate password_failed_count / pin_failed_count and
   last_failed_at. credential_algo and credential_params_json (Argon2id m/t/p, req 65).
   pin_set_at and must_set_pin. status adds 'archived'. Soft delete only.
2. credential_attempt (or extend auth audit) for rate limiting by user and client host
   (req 64, 65), with a retention note.
3. Last admin guard (G12, req 56): triggers on user_role, role_permission and user_account
   status abort if no active user would hold 'users.manage'.
4. Scope (req 55, 59): add the missing UPDATE trigger on directory_group_role (D5). user_role
   scope uses space_closure. Optional gateway scope for gateway-domain roles (G4, Section 13),
   with a CHECK that gateway-domain roles are scoped to tenant/site/gateway only.
   v_user_effective_scope(user_id, tenant_id, site_id, space_id) and
   v_user_effective_permission(user_id, permission_code, tenant/site/space/gateway).
   These are the single enforcement inputs (req 58).
5. session: lock state (locked_at, unlock_failures), selected tenant (req 54 "active tenant
   visible"), client_version and protocol_version (req 88 compatibility), idle_timeout_sec
   snapshot, per-session audio prefs stored or ADR'd as runtime only (req 4).
6. first_run_step(step_code, completed_at, completed_by) for the resumable guided first run
   (req 110, G16).
7. Tests: last-admin removal blocked through every path; scope trigger on update; fallback
   uniqueness; the effective permission view on a tree of scopes.

Acceptance: tests pass, including a tenant isolation test where a user of tenant A gets zero
rows from every v_* view for tenant B (req 55).
Stop and ask: the number of fallback accounts, and whether AD vs Windows integrated auth need
distinct auth_type values.
```

---

## M8 — Gateway Management Application (Section 13)

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G3, G4) and architecture Section 13 in full (G01-G12).
Milestone M8. Plan mode first. Several items are "proposed" in the architecture: implement
them as tables with comments citing the open decision, and list the open decisions.

Tasks
1. Module catalogue: gateway_module(code e.g. bacnet/modbus/cip/simplex/snmp, protocol_id,
   description, name_key), gateway_module_version(module, version, arch, runtime_min,
   package_sha256, signature_ok, manifest_json, dependencies_json, resources_json, approved_at),
   module_entitlement(module, tenant/site/gateway scope, version range, valid_from/to, source).
2. gateway_module_install(gateway, module_version, state: staged/installed/configured/enabled/
   running/failed/rolled_back/removed, previous_install_id for rollback, config_snapshot_sha256,
   health_check_ok, fault_reason). State transitions follow the Section 13 lifecycle table, enforced
   by trigger. Configured must come before enabled (no implicit activation). One active install
   per (gateway, module).
3. Central elevation (G05, G06): elevation_request(user, gateway, task, requested_actions_json,
   challenge, status) and elevation_grant(request, grant_id UNIQUE, subject, gateway, actions,
   approver, issued_at, expires_at, consumed_at, revoked_at, is_offline_grant,
   package_sha256 if bound). Single use: consumed_at is set once (trigger), and a consumed or
   expired grant can't open a session. Never store OTP seeds or raw tokens: hashes only, with a
   CHECK on hash format.
4. gateway_admin_session(grant, opened/closed, actions_performed).
5. gateway_setting_change(gateway, field from an allowlist table gateway_setting_field
   (field, validation_json, restart_impact, rollback_supported, is_secret), before/after
   (secrets masked), status pending_confirm/confirmed/rolled_back/failed, confirm_deadline)
   for timed confirm and rollback (G03).
   gateway_service_op(gateway, service from allowlist gateway_service, op start/stop/restart,
   maintenance_window_id or emergency_override with reason).
6. gateway_audit_inbox(gateway_id, gateway_seq, payload, received_at) with UNIQUE(gateway_id,
   gateway_seq) so sync loses or duplicates nothing (G09), then merged into audit_log (M9).
7. Permission domain 'gateway' is enforced: a fire-domain admin role can't satisfy gateway
   permissions (test).

Acceptance: tests for single-use grant, expiry, wrong gateway, consumed after "reboot" (re-open
DB), illegal module transitions, unentitled install blocked, duplicate audit sync ignored.
DECISIONS.md lists every open Section 13 decision.
Stop and ask: the offline-grant policy, and whether the module catalogue is mirrored locally or
fetched per request.
```

---

## M9 — Audit, integrity, quarantine, telemetry cleanup

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G11, D12, G19) and requirements 49, 50, 95, 102, G09.
Milestone M9. Plan mode first.

Tasks
1. audit_log: add seq (AUTOINCREMENT id is fine if gap-free is stated), tenant_id/site_id
   (nullable for installation-level actions) for scoped reading (req 55), correlation_id,
   grant_id (M8), approver_id, client_identity. Specify the hash canonicalisation (field order,
   encoding, NULL representation) in docs. Genesis row seeded. Write db/tools/verify-audit-chain
   and test it with a tamper (edit the file bytes via a raw connection without triggers) to prove
   detection.
2. Index audit_log(user_id, at) and (tenant_id, at). The audit read permission view respects scope.
3. quarantine: payload_sha256, first/last seen, occurrence count (dedupe repeated bad messages),
   status new/reviewed/ignored, reason code. Index on (status, rcv_time) for the dashboard count (req 95).
4. Telemetry cleanup (D12): split telemetry_rollup into device_telemetry_rollup and
   gateway_telemetry_rollup (WITHOUT ROWID, real FKs). Decide in an ADR whether gateway_health is
   removed in favour of gateway_telemetry plus a latest view.
5. technical_log (G19): ADR that it's file-based (recommended). Remove it from the
   retention_policy CHECK or keep it as a policy for file rotation only.

Acceptance: chain verifier passes on clean data and fails on tamper. Scope test on audit reads.
No polymorphic ids without FKs remain.
```

---

## M10 — Reporting, exports, statistics views

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (G8, G9) and requirements 35, 41-48, 52, 53, T4, T6, 99.
Milestone M10. Plan mode first.

Tasks
1. export_job(requested_by, session, tenant_id, scope_json, filter_json (snapshot at request,
   req 44), format pdf/xlsx/csv, kind alarms/alarm_single/register/health/stats, status
   queued/running/cancelling/cancelled/failed/done, progress_pct, row_count, file_path,
   file_sha256, error, requested/started/finished). A CHECK requires done to have file_sha256,
   and cancelled/failed to have no file_path (no partial files, req 48). Provenance columns
   cover req 46.
2. report_schedule(kind, filter_json, format, target_folder, cron, enabled, owner) and
   report_run(status, error, raised_alarm_id) so a write failure raises a Trouble alarm (req 52).
3. Views (read-only, scope-parameterised through joins with v_user_effective_scope):
   v_condition_stats (req 41, per condition including unknowns), v_mapping_completeness (req 35),
   v_disabled_device_count (req 19), v_alarm_response_times (req 53; per-operator figures gated
   by permission plus an installation setting), v_active_alarm_counts (req 1).
4. Generated columns where they help: alarm.ack_duration_ms, event day bucket (only if the
   benchmark proves a gain).
5. Benchmarks: 100,000-row export query (T6) and filtered alarm list (T4) on the M5 dataset,
   run while the ingest benchmark runs (req 99). Report latency for both.

Acceptance: the export state CHECKs are tested. Views return identical rows to the equivalent
filtered list query (req 44 "same rows"). The concurrent benchmark is documented.
```

---

## M11 — Retention, archive, backup, update, licence, settings

```text
Read CLAUDE.md, SCHEMA_REVIEW.md (D1, D2, G13-G16) and requirements 51, 67, 70-76, 97,
107-122. Milestone M11. Plan mode first.

Tasks
1. Retention (D1, req 51): literal CHECKs (data_type='event' → keep_days IS NULL OR
   keep_days >= 365; audit_log keep_days IS NULL always). min_days becomes informational or is
   removed. retention_run gets a FK/CHECK to data_type, plus archive_id.
2. Delete gate (D2, finishes M5): retention_gate(data_type, run_id, opened_at) inserted and
   deleted inside the retention transaction. DELETE triggers on event/alarm/
   device_state_history/command allow deletes only while a matching gate row exists. Batch delete
   pattern by id range plus PRAGMA incremental_vacuum(N) afterwards. Document both.
3. archive_catalogue(data_type, from_ts, to_ts, row_count, file_path, format (sqlite + csv),
   sha256, created_by_run) so archived data stays reachable (req 51, T10). Archive format: an
   attached SQLite DB per period built with the same DDL (readable without the app). ADR it.
4. backup_run: retained_until_next_success flag (req 116), restore_verified_at, location_kind
   (local/external/network, which must survive machine loss), method (backup_api/vacuum_into).
5. Updates (G15): update_history.stage with checkpoint rows update_stage(update_id, stage
   verify/backup/stop/apply/migrate/start/health/commit/rollback, started/finished, outcome) so
   an interrupted update is detectable at startup (req 119). maintenance_window (req 114).
   available_update (req 112).
6. Licence (G14): licence.status, licence_rehost history (req 76), document_acceptance gets
   licence_id and platform_synced_at. Generic sync_outbox(kind, payload_json, created_at,
   attempts, last_error, synced_at) for acceptance records, gateway audit and central requests.
7. Settings (G13, req 67, 75): setting scope (installation/tenant/site) with a FK, a
   setting_definition(key, value_schema_json, is_secret, exportable, requires_permission), and
   value validation triggers via json_type checks. Every change is audited with before/after
   (secrets masked).

Acceptance: tests show retention can't go below the floor, delete outside the gate fails, a
gated delete passes and incremental_vacuum reclaims pages, an interrupted update stage is
detectable, and secret settings are excluded by the portability export view.
Stop and ask: the archive format and location, and whether audit archives may be moved
out of the live DB (they must never be deleted).
```

---

## M12 — Verification, performance, durability, handover

```text
Read CLAUDE.md and all docs/db files. Milestone M12. Plan mode first. No new features: verify,
measure, document.

Tasks
1. Durability test (req 97): a child process ingests in a loop with commit-before-ack logging;
   the parent kills it with SIGKILL at random points 200 times. After each kill, reopen and check
   that every acked id is present, quick_check is ok and foreign_key_check is empty. Add a
   disk-full simulation (max_page_count) showing a clean failure, no corruption.
2. Sizing (T9, T10): extrapolate bytes/event and bytes/device from the benchmarks to 3 years at
   the agreed rate. Produce a table for 5 / 50 / 500 events/s average. Feed the
   SQLite-vs-PostgreSQL decision (Section 6).
3. Query-plan regression suite: every hot query in docs/db/QUERIES.md has an EXPLAIN assertion.
   Add PRAGMA optimize at close plus ANALYZE guidance.
4. Lint is clean with zero baseline exceptions. Every allowlist entry has an ADR.
5. Generate docs/db/DATA_DICTIONARY.md (from the schema plus comments) and docs/db/ERD.md
   (Mermaid, one diagram per module). Generate db/schema.sql as one consolidated snapshot.
6. Write db/migrations/0001_baseline.sql = the frozen v3 schema. From here on, schema changes are
   forward-only migrations.
7. A PostgreSQL portability appendix: every SQLite-specific feature used (STRICT, WITHOUT ROWID,
   FTS5, triggers with RAISE, partial indexes, JSON functions) and its PG equivalent.
8. TRACEABILITY.md: every DB-relevant requirement has an object, constraint and passing test,
   or an explicit "deferred, approved by" note.

Acceptance: all suites are green, the durability run shows zero lost acked events, and the
benchmark and sizing report is committed.
Final summary: residual risks and decisions still open for Vijay.
```
