'use strict';
// Negative test for every CHECK added since Draft v2 (M1 acceptance; CLAUDE.md working rule:
// "Every CHECK has a failing-insert test"). For each table there is one valid row; each case inserts
// that row with one column broken and expects SQLite's "CHECK constraint failed: <expr>" for exactly
// the CHECK under test. Most cases are generated from the CHECK's shape (time > 0, booleans, JSON,
// sha256); the rest are listed by hand. The last test fails if a CHECK that is new since Draft v2
// has no failing case here.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { freshDb, insert, insertFixtures, hex, T0 } = require('./helpers');
const { buildFromFile, REFERENCE_FILE } = require('../tools/lib/schema');
const { checkExpressions, stripComments } = require('../tools/lib/sql');

const norm = (s) => s.replace(/\s+/g, ' ').trim();
const UUID = '00000000-0000-4000-8000-0000000000aa';

/** Parent rows the valid rows below point at. */
function setup() {
  const db = freshDb();
  const f = insertFixtures(db);
  f.alarmClassId = f.fireClassId; // seeded
  f.bmsSystemId = db.prepare(`SELECT id FROM system WHERE code = 'bms'`).get().id;
  f.eventId = insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'e1', event_type: 'alarm', alarm_class_id: f.alarmClassId, rcv_time: T0, raw_json: '{}' });
  f.keyId = insert(db, 'telemetry_key', { code: 'sensitivity', name: 'Sensitivity', value_kind: 'numeric', storage_mode: 'on_change' });
  f.schedTypeId = insert(db, 'command_type', { system_id: f.fireSystemId, code: 'sync_clock', name: 'Sync', target: 'controller', permission_id: f.permissionId, can_schedule: 1 });
  f.scheduleId = insert(db, 'command_schedule', { name: 'S', command_type_id: f.schedTypeId, site_id: f.siteId, controller_id: f.controllerId, interval_sec: 3600, created_by_user_account_id: f.userId });
  f.floorPlanId = insert(db, 'floor_plan', { space_id: f.floorId, revision_no: 1, status: 'current', file_name: 'a.png', mime_type: 'image/png', width_px: 10, height_px: 10, size_bytes: 10, sha256: hex(64), storage_path: 'a', uploaded_at: T0 });
  return { db, f };
}

