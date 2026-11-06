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
  f.syncId = insert(db, 'command_type', { system_id: f.fireSystemId, code: 'sync_clock', name: 'Sync clock', target: 'controller', permission_id: f.permissionId, can_schedule: 1 });
  f.silenceId = insert(db, 'command_type', { system_id: f.fireSystemId, code: 'silence', name: 'Silence', target: 'controller', permission_id: f.permissionId });
  return { db, f };
}

const schedule = (f, commandTypeId) => ({
  name: 'S', command_type_id: commandTypeId, site_id: f.siteId, controller_id: f.controllerId,
  interval_sec: 3600, created_by_user_account_id: f.userId, created_at: T0, updated_at: T0,
});

const TESTED = {
  // M2 (req 6): fire class identity and order are fixed; every forbidden column is tried separately.
  trg_alarm_class_fire_immutable({ db, f }) {
    const msg = 'alarm_class: fire class code/precedence/is_life_safety are fixed';
    for (const set of ['precedence = 9', `code = 'blaze'`, 'is_life_safety = 0', 'is_builtin = 0', 'system_id = 2']) {
      expectAbort(db, `UPDATE alarm_class SET ${set} WHERE id = ?`, msg, [f.fireClassId]);
    }
    // Swapping two precedences in one statement is also refused (UNIQUE would allow a careful swap).
    expectAbort(db, 'UPDATE alarm_class SET precedence = 5 - precedence WHERE id IN (?, ?)', msg, [f.fireClassId, f.troubleClassId]);
  },
  trg_alarm_class_builtin_no_delete({ db, f }) {
    expectAbort(db, 'DELETE FROM alarm_class WHERE id = ?', 'alarm_class: built-in class cannot be deleted', [f.troubleClassId]);
  },
  trg_role_builtin_no_delete({ db, f }) {
    expectAbort(db, 'DELETE FROM role WHERE id = ?', 'role: built-in role cannot be deleted', [f.roleId]);
  },
  trg_role_builtin_immutable({ db, f }) {
    for (const set of [`name = 'Admin'`, `name_key = 'role.admin'`, 'is_builtin = 0']) {
      expectAbort(db, `UPDATE role SET ${set} WHERE id = ?`, 'role: built-in role identity is fixed', [f.roleId]);
    }
  },
  trg_command_schedule_allowed({ db, f }) {
    insert(db, 'command_schedule', schedule(f, f.syncId)); // allowed type: OK
    expectAbort(db, `INSERT INTO command_schedule (name, command_type_id, site_id, controller_id, interval_sec, created_by_user_account_id, created_at, updated_at)
                     VALUES ('S', ?, ?, ?, 3600, ?, ?, ?)`, 'this command type cannot be scheduled',
    [f.silenceId, f.siteId, f.controllerId, f.userId, T0, T0]);
  },
  trg_command_schedule_allowed_upd({ db, f }) {
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
  trg_directory_group_role_scope({ db, f }) {
    expectAbort(db, `INSERT INTO directory_group_role (group_sid, role_id, tenant_id, site_id, created_at, updated_at) VALUES ('S-1-5-32-544', ?, ?, ?, ?, ?)`,
      'directory_group_role scope', [f.roleId, f.tenantId, f.otherSiteId, T0, T0]);
  },
  trg_audit_log_no_update({ db, f }) {
    const id = insert(db, 'audit_log', { at: T0, user_id: f.userId, action: 'auth.login', outcome: 'success', prev_hash: hex(64, '0'), row_hash: hex(64) });
    expectAbort(db, `UPDATE audit_log SET outcome = 'failed' WHERE id = ?`, 'audit_log is append-only', [id]);
  },
  trg_audit_log_no_delete({ db, f }) {
    const id = insert(db, 'audit_log', { at: T0, user_id: f.userId, action: 'auth.login', outcome: 'success', prev_hash: hex(64, '0'), row_hash: hex(64) });
    expectAbort(db, 'DELETE FROM audit_log WHERE id = ?', 'audit_log is append-only', [id]);
  },
  trg_schema_version_no_update({ db }) {
    expectAbort(db, `UPDATE schema_version SET description = 'x' WHERE module = '00_header'`, 'schema_version: append-only');
  },
  trg_schema_version_no_delete({ db }) {
    expectAbort(db, `DELETE FROM schema_version WHERE module = '00_header'`, 'schema_version: append-only');
  },
  trg_event_no_update({ db, f }) {
    const id = insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'x', event_type: 'status', rcv_time: T0, raw_json: '{}' });
    expectAbort(db, 'UPDATE event SET is_late = 1 WHERE id = ?', 'event is append-only', [id]);
  },

  // M3 (D6, req 30): space hierarchy. Deeper cases (cycles, moves, oracle) are in tenancy.test.js.
  trg_space_hierarchy_ins({ db, f }) {
    const ins = 'INSERT INTO space (id, site_id, parent_space_id, type, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)';
    expectAbort(db, ins, 'space: parent must be in the same site', [null, f.otherSiteId, f.floorId, 'zone', 'Z', T0, T0]);
    expectAbort(db, ins, 'space: a space cannot be its own parent', [999, f.siteId, 999, 'zone', 'Z', T0, T0]);
    expectAbort(db, ins, 'space: type not allowed under this parent type', [null, f.siteId, f.floorId, 'building', 'B', T0, T0]);
    expectAbort(db, ins, 'space: type not allowed under this parent type', [null, f.siteId, null, 'floor', 'F', T0, T0]); // floor at root
    let parent = f.floorId; // depth 1; zones nest under zones up to depth 7
    for (let d = 2; d <= 7; d++) parent = insert(db, 'space', { site_id: f.siteId, parent_space_id: parent, type: 'zone', name: `Z${d}` });
    expectAbort(db, ins, 'space: maximum depth is 8 levels', [null, f.siteId, parent, 'zone', 'Z8', T0, T0]);
  },
  trg_space_hierarchy_upd({ db, f }) {
    const zoneId = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Z' });
    expectAbort(db, 'UPDATE space SET parent_space_id = ? WHERE id = ?', 'space: parent must be in the same site', [f.otherSpaceId, zoneId]);
    expectAbort(db, 'UPDATE space SET parent_space_id = ? WHERE id = ?', 'space: cycle', [zoneId, f.buildingId]);
    expectAbort(db, 'UPDATE space SET parent_space_id = id WHERE id = ?', 'space: cycle', [zoneId]);
    expectAbort(db, `UPDATE space SET type = 'room' WHERE id = ?`, 'space: type not allowed under this parent type', [f.floorId]);
    expectAbort(db, `UPDATE space SET type = 'building' WHERE id = ?`, 'space: type not allowed under this parent type', [zoneId]);
    insert(db, 'space', { site_id: f.siteId, parent_space_id: zoneId, type: 'zone', name: 'ZZ' });
    expectAbort(db, `UPDATE space SET type = 'room' WHERE id = ?`, 'space: an existing child type is not allowed under the new type', [zoneId]);
  },
  trg_space_site_immutable({ db, f }) {
    expectAbort(db, 'UPDATE space SET site_id = ? WHERE id = ?', 'space: site_id cannot change', [f.siteId, f.otherSpaceId]);
  },
  trg_space_depth_derived({ db, f }) {
    expectAbort(db, 'UPDATE space SET depth = 3 WHERE id = ?', 'space: depth is trigger-maintained', [f.floorId]);
    db.prepare('UPDATE space SET depth = 1 WHERE id = ?').run(f.floorId); // the derived value is accepted
  },
  trg_space_closure_ins({ db, f }) {
    // Maintenance trigger: a valid insert writes the self row + one row per ancestor; a refused insert writes nothing.
    const n0 = db.prepare('SELECT count(*) AS n FROM space_closure').get().n;
    const z = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Z' });
    assert.deepEqual(db.prepare('SELECT ancestor_space_id AS a, depth FROM space_closure WHERE descendant_space_id = ? ORDER BY depth').all(z),
      [{ a: z, depth: 0 }, { a: f.floorId, depth: 1 }, { a: f.buildingId, depth: 2 }]);
    expectAbort(db, `INSERT INTO space (site_id, parent_space_id, type, name, created_at, updated_at) VALUES (?, ?, 'building', 'B', ?, ?)`,
      'space: type not allowed', [f.siteId, z, T0, T0]);
    assert.equal(db.prepare('SELECT count(*) AS n FROM space_closure').get().n, n0 + 3);
  },
  trg_space_closure_move({ db, f }) {
    // Maintenance trigger: a refused move leaves the closure untouched; a valid move relinks the subtree.
    const b2 = insert(db, 'space', { site_id: f.siteId, type: 'building', name: 'Tower B' });
    const before = db.prepare('SELECT * FROM space_closure ORDER BY 1, 2').all();
    expectAbort(db, 'UPDATE space SET parent_space_id = ? WHERE id = ?', 'space: cycle', [f.floorId, f.buildingId]);
    assert.deepEqual(db.prepare('SELECT * FROM space_closure ORDER BY 1, 2').all(), before);
    db.prepare('UPDATE space SET parent_space_id = ? WHERE id = ?').run(b2, f.floorId);
    assert.deepEqual(db.prepare('SELECT ancestor_space_id AS a FROM space_closure WHERE descendant_space_id = ? ORDER BY depth').all(f.floorId).map((r) => r.a), [f.floorId, b2]);
  },

  // M3 (G7, req 39): floor plan revisions
  trg_floor_plan_revision_ins({ db, f }) {
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    expectAbort(db, planSql, 'floor_plan: a new revision must be draft or current', planArgs(f, 2, 'superseded', cur, '2'));
    expectAbort(db, planSql, 'floor_plan: revision_no must be the next number', planArgs(f, 3, 'draft', cur, '2'));
    expectAbort(db, planSql, 'floor_plan: a space has one current plan', planArgs(f, 2, 'current', cur, '2'));
    expectAbort(db, planSql, 'floor_plan: replaces_floor_plan_id must be the current plan', planArgs(f, 2, 'draft', null, '2'));
  },
  trg_floor_plan_status({ db, f }) {
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    const set = 'UPDATE floor_plan SET status = ? WHERE id = ?';
    expectAbort(db, set, 'floor_plan: status transition not allowed', ['draft', cur]);
    expectAbort(db, set, 'floor_plan: only a plan with a pending draft replacing it can be superseded', ['superseded', cur]);
    const draft = insert(db, 'floor_plan', plan(f, 2, 'draft', cur, '2'));
    expectAbort(db, set, 'floor_plan: supersede the replaced plan before promoting the draft', ['current', draft]);
    insert(db, 'plan_placement', { floor_plan_id: draft, device_id: f.deviceId, x: 0.5, y: 0.5, status: 'needs_review', placed_at: T0 });
    db.prepare(set).run('superseded', cur);
    expectAbort(db, set, 'floor_plan: placements still need review', ['current', draft]);
    expectAbort(db, set, 'floor_plan: status transition not allowed', ['current', cur]); // superseded is final
  },
  trg_floor_plan_content_immutable({ db, f }) {
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    for (const s of [`sha256 = '${hex(64, 'c')}'`, `storage_path = 'x'`, 'width_px = 11', 'revision_no = 5', `file_name = 'y.png'`]) {
      expectAbort(db, `UPDATE floor_plan SET ${s} WHERE id = ?`, 'floor_plan: revision content is immutable', [cur]);
    }
  },

  // M3 (D6, G7): placements
  trg_plan_placement_ins({ db, f }) {
    const o = otherSiteSources(db, f);
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    const ins = 'INSERT INTO plan_placement (floor_plan_id, device_id, controller_id, gateway_id, x, y, status, placed_at, created_at, updated_at) VALUES (?, ?, ?, ?, 0.5, 0.5, ?, ?, ?, ?)';
    expectAbort(db, ins, "plan_placement: target not in plan's site", [cur, o.deviceId, null, null, 'placed', T0, T0, T0]);
    expectAbort(db, ins, "plan_placement: target not in plan's site", [cur, null, o.controllerId, null, 'placed', T0, T0, T0]);
    expectAbort(db, ins, "plan_placement: target not in plan's site", [cur, null, null, o.gatewayId, 'placed', T0, T0, T0]);
    expectAbort(db, ins, 'plan_placement: needs_review only on a draft revision', [cur, f.deviceId, null, null, 'needs_review', T0, T0, T0]);
    const draft = insert(db, 'floor_plan', plan(f, 2, 'draft', cur, '2'));
    db.prepare(`UPDATE floor_plan SET status = 'rejected' WHERE id = ?`).run(draft);
    expectAbort(db, ins, 'plan_placement: plan revision is frozen', [draft, f.deviceId, null, null, 'placed', T0, T0, T0]);
  },
  trg_plan_placement_upd({ db, f }) {
    const o = otherSiteSources(db, f);
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    const p = insert(db, 'plan_placement', { floor_plan_id: cur, device_id: f.deviceId, x: 0.5, y: 0.5, placed_at: T0 });
    expectAbort(db, 'UPDATE plan_placement SET device_id = ? WHERE id = ?', "plan_placement: target not in plan's site", [o.deviceId, p]);
    expectAbort(db, `UPDATE plan_placement SET status = 'needs_review' WHERE id = ?`, 'plan_placement: needs_review only on a draft revision', [p]);
    const draft = insert(db, 'floor_plan', plan(f, 2, 'draft', cur, '2'));
    expectAbort(db, 'UPDATE plan_placement SET floor_plan_id = ? WHERE id = ?', 'plan_placement: a placement cannot move to another plan revision', [draft, p]);
    db.prepare(`UPDATE floor_plan SET status = 'superseded' WHERE id = ?`).run(cur);
    expectAbort(db, 'UPDATE plan_placement SET x = 0.1 WHERE id = ?', 'plan_placement: plan revision is frozen', [p]);
  },
  trg_plan_placement_del({ db, f }) {
    const cur = insert(db, 'floor_plan', plan(f, 1, 'current', null, '1'));
    const p = insert(db, 'plan_placement', { floor_plan_id: cur, device_id: f.deviceId, x: 0.5, y: 0.5, placed_at: T0 });
    insert(db, 'floor_plan', plan(f, 2, 'draft', cur, '2'));
    db.prepare(`UPDATE floor_plan SET status = 'superseded' WHERE id = ?`).run(cur);
    expectAbort(db, 'DELETE FROM plan_placement WHERE id = ?', 'plan_placement: plan revision is frozen', [p]);
  },
};

