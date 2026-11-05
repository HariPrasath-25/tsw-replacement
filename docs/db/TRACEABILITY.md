# Traceability — requirements → schema objects → tests

Source: `docs/reference/architecture_roadmap_v1.2.md`. Appendix A covers requirements 1–123, Appendix B covers targets T1–T18, and Section 13 covers Gateway Management acceptance tests G01–G12. Gap IDs refer to `docs/db/SCHEMA_REVIEW.md`.

**Baseline:** Draft v2 as split into `db/schema/` in M0. **M1** (2026-11-05) applied the cross-cutting conventions: ON DELETE policy (ADR-001), JSON/time/hash/UUID domain CHECKs, P8 audit columns, AUTOINCREMENT, the connection profile (ADR-003) and the migration log (ADR-004). Every CHECK added in M1 is tested in `checks.test.js`. `db/tests/traceability.test.js` fails if any ID from the architecture document is missing here.

**Columns.** *DB relevant?* is Y when the database stores, constrains or serves the requirement. N rows are owned by the service, UI, installer or process, and later milestones don't track them here. *Objects* are tables and columns. *Constraint/trigger* lists only the existing enforcement, not the planned enforcement. *Test* paths are relative to `db/tests/`.

**Status values:**
- `Covered (baseline)`: the current schema represents the requirement and no review finding is open against it.
- `Partial — <IDs>`: represented, but the listed findings must close first.
- `Gap — <IDs>`: not represented.
- `Not measured — M12`: a performance target that needs the benchmark.
- `N/A`: not DB relevant.

Every milestone updates the rows it touches: objects, constraints, tests and status.

## Appendix A — requirements 1–123