/** One valid row per table that has CHECKs new since Draft v2. */
const VALID = {
  schema_version: () => ({ version: 9, module: 'm9', checksum: hex(64), applied_at: T0, applied_by: 'test', description: 'd' }),
  tenant: () => ({ name: 'T2', status: 'archived', archived_at: T0, updated_by_user_account_id: null }),
  site: (f) => ({ tenant_id: f.tenantId, name: 'S2', timezone: 'UTC', status: 'archived', archived_at: T0 }),
  space_type_rule: () => ({ parent_type: 'room', child_type: 'room' }),
  space: (f) => ({ site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Z' }),
  space_closure: (f) => ({ ancestor_space_id: f.floorId, descendant_space_id: f.buildingId, depth: 1 }), // CHECK-only row
  floor_plan: (f) => ({ space_id: f.floorId, revision_no: 2, replaces_floor_plan_id: f.floorPlanId, status: 'draft', status_changed_at: T0, file_name: 'b.png', mime_type: 'image/png', width_px: 10, height_px: 10, size_bytes: 10, sha256: hex(64, 'b'), storage_path: 'b', uploaded_at: T0 }),
  plan_placement: (f) => ({ floor_plan_id: f.floorPlanId, device_id: f.deviceId, x: 0.5, y: 0.5, rotation_deg: 90, placed_at: T0 }),
  system: () => ({ code: 's2', name: 'S2', name_key: 'system.s2' }),
  vendor: () => ({ name: 'Notifier' }),
  protocol: () => ({ code: 'p2', name: 'P2', name_key: 'protocol.p2' }),
  device_state_code: () => ({ code: 'x2', precedence: 50, is_alarm: 0, name_key: 'device_state.x2' }),
  condition: () => ({ code: 'c2', raw_name: 'C2', is_reported_unknown: 0, name_key: 'condition.c2' }),
  gateway: (f) => ({ site_id: f.siteId, name: 'GW-2', last_heartbeat: T0 }),
  gateway_hardware: (f) => ({ gateway_id: f.gatewayId, serial: 'SER-2', installed_at: T0, removed_at: T0 + 1 }),
  controller: (f) => ({ gateway_id: f.gatewayId, protocol_id: f.simplexProtocolId, ref: '2', name: 'FACP 2', last_contact: T0 }),
  device_category: () => ({ code: 'c2', name: 'C2', name_key: 'device_category.c2' }),
  device_type: (f) => ({ code: 't2', device_category_id: f.detectorCategoryId, name: 'T2', name_key: 'device_type.t2' }),
  vendor_type_map: (f) => ({ vendor_id: f.simplexVendorId, vendor_type: 'HEAT', device_type_id: f.deviceTypeId }),
  device: (f) => ({ controller_id: f.controllerId, address: 'L1-M2' }),
  device_hardware: (f) => ({ device_id: f.deviceId, controller_id: f.controllerId, address: 'L1-M1', installed_at: T0, removed_at: T0 + 1 }),
  device_state: (f) => ({ device_id: f.deviceId, analog_json: '{}', updated_src_time: T0, updated_rcv_time: T0, last_seen_at: T0 }),
  device_state_history: (f) => ({ device_id: f.deviceId, old_states_json: '["normal"]', new_states_json: '["trouble"]', new_primary_state: 'trouble', src_time: T0, rcv_time: T0 }),
  alarm_class: (f) => ({ system_id: f.bmsSystemId, code: 'high_temp', name: 'High temperature', name_key: 'alarm_class.bms.high_temp', precedence: 1 }),
  event: (f) => ({ gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'v1', event_type: 'status', src_time: T0, rcv_time: T0, raw_json: '{}' }),
  alarm: (f) => ({ raised_event_id: f.eventId, site_id: f.siteId, alarm_class_id: f.alarmClassId, precedence: 1, raised_at: T0, acked_at: T0, cleared_at: T0 }),
  telemetry_key: () => ({ code: 'k2', name: 'K2', name_key: 'telemetry_key.k2', value_kind: 'numeric', storage_mode: 'interval', interval_sec: 60, decimals: 2, raw_keep_days: 10, rollup_keep_days: 10 }),
  device_type_telemetry: (f) => ({ device_type_id: f.deviceTypeId, telemetry_key_id: f.keyId, interval_sec: 60 }),
  vendor_key_map: (f) => ({ vendor_id: f.simplexVendorId, raw_key: 'r', telemetry_key_id: f.keyId, enum_map_json: '{}' }),
  telemetry: (f) => ({ device_id: f.deviceId, telemetry_key_id: f.keyId, ts: T0, value: 1 }),
  gateway_telemetry: (f) => ({ gateway_id: f.gatewayId, telemetry_key_id: f.keyId, ts: T0, value: 1 }),
  telemetry_rollup: (f) => ({ source_kind: 'device', source_id: f.deviceId, telemetry_key_id: f.keyId, period: 'hour', period_ts: T0, samples: 1 }),
  command_type: (f) => ({ system_id: f.fireSystemId, code: 'c3', name: 'C3', name_key: 'command_type.c3', target: 'device', permission_id: f.permissionId, expiry_sec: 30 }),
  command_schedule: (f) => ({
    name: 'S2', command_type_id: f.schedTypeId, site_id: f.siteId, controller_id: f.controllerId, interval_sec: 3600,
    window_start: '01:00', window_end: '05:00', last_run_at: T0, next_run_at: T0, params_json: '{}', created_by_user_account_id: f.userId,
  }),
  schedule_run: (f) => ({ command_schedule_id: f.scheduleId, due_at: T0, started_at: T0, finished_at: T0, status: 'done' }),
  command: (f) => ({
    correlation_id: UUID, user_id: f.userId, command_type_id: f.schedTypeId, controller_id: f.controllerId, status: 'success',
    requested_at: T0, expires_at: T0 + 1, completed_at: T0 + 1, raw_json: '{}',
  }),
  user_account: () => ({ username: 'u2', display_name: 'U2', auth_type: 'windows', locked_until: T0 }),
  role: () => ({ name: 'R2', name_key: 'role.r2', is_builtin: 1 }),
  permission: () => ({ code: 'gateway.p2', domain: 'gateway', description: 'P2', name_key: 'permission.p2', is_central_grant_required: 1 }),
  user_role: (f) => ({ user_id: f.userId, role_id: f.roleId, tenant_id: f.tenantId, granted_at: T0 }),
  directory_group_role: (f) => ({ group_sid: 'S-1-5-21-9', role_id: f.roleId, tenant_id: f.tenantId }),
  session: (f) => ({ user_id: f.userId, token_hash: hex(64), client_kind: 'web', started_at: T0, last_activity: T0, ended_at: T0, end_reason: 'logout' }),
  audit_log: () => ({ at: T0, action: 'a', outcome: 'success', before_json: '{}', after_json: '{}', prev_hash: hex(64, '0'), row_hash: hex(64) }),
  quarantine: () => ({ topic: 't', payload: Buffer.from('x'), error: 'e', rcv_time: T0, reviewed_at: T0 }),
  gateway_health: (f) => ({ gateway_id: f.gatewayId, rcv_time: T0, detail_json: '{}' }),
  setting: () => ({ key: 'k', value_json: '1' }),
  retention_policy: () => ({ data_type: 'telemetry', keep_days: 30, min_days: 7 }),
  retention_run: () => ({ data_type: 'event', started_at: T0, finished_at: T0, cutoff_time: T0, archive_sha256: hex(64), status: 'done' }),
  backup_run: () => ({ kind: 'manual', started_at: T0, finished_at: T0, target_path: 'p', sha256: hex(64), status: 'done' }),
  installed_component: () => ({ component: 'service', version: '1', detail_json: '{}', updated_at: T0 }),
  update_history: () => ({ from_version: '1', to_version: '2', package_sha256: hex(64), manifest_json: '{}', source: 'online', started_at: T0, finished_at: T0, status: 'succeeded' }),
  licence: () => ({ licence_key_enc: Buffer.from([1]), entitlements_json: '{}', activated_at: T0, activation_mode: 'online' }),
  document_acceptance: (f) => ({ user_id: f.userId, document: 'terms', doc_version: '1', accepted_at: T0 }),
};

// Extra fields a generated case needs so that only the CHECK under test fails.
const CONTEXT = {
  'command_schedule.target_filter_json': { controller_id: null },
};

/** Broken values implied by the shape of a CHECK expression (one or more patches, or none). */
function generatedPatches(expr) {
  let m;
  if ((m = /^(\w+) > 0$/.exec(expr))) return [{ [m[1]]: 0 }, { [m[1]]: -1 }];
  if ((m = /^(\w+) >= 1$/.exec(expr))) return [{ [m[1]]: 0 }];
  if ((m = /^(\w+) >= 0$/.exec(expr))) return [{ [m[1]]: -1 }];
  if ((m = /^(\w+) IN \(0,1\)$/.exec(expr))) return [{ [m[1]]: 2 }];
  if ((m = /json_valid\((\w+)\)/.exec(expr))) {
    const c = m[1], ps = [{ [c]: 'not json' }];
    if (/json_type\(\w+\) = 'object'/.test(expr)) ps.push({ [c]: '[]' });
    if (/json_type\(\w+\) = 'array'/.test(expr)) ps.push({ [c]: '{}' });
    return ps;
  }
  if ((m = /^length\((\w+)\) = 64 AND \1 NOT GLOB/.exec(expr))) return [{ [m[1]]: hex(63) }, { [m[1]]: hex(64, 'A') }, { [m[1]]: hex(64, 'g') }];
  // Lowercase dotted keys (name_key, permission.code; M2): uppercase, bad character, leading digit.
  // Values keep the 'gateway.' prefix so permission's domain/prefix CHECK is not the one that fails.
  if ((m = /^(\w+) GLOB '\[a-z\]\*' AND \1 NOT GLOB '\*\[\^a-z0-9\._\]\*'$/.exec(expr))) {
    return [{ [m[1]]: 'gateway.X' }, { [m[1]]: 'gateway.a-b' }, { [m[1]]: '9gateway.x' }];
  }
  return [];
}

// Hand-written cases for CHECKs whose shape the generator does not cover.
const MANUAL = [
  // M3
  ['tenant', { status: 'closed', archived_at: null }], ['tenant', { archived_at: null }], ['tenant', { status: 'active' }],
  ['site', { status: 'closed', archived_at: null }], ['site', { archived_at: null }], ['site', { status: 'suspended' }],
  ['space_type_rule', { parent_type: 'wing' }], ['space_type_rule', { child_type: 'wing' }],
  ['space', { depth: 8 }], ['space', { depth: -1 }],
  ['space_closure', { depth: 8 }], ['space_closure', { depth: -1 }],
  ['floor_plan', { status: 'archived' }],
  ['plan_placement', { status: 'moved' }],
  ['plan_placement', { rotation_deg: 360 }], ['plan_placement', { rotation_deg: -0.5 }],
  ['telemetry_key', { decimals: 7 }], ['telemetry_key', { decimals: -1 }],
  ['command_schedule', { window_start: '24:00' }], ['command_schedule', { window_start: '7:00' }],
  ['command_schedule', { window_end: '12:60' }], ['command_schedule', { window_end: 'noon!' }],
  ['command_schedule', { window_end: null }], // both-or-neither
  ['command', { correlation_id: UUID.toUpperCase() }],
  ['command', { correlation_id: UUID.slice(0, 35) }],
  ['command', { correlation_id: UUID.replace(/-/g, 'x') }],
  ['session', { ended_at: null }], ['session', { end_reason: null }],
  ['retention_run', { data_type: 'technical' }],
  ['command_type', { can_schedule: 1, pin_policy: 'always' }], // renamed column (was allow_schedule)
  // M2
  ['vendor_type_map', { vendor_type: 'Heat' }], ['vendor_type_map', { vendor_type: ' HEAT' }],
  ['condition', { code: null }], ['condition', { name_key: null }],   // known conditions need code + name_key
  ['role', { name_key: null }],                                        // built-in roles are translated
  ['permission', { domain: 'admin' }],
  ['permission', { domain: 'fire', is_central_grant_required: 0 }],    // gateway.* code outside the gateway domain
  ['permission', { code: 'panel.x', domain: 'gateway', is_central_grant_required: 0 }], // gateway domain without prefix
  ['permission', { code: 'panel.x', domain: 'fire' }],                 // central grant on a non-gateway permission
];

const hits = new Set(); // "<table>: <expr>" of every CHECK a case made fail

/** Insert valid row + patch inside a savepoint; expect a CHECK failure; return the failed expression. */
function failing(db, f, table, patch) {
  const row = { ...VALID[table](f), ...patch };
  db.exec('SAVEPOINT c');
  try {
    assert.throws(() => insert(db, table, row), /CHECK constraint failed: /, `${table} ${JSON.stringify(patch)} was accepted`);
    try { insert(db, table, row); } catch (e) {
      const expr = norm(e.message.replace(/^CHECK constraint failed: /, ''));
      hits.add(`${table}: ${expr}`);
      return expr;
    }
  } finally { db.exec('ROLLBACK TO c'); db.exec('RELEASE c'); }
  return null;
}

/** CHECK expressions per table in a database ({table: [expr]}). */
function checksByTable(db) {
  const out = {};
  for (const { name, sql } of db.prepare(`SELECT name, sql FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`).all()) {
    out[name] = checkExpressions(stripComments(sql)).map(norm);
  }
  return out;
}

test('every valid row is accepted (so each negative case isolates one CHECK)', () => {
  const { db, f } = setup();
  try {
    for (const [table, make] of Object.entries(VALID)) {
      db.exec('SAVEPOINT v');
      try { insert(db, table, make(f)); } catch (e) { assert.fail(`${table}: valid row rejected: ${e.message}`); }
      finally { db.exec('ROLLBACK TO v'); db.exec('RELEASE v'); }
    }
  } finally { db.close(); }
});

test('generated cases: each breaks exactly the CHECK it was generated from', () => {
  const { db, f } = setup();
  try {
    const checks = checksByTable(db);
    for (const table of Object.keys(VALID)) {
      for (const expr of checks[table] || []) {
        for (const patch of generatedPatches(expr)) {
          const col = Object.keys(patch)[0];
          const got = failing(db, f, table, { ...(CONTEXT[`${table}.${col}`] || {}), ...patch });
          assert.equal(got, expr, `${table} ${JSON.stringify(patch)} failed a different CHECK`);
        }
      }
    }
  } finally { db.close(); }
});

test('hand-written cases fail a CHECK', () => {
  const { db, f } = setup();
  try {
    for (const [table, patch] of MANUAL) assert.ok(failing(db, f, table, patch), `${table} ${JSON.stringify(patch)}`);
  } finally { db.close(); }
});

test('every CHECK new since Draft v2 has a failing-insert case', () => {
  const ref = buildFromFile(REFERENCE_FILE);
  const db = freshDb();
  const before = checksByTable(ref);
  const after = checksByTable(db);
  ref.close(); db.close();
  const untested = [];
  for (const [table, exprs] of Object.entries(after)) {
    for (const expr of exprs) {
      if ((before[table] || []).includes(expr)) continue; // unchanged since Draft v2
      if (!hits.has(`${table}: ${expr}`)) untested.push(`${table}: ${expr}`);
    }
  }
  assert.deepEqual(untested, [], 'new CHECKs without a negative test');
});