// floor_plan row for the fixture floor (M3 trigger cases)
const plan = (f, revision_no, status, replaces, h) => ({
  space_id: f.floorId, revision_no, status, replaces_floor_plan_id: replaces, file_name: `r${revision_no}.png`, mime_type: 'image/png',
  width_px: 100, height_px: 100, size_bytes: 10, sha256: hex(64, h), storage_path: `p/r${revision_no}`, uploaded_at: T0,
});
const planSql = `INSERT INTO floor_plan (space_id, revision_no, status, replaces_floor_plan_id, file_name, mime_type, width_px, height_px,
                 size_bytes, sha256, storage_path, uploaded_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'image/png', 100, 100, 10, ?, ?, ?, ?, ?)`;
const planArgs = (f, revision_no, status, replaces, h) => [f.floorId, revision_no, status, replaces, `r${revision_no}.png`, hex(64, h), `p/r${revision_no}`, T0, T0, T0];

/** A gateway > controller > device chain in the other site (cross-site placement cases). */
function otherSiteSources(db, f) {
  const gatewayId = insert(db, 'gateway', { site_id: f.otherSiteId, name: 'GW-X', created_at: T0 });
  const controllerId = insert(db, 'controller', { gateway_id: gatewayId, protocol_id: f.simplexProtocolId, ref: '9', name: 'FACP X', vendor_id: f.simplexVendorId });
  const deviceId = insert(db, 'device', { controller_id: controllerId, address: 'L9-M9', address_json: '{"loop":9,"point":"M9"}', device_type_id: f.deviceTypeId, created_at: T0 });
  return { gatewayId, controllerId, deviceId };
}

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
