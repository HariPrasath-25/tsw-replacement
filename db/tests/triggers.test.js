'use strict';
// Negative test for every trigger (CLAUDE.md convention 12). The last test fails if a trigger
// is added to the schema without a case here.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { freshDb, insert, insertFixtures, expectAbort, hex, T0 } = require('./helpers');

function setup() {
  const db = freshDb();
  const f = insertFixtures(db);
  f.otherTenantId = insert(db, 'tenant', { name: 'Other Tenant', created_at: T0 });
  f.otherSiteId = insert(db, 'site', { tenant_id: f.otherTenantId, name: 'Other Site', timezone: 'Asia/Dubai', created_at: T0 });
  f.otherSpaceId = insert(db, 'space', { site_id: f.otherSiteId, type: 'building', name: 'Other Building' });
  f.syncId = insert(db, 'command_type', { system: 'fire', code: 'sync_clock', name: 'Sync clock', target: 'controller', permission_id: f.permissionId, allow_schedule: 1 });
  f.silenceId = insert(db, 'command_type', { system: 'fire', code: 'silence', name: 'Silence', target: 'controller', permission_id: f.permissionId });
  return { db, f };
}

const schedule = (f, commandTypeId) => ({
  name: 'S', command_type_id: commandTypeId, site_id: f.siteId, controller_id: f.controllerId,
  interval_sec: 3600, created_by: f.userId, created_at: T0,
});

const TESTED = {
  trg_schedule_allowed({ db, f }) {
    insert(db, 'command_schedule', schedule(f, f.syncId)); // allowed type: OK
    expectAbort(db, `INSERT INTO command_schedule (name, command_type_id, site_id, controller_id, interval_sec, created_by, created_at)
                     VALUES ('S', ?, ?, ?, 3600, ?, ?)`, 'this command type cannot be scheduled',
    [f.silenceId, f.siteId, f.controllerId, f.userId, T0]);
  },
  trg_schedule_allowed_upd({ db, f }) {
    const id = insert(db, 'command_schedule', schedule(f, f.syncId));
    expectAbort(db, 'UPDATE command_schedule SET command_type_id = ? WHERE id = ?', 'this command type cannot be scheduled', [f.silenceId, id]);
  },
  trg_user_role_scope({ db, f }) {
    const base = `INSERT INTO user_role (user_id, role_id, tenant_id, site_id, space_id, granted_at) VALUES (?, ?, ?, ?, ?, ?)`;
    expectAbort(db, base, 'user_role scope', [f.userId, f.roleId, f.tenantId, f.otherSiteId, null, T0]); // site of another tenant
    expectAbort(db, base, 'user_role scope', [f.userId, f.roleId, f.tenantId, f.siteId, f.otherSpaceId, T0]); // space of another site
  },
  trg_user_role_scope_upd({ db, f }) {
    const id = insert(db, 'user_role', { user_id: f.userId, role_id: f.roleId, tenant_id: f.tenantId, site_id: f.siteId, granted_at: T0 });
    expectAbort(db, 'UPDATE user_role SET site_id = ? WHERE id = ?', 'user_role scope', [f.otherSiteId, id]);
  },
  trg_group_role_scope({ db, f }) {
    expectAbort(db, `INSERT INTO directory_group_role (group_sid, role_id, tenant_id, site_id) VALUES ('S-1-5-32-544', ?, ?, ?)`,
      'directory_group_role scope', [f.roleId, f.tenantId, f.otherSiteId]);
  },
  trg_audit_no_update({ db, f }) {
    const id = insert(db, 'audit_log', { at: T0, user_id: f.userId, action: 'auth.login', outcome: 'success', prev_hash: hex(64, '0'), row_hash: hex(64) });
    expectAbort(db, `UPDATE audit_log SET outcome = 'failed' WHERE id = ?`, 'audit_log is append-only', [id]);
  },
  trg_audit_no_delete({ db, f }) {
    const id = insert(db, 'audit_log', { at: T0, user_id: f.userId, action: 'auth.login', outcome: 'success', prev_hash: hex(64, '0'), row_hash: hex(64) });
    expectAbort(db, 'DELETE FROM audit_log WHERE id = ?', 'audit_log is append-only', [id]);
  },
  trg_event_no_update({ db, f }) {
    const id = insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'x', event_type: 'status', rcv_time: T0, raw_json: '{}' });
    expectAbort(db, 'UPDATE event SET is_late = 1 WHERE id = ?', 'event is append-only', [id]);
  },
};

for (const [name, fn] of Object.entries(TESTED)) {
  test(`trigger ${name} aborts on a forbidden change`, () => {
    const ctx = setup();
    try { fn(ctx); } finally { ctx.db.close(); }
  });
}

test('every trigger in the schema has a negative test here', () => {
  const db = freshDb();
  const names = db.prepare(`SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name`).all().map((r) => r.name);
  db.close();
  assert.deepEqual(names.filter((n) => !(n in TESTED)), [], 'triggers without a negative test');
  assert.deepEqual(Object.keys(TESTED).filter((n) => !names.includes(n)), [], 'tests for triggers that no longer exist');
});