| Req | Priority | DB relevant? | Objects | Constraint/trigger | Test | Status |
|---|---|---|---|---|---|---|
| 1 System dashboard | P1 | Y | alarm (state, precedence, site_id), alarm_class (precedence, is_life_safety) | ix_alarm_open (partial, state ≠ cleared) | smoke/03_events_alarms | Partial — G11, P5 |
| 2 Push refresh | P1 | N | — (service push; relies on commit-before-ack, req 97) | — | — | N/A |
| 3 Staleness indication | P1 | Y | device_state.is_stale, last_seen_at, gateway.last_heartbeat / conn_state, controller.last_contact / conn_state | conn_state CHECK lists; time > 0 CHECKs (M1) | smoke/02_sources, checks | Partial — G1 (broker) |
| 4 Audible annunciation per session | P1 | N | — (client) | — | — | N/A |
| 5 Active alarm list | P1 | Y | alarm, alarm_class, device (address, local_label, space_id), controller, site | ix_alarm_open, ix_alarm_site | smoke/03_events_alarms | Partial — P5, G11 |
| 6 Alarm types | P1 | Y | alarm_class (system, code, precedence, is_life_safety) | UNIQUE (system, code) | smoke/03_events_alarms | Partial — N1, N6 (no seed data yet, M2) |
| 7 Type distinction | P1 | N | — (UI colour and symbol) | — | — | N/A |
| 8 Acknowledge (individual / group) | P1 | Y | alarm.acked_by_user_account_id, acked_at, state | state CHECK; acked_at > 0; FK RESTRICT (M1) | smoke/03_events_alarms, checks | Gap — G10, D3 |
| 9 Silence | P1 | Y | command_type (silence, permission_id), command, audit_log | command.status CHECK | smoke/05_commands | Partial — D4 |
| 10 Reset | P1 | Y | command_type.pin_policy, command.is_pin_verified | pin_policy CHECK | smoke/05_commands | Partial — D4 |
| 11 Pending and failed states | P1 | Y | command.status, status_reason, expires_at, completed_at | status CHECK, ix_command_pending | smoke/05_commands | Partial — D4 |
| 12 Refusal when offline | P1 | Y | command.status = 'refused', schedule_run.skip_reason | status / skip_reason CHECK | smoke/05_commands | Partial — D4 |
| 13 Operator notes | P3 | Y | alarm.note | — | smoke/03_events_alarms | Gap — G10 |
| 14 Wallboard mode | P2 | N | — (client) | — | — | N/A |
| 15 Device register | P1 | Y | device, device_state, device_type, space, controller | UNIQUE (controller_id, address), ix_device_space_id, ix_device_device_type_id | smoke/02_sources | Partial — G17, P9, G11 |
| 16 Full device metadata | P2 | Y | device.attributes_json, device_state.analog_json, device_hardware | json_valid + json_type 'object' CHECKs (M1) | smoke/02_sources, checks | Covered (M1) |
| 17 Device state history | P2 | Y | device_state_history, retention_policy ('device_state_history') | ix_device_state_history_device_id_rcv_time; JSON array CHECKs; device_id RESTRICT (M1) | smoke/02_sources, checks | Partial — D2, D1 |
| 18 Device discovery review | P2 | Y | device.discovery_state | discovery_state CHECK | smoke/02_sources | Gap — G6 |
| 19 Device control | P1 | Y | device_type.can_disable / can_test, device_state.is_disabled, command_type (target = device), command | is_disabled CHECK | smoke/05_commands | Partial — D4 |
| 20 Local labels and spaces | P1 | Y | device.local_label vs source_label, device.space_id (SET NULL), updated_at / updated_by_user_account_id / row_version | P8 columns (M1) | smoke/02_sources, checks | Partial — D6 |
| 21 Fire network view | P2 | Y | controller (conn_state, last_contact, gateway_id), gateway | UNIQUE (gateway_id, protocol, ref) | smoke/02_sources | Partial — P5 |
| 22 Network alarms as Trouble | P1 | Y | alarm, event | — | — | Gap — G1 |
| 23 Gateway health | P2 | Y | gateway, gateway_hardware, gateway_health, gateway_telemetry, controller.conn_state | ux_gateway_hardware_current | smoke/02_sources, smoke/08_integrity | Partial — D12, G5 |
| 24 Source loss alarm (gateway, panel, broker) | P1 | Y | — | — | — | Gap — G1, G2 |
| 25 Late delivery marking | P1 | Y | event.is_late, src_time, rcv_time | ix_event_rcv | smoke/03_events_alarms | Partial — P5 (no src_time order) |
| 26 Firmware version tracking | P3 | Y | gateway.runtime_version, contract_version, controller.firmware_version (current only) | — | smoke/02_sources | Gap — G5 |
| 27 Outdated version flagging | P3 | Y | — | — | — | Gap — G5 |
| 28 Firmware change audit | P2 | Y | audit_log | — | — | Gap — G5 |
| 29 Floor plan upload limits | P1 | Y | floor_plan (mime_type, width_px, height_px, size_bytes, sha256) | mime CHECK, 1–8192 px, ≤ 20 MB CHECKs | smoke/01_tenancy | Partial — D10 (sha256 domain, no dedupe) |
| 30 Space hierarchy (≥ 3 levels) | P1 | Y | space (site_id, parent_id, type) | type CHECK, ix_space_site_parent | smoke/01_tenancy | Partial — D6 (cross-site parent, cycles) |
| 31 Drag-and-drop placement | P1 | Y | plan_placement (x, y, rotation_deg) | x/y BETWEEN 0 AND 1, exactly-one-target CHECK, rotation_deg [0, 360) CHECK, ux_plan_placement_* | smoke/01_tenancy | Partial — D6, D10 |
| 32 Plan performance | P2 | Y | plan_placement (read by floor_plan_id) | ux_plan_placement_device / controller / gateway, ix_plan_placement_floor_plan_id | — | Not measured — M12 (T5) |
| 33 Bulk mapping | P1 | Y | device.space_id | — | smoke/02_sources | Partial — D6 |
| 34 Bulk placement | P1 | Y | plan_placement | ux_plan_placement_device | smoke/01_tenancy | Partial — D6 |
| 35 Mapping completeness | P2 | Y | device.space_id, plan_placement | — | — | Gap — M10 view (req 35) |
| 36 Control from the plan | P2 | Y | command (same path as req 19) | — | smoke/05_commands | Partial — D4 |
| 37 Navigate to alarm | P2 | Y | alarm.device_id → plan_placement.device_id | ix_plan_placement_device_id | smoke/03_events_alarms | Partial — P5 (alarm.device_id) |
| 38 Geographic view | P3 | Y | site (no position) | — | — | Gap — not in SCHEMA_REVIEW (site location); to propose in M3 |
| 39 Plan replacement (recoverable) | P3 | Y | floor_plan.is_current, plan_placement.status | status CHECK; plan_placement.floor_plan_id RESTRICT (was CASCADE, ADR-001) | smoke/01_tenancy | Gap — G7 |
| 40 Mapping import | P2 | N | — (service validates, then writes device.space_id through the normal path) | — | — | N/A |
| 41 Condition statistics | P2 | Y | event.condition (free text) | — | — | Gap — G9 |
| 42 Drill-through | P3 | Y | event, alarm, device, plan_placement | — | — | Partial — P5, G9 |
| 43 Filtering (incl. tenant) | P2 | Y | event, alarm, device, space | — | — | Partial — G11, P5, G9 |
| 44 Bulk export | P2 | Y | — | — | — | Gap — G8 |
| 45 Individual alarm report | P2 | Y | alarm, event, command, plan_placement | — | — | Gap — G8, G10 |
| 46 Export provenance | P2 | Y | — | — | — | Gap — G8 |
| 47 Register and health exports | P3 | Y | — | — | — | Gap — G8 |
| 48 Non-blocking export | P2 | Y | — (reader connection, no write lock) | — | — | Gap — G8, P1 |
| 49 Alarm log (append-only) | P1 | Y | event (src_time, rcv_time, raw_json, source_event_id), id AUTOINCREMENT | UNIQUE (gateway_hardware_id, source_event_id), trg_event_no_update, all FKs RESTRICT (ADR-001), raw_json object CHECK, time > 0 | triggers (trg_event_no_update), checks, smoke/03_events_alarms | Partial — D2, G1, P6 |
| 50 Audit log | P1 | Y | audit_log (user_id, session_id, client_host, action, target, outcome, before/after_json, prev_hash, row_hash), id AUTOINCREMENT | trg_audit_log_no_update, trg_audit_log_no_delete, outcome CHECK, sha256 CHECKs on prev_hash/row_hash, JSON object CHECKs, FKs RESTRICT | triggers (trg_audit_log_*), checks, smoke/07_audit | Partial — G11, P5 (M9) |
| 51 Retention floors and archiving | P1 | Y | retention_policy, retention_run | keep_days ≥ min_days, audit_log keep_days NULL; keep_days ≥ 1, min_days ≥ 0, retention_run.data_type domain, archive_sha256 CHECK (M1) | smoke/09_ops, checks | Gap — D1, D2, G19 |
| 52 Scheduled reports | P3 | Y | — | — | — | Gap — G8 |
| 53 Response analytics | P4 | Y | alarm.raised_at, acked_at, acked_by_user_account_id | — | — | Partial — G10, P7 (M10 views) |
| 54 Tenant management | P1 | Y | tenant.status, site | status CHECK, UNIQUE (tenant_id, name) | smoke/01_tenancy | Partial — P8, G11 |
| 55 Tenant isolation | P1 | Y | event, audit_log, quarantine, command (no tenant/site column) | — | — | Gap — G11 |
| 56 Roles; never zero manage-users holders | P1 | Y | role, permission, role_permission, user_role | UNIQUE (role_id, permission_id) | smoke/06_identity | Gap — G12 |
| 57 Granular permissions | P1 | Y | permission (code) | UNIQUE (code) | smoke/06_identity | Partial — G4 (domain), N1 (no seed yet, M2) |
| 58 Single enforcement point | P1 | N | — (service) | — | — | N/A |
| 59 User scoping | P1 | Y | user_role (tenant_id, site_id, space_id) | ux_user_role_scope, trg_user_role_scope, trg_user_role_scope_upd | triggers (trg_user_role_scope*), smoke/06_identity | Partial — D6 |
| 60 Authentication (Windows / AD / local) | P1 | Y | user_account (auth_type, windows_sid, password_hash) | auth_type CHECK, local requires password_hash | smoke/06_identity | Partial — D7 |
| 61 Directory fallback account | P1 | Y | user_account.is_fallback | is_fallback CHECK | smoke/06_identity | Gap — D7 (not restricted to local, not single) |
| 62 Inactivity lock and PIN | P1 | Y | session.locked, user_account.pin_hash | — | smoke/06_identity | Partial — D7 (no pin_set_at) |
| 63 PIN on control actions | P2 | Y | command_type.pin_policy, command.is_pin_verified, setting | pin_policy CHECK, can_schedule ⇒ pin_policy 'never' | smoke/05_commands, checks | Partial — G13 |
| 64 Failed PIN handling | P1 | Y | user_account.failed_attempts, locked_until, session.end_reason ('pin_failures'), audit_log | end_reason CHECK | smoke/06_identity | Partial — D7 (shared counter) |
| 65 Credential storage (memory-hard hash) | P1 | Y | user_account.password_hash, pin_hash (Argon2id) | — | smoke/06_identity | Partial — D7 (no algorithm/parameter version) |
| 66 Directory group mapping | P3 | Y | directory_group_role | ux_group_role_scope, trg_group_role_scope | triggers (trg_group_role_scope), smoke/06_identity | Partial — D5 |
| 67 Settings with audited before/after | P1 | Y | setting (value_json, row_version), audit_log.before_json / after_json | json_valid CHECKs (M1) | smoke/09_ops, checks | Partial — G13 |
| 68 Light and dark themes | P2 | N | — (UI; preference in user_account.ui_prefs_json) | — | — | N/A |
| 69 White labelling | P2 | Y | setting (branding keys) | — | — | Partial — G13 |
| 70 Licence activation | P1 | Y | licence (licence_key_enc, entitlements_json, activation_mode) | activation_mode CHECK | smoke/10_licence | Partial — G14 |
| 71 Terms and privacy acceptance | P1 | Y | document_acceptance (document, doc_version, accepted_at) | document CHECK | smoke/10_licence | Partial — G14 |
| 72 Acceptance recorded on licensing platform | P1 | Y | document_acceptance | — | — | Gap — G14 (sync outbox, licence link) |
| 73 Offline activation | P1 | Y | licence.activation_mode = 'offline' | — | smoke/10_licence | Partial — G14 |
| 74 Licence status | P2 | Y | licence, document_acceptance | — | smoke/10_licence | Partial — G14, D9 |
| 75 Settings portability (no secrets) | P2 | Y | setting; secret-bearing column list in DATA_DICTIONARY.md | — | build.test.js (dictionary up to date) | Gap — G13 |
| 76 Licence re-hosting | P3 | Y | — | — | — | Gap — G14 |
| 77 Desktop executable + background service | P1 | N | — (single-writer service model is the DB premise) | — | — | N/A |
| 78 Windows 11 x64 platform support | P2 | N | — | — | — | N/A |
| 79 No internet exposure; authenticated IPC | P1 | N | — | — | — | N/A |
| 80 Configured addresses / ports, audited, reversible | P2 | Y | setting, audit_log | — | — | Partial — G13 |
| 81 IPC and remote link trust (certificates) | P1 | Y | — (no certificate fingerprints) | — | — | Gap — G18 |
| 82 Unattended start | P1 | N | — | — | — | N/A |
| 83 Capture continues without UI | P1 | N | — | — | — | N/A |
| 84 Control-room full-screen launch | P1 | N | — | — | — | N/A |
| 85 Lock and permission enforced by service | P1 | Y | session (locked, ended_at) | locked CHECK | smoke/06_identity | Partial — enforcement is in the service; DB holds lock state |
| 86 50 concurrent operator sessions | P2 | Y | session, ix_session_open; created_at / updated_at / updated_by_user_account_id / row_version on 23 mutable config tables | row_version ≥ 1 CHECK (M1); optimistic concurrency WHERE id=? AND row_version=? (CONNECTION_PROFILE / DATA_DICTIONARY) | checks, smoke/* | Covered (M1) — schema side; service enforces the WHERE |
| 87 Documented supported versions | P3 | N | — | — | — | N/A |
| 88 Servicing-baseline verification | P2 | N | — | — | — | N/A |
| 89 Layered architecture | P2 | N | — | — | — | N/A |
| 90 Framework-free domain | P2 | N | — | — | — | N/A |
| 91 Single internal event/command model | P2 | Y | event, command (topology-neutral) | — | smoke/03_events_alarms, smoke/05_commands | Partial — G1, G2 |
| 92 MQTT subscription (broker, TLS, credentials, topic scope) | P1 | Y | — | — | — | Gap — G2, G18 |
| 93 Automatic reconnection | P1 | N | — (service) | — | — | N/A |
| 94 Direct Simplex panel connection | P1 | Y | event (gateway_id, gateway_hardware_id NOT NULL), gateway_hardware.platform | platform CHECK | smoke/03_events_alarms | Partial — G1, G2 (direct source without gateway hardware unconfirmed) |
| 95 Event integrity (validate, quarantine, dedupe) | P1 | Y | quarantine, event | UNIQUE (gateway_hardware_id, source_event_id) | smoke/08_integrity | Partial — G11, P7 |
| 96 Time handling (UTC, both times) | P1 | Y | event.src_time / rcv_time, device_state_history, site.timezone | — | smoke/03_events_alarms | Partial — P5, D10 |
| 97 Local store durability | P1 | Y | whole DB; db/tools/connection.js (WAL, synchronous=FULL, foreign_keys, trusted_schema OFF, DEFENSIVE, service-owned checkpoints); 00_header file pragmas; user_version + schema_version log | build: one transaction, foreign_key_check, quick_check, user_version set last; assertProfile refuses mismatches; writeTx commit-before-ack | connection.test.js, build.test.js | Partial — power-cut test under load (M12) |
| 98 Encryption at rest | P1 | Y | licence.licence_key_enc (DPAPI); secret columns listed in DATA_DICTIONARY.md | — | smoke/10_licence | Partial — G18 |
| 99 Alarm path isolation | P1 | Y | event (minimal indexes), reader profile query_only=ON, wal_autocheckpoint=0 (checkpoint off the ingest path) | FK indexes on hot tables deferred with benchmark (ADR-002) | helpers.test.js (assertNoScan), connection.test.js | Partial — P6 (M12 bench, T1) |
| 100 Component licensing | P1 | N | — | — | — | N/A |
| 101 Extensibility (new source type) | P2 | Y | controller.protocol (free text), vendor_type_map, vendor_key_map | — | smoke/02_sources | Partial — N1 |
| 102 Diagnostics / technical log | P2 | Y | retention_policy ('technical_log') | — | — | Gap — G19 |
| 103 Fault containment | P1 | N | — (service) | — | — | N/A |
| 104 Security hardening | P1 | N | — (no plaintext secrets: convention 15) | — | — | N/A |
| 105 Certification-aware design | P3 | N | — | — | — | N/A |
| 106 Signed installer | P1 | N | — | — | — | N/A |
| 107 Licence before download | P1 | N | — | — | — | N/A |
| 108 Offline installation | P1 | N | — | — | — | N/A |
| 109 Safe installation | P1 | N | — | — | — | N/A |
| 110 Guided first run (resumable) | P1 | Y | — | — | — | Gap — G16 |
| 111 Package verification | P1 | Y | update_history.package_sha256, audit_log | — | smoke/09_ops | Partial — D10 |
| 112 Subscribed updates (available versions) | P2 | Y | — | — | — | Gap — G15 |
| 113 Coordinated version compatibility | P1 | Y | installed_component (ipc_protocol, …), update_history.manifest_json | component CHECK, UNIQUE (component) | smoke/09_ops | Partial — N5, D9 |
| 114 Scheduled updates (maintenance window) | P2 | Y | — | — | — | Gap — G15 |
| 115 Manual (offline package) update | P1 | Y | update_history.source = 'offline_package' | source CHECK | smoke/09_ops | Partial — G15 |
| 116 Backup before update | P1 | Y | backup_run (kind = 'pre_update', is_verified, sha256), update_history.backup_run_id (RESTRICT) | kind / status CHECK; sha256 CHECKs (M1) | smoke/09_ops, checks | Partial — G15 |
| 117 Post-update health check | P1 | Y | update_history.status | status CHECK, finished_at required when not running | smoke/09_ops | Gap — G15 (no stage checkpoint) |
| 118 Automatic rollback | P1 | Y | update_history.status = 'rolled_back' | status CHECK | smoke/09_ops | Partial — G15 |
| 119 Interruption tolerance | P1 | Y | — | — | — | Gap — G15 |
| 120 Update history | P2 | Y | update_history, installed_component | ix_update_started | smoke/09_ops | Partial — G15, N5 |
| 121 Repair and migration | P2 | Y | backup_run | — | smoke/09_ops | Partial — G14 (re-hosting) |
| 122 Clean removal (audited first) | P2 | Y | audit_log | trg_audit_log_no_delete | triggers (trg_audit_log_no_delete) | Covered (baseline) |
| 123 Unattended installer parameters | P3 | N | — | — | — | N/A |

## Appendix B — targets T1–T18

| Req | Priority | DB relevant? | Objects | Constraint/trigger | Test | Status |
|---|---|---|---|---|---|---|
| T1 Alarm latency ≤ 1 s / 2 s burst | Target | Y | event, alarm, device_state (ingest path) | minimal event indexes | — | Not measured — M12 (P1, P6) |
| T2 Control dispatch ≤ 500 ms | Target | Y | command | — | — | Gap — D4 (no dispatched_at) |
| T3 Startup | Target | Y | alarm (open), device_state | ix_alarm_open | — | Not measured — M12 |
| T4 Queries (nav < 1 s, filtered list < 2 s) | Target | Y | alarm, event, device | — | helpers.test.js (explain) | Partial — P5 (M12) |
| T5 Plans 30 fps with 1,000 devices | Target | Y | plan_placement | ux_plan_placement_* | — | Not measured — M12 |
| T6 Export 100k alarms in 60 s | Target | Y | — | — | — | Gap — G8 (M12) |
| T7 Sustained 50 events/s | Target | Y | event | — | — | Not measured — M12 (P6) |
| T8 Burst 500 events/s for 60 s, no loss | Target | Y | event | UNIQUE (gateway_hardware_id, source_event_id) | — | Not measured — M12 |
| T9 Scale (100 panels/tenants/sources, 100k devices) | Target | Y | device, controller, tenant | — | — | Not measured — M12 (G17) |
| T10 Three years of alarm history | Target | Y | event, retention_policy | — | — | Gap — D1, P2, P6 |
| T11 Continuous operation 90 days | Target | Y | WAL / checkpoint policy | — | — | Gap — P1 (checkpoint policy) |
| T12 Source loss shown within 15 s | Target | Y | — | — | — | Gap — G1 |
| T13 Accessibility | Target | N | — | — | — | N/A |
| T14 Localisation (English / Arabic) | Target | Y | reference-data names; device labels | — | — | Gap — N6, P9, G17 |
| T15 Coverage | Target | N | — (code coverage; DB triggers have negative tests, convention 12) | — | triggers.test.js | N/A |
| T16 Minimum host (256 GB SSD) | Target | Y | storage size per event | — | — | Not measured — M12 (P6) |
| T17 Desktop client | Target | N | — | — | — | N/A |
| T18 Unattended recovery ≤ 60 s | Target | Y | DB open + WAL recovery + quick_check | — | — | Not measured — M12 (P1) |

## Section 13 — Gateway Management acceptance tests G01–G12

| Req | Priority | DB relevant? | Objects | Constraint/trigger | Test | Status |
|---|---|---|---|---|---|---|
| G01 Gateway identity, resources, services, modules, freshness | GMA | Y | gateway, gateway_hardware, gateway_health (no modules or services) | — | smoke/02_sources | Gap — G3 |
| G02 Viewer read-only; scoped network changes | GMA | Y | permission, user_role (no gateway scope) | — | — | Gap — G4 |
| G03 Network change validation + timed confirm/rollback | GMA | Y | — | — | — | Gap — G3 |
| G04 Allowlisted service / OS operations only | GMA | Y | — | — | — | Gap — G3 |
| G05 Central single-use elevation (no replay, no reboot reuse) | GMA | Y | — | — | — | Gap — G3 |
| G06 Central outage / revocation / clock-fault policy | GMA | Y | — | — | — | Gap — G3 |
| G07 Module install/update/remove by authorised admin only | GMA | Y | — | — | — | Gap — G3, G4 |
| G08 Reject bad packages; recover at every lifecycle stage | GMA | Y | — | — | — | Gap — G3 |
| G09 Gateway audit sync without loss or duplication | GMA | Y | audit_log (no gateway origin or sync key) | — | — | Gap — G3, G11 |
| G10 Resource limits preserve alarm path | GMA | Y | — | — | — | Not measured — M12 |
| G11 Non-developer configuration from the guide | GMA | N | — | — | — | N/A |
| G12 Security assessment | GMA | N | — | — | — | N/A |
