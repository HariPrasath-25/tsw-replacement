'use strict';
// M3: tenancy, space hierarchy, closure table, floor plan revisions (D6, G7, G11, P9;
// req 29, 30, 35, 39, 54, 55, 59). Single-trigger negatives live in triggers.test.js.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { freshDb, insert, insertFixtures, expectAbort, explain, assertNoScan, hex, T0 } = require('./helpers');
const { stripComments } = require('../tools/lib/sql');

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/** Deterministic PRNG (mulberry32) so the random tree is the same on every run. */
function prng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Closure computed independently of the triggers: recursive CTE over space.parent_space_id. */
const ORACLE = `
  WITH RECURSIVE o(a, d, depth) AS (
    SELECT id, id, 0 FROM space
    UNION ALL
    SELECT o.a, s.id, o.depth + 1 FROM o JOIN space s ON s.parent_space_id = o.d)
  SELECT a, d, depth FROM o ORDER BY a, d`;
const CLOSURE = 'SELECT ancestor_space_id AS a, descendant_space_id AS d, depth FROM space_closure ORDER BY a, d';

function assertClosureMatchesOracle(db) {
  const oracle = db.prepare(ORACLE).all();
  const closure = db.prepare(CLOSURE).all();
  assert.equal(closure.length, oracle.length, 'closure row count differs from the oracle');
  assert.deepEqual(closure, oracle, 'closure differs from the recursive CTE oracle');
  const badDepth = db.prepare(`
    SELECT s.id, s.depth, (SELECT max(depth) FROM (${ORACLE}) WHERE d = s.id) AS want
      FROM space s WHERE s.depth IS NOT (SELECT max(depth) FROM (${ORACLE}) WHERE d = s.id)`).all();
  assert.deepEqual(badDepth, [], 'space.depth differs from the oracle depth');
}

/** Named SQL blocks from docs/db/PLAN_REPLACEMENT.md (```sql name=<block>). */
const DOC = fs.readFileSync(path.resolve(__dirname, '../../docs/db/PLAN_REPLACEMENT.md'), 'utf8');
const BLOCKS = Object.fromEntries([...DOC.matchAll(/```sql name=([\w-]+)\r?\n([\s\S]*?)```/g)].map((m) => [m[1], m[2]]));

/** Run a doc block as the service would: BEGIN IMMEDIATE, statements in order, ROLLBACK on error. Returns changes per statement. */
function runBlock(db, name, params) {
  assert.ok(BLOCKS[name], `PLAN_REPLACEMENT.md has no block ${name}`);
  const stmts = stripComments(BLOCKS[name]).split(';').map((s) => s.trim()).filter(Boolean);
  db.exec('BEGIN IMMEDIATE');
  try {
    const changes = stmts.map((s) => db.prepare(s).run(params).changes);
    db.exec('COMMIT');
    return changes;
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}

const upload = (f, n, extra = {}) => ({
  space_id: f.floorId, file_name: `f16-r${n}.png`, mime_type: 'image/png', width_px: 4000 + n, height_px: 3000,
  size_bytes: 1000 + n, sha256: hex(64, String(n % 10)), storage_path: `plans/f16-r${n}.png`, user_id: f.userId, now: T0 + n, ...extra,
});
const planRow = (db, id) => db.prepare('SELECT id, revision_no, replaces_floor_plan_id, status, is_current, row_version FROM floor_plan WHERE id = ?').get(id);
const draftOf = (db, spaceId) => db.prepare(`SELECT id, row_version FROM floor_plan WHERE space_id = ? AND status = 'draft'`).get(spaceId);
const currentOf = (db, spaceId) => db.prepare(`SELECT id FROM floor_plan WHERE space_id = ? AND status = 'current'`).get(spaceId);
const placements = (db, planId) => db.prepare(`SELECT device_id, controller_id, gateway_id, x, y, rotation_deg, status, row_version
                                                 FROM plan_placement WHERE floor_plan_id = ? ORDER BY id`).all(planId);

// ---------------------------------------------------------------------------------------------
// Sites (req 54)
// ---------------------------------------------------------------------------------------------

test('req 54: a suspended or archived site still ingests events (access-only suspension)', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    db.prepare(`UPDATE site SET status = 'suspended' WHERE id = ?`).run(f.siteId);
    db.prepare(`UPDATE tenant SET status = 'archived', archived_at = ? WHERE id = ?`).run(T0, f.tenantId);
    insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 's1', event_type: 'alarm', alarm_class_id: f.fireClassId, rcv_time: T0, raw_json: '{}' });
    db.prepare(`UPDATE site SET status = 'archived', archived_at = ? WHERE id = ?`).run(T0, f.siteId);
    insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 's2', event_type: 'alarm', alarm_class_id: f.fireClassId, rcv_time: T0 + 1, raw_json: '{}' });
    assert.equal(db.prepare('SELECT count(*) AS n FROM event').get().n, 2);
  } finally { db.close(); }
});

// ---------------------------------------------------------------------------------------------
// Space hierarchy (D6, req 30)
// ---------------------------------------------------------------------------------------------

test('D6: cross-site parent is refused on insert and on move', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const s2 = insert(db, 'site', { tenant_id: f.tenantId, name: 'Site 2', timezone: 'UTC' });
    const b2 = insert(db, 'space', { site_id: s2, type: 'building', name: 'B2' });
    expectAbort(db, `INSERT INTO space (site_id, parent_space_id, type, name, created_at, updated_at) VALUES (?, ?, 'floor', 'F', ?, ?)`,
      'space: parent must be in the same site', [f.siteId, b2, T0, T0]);
    expectAbort(db, 'UPDATE space SET parent_space_id = ? WHERE id = ?', 'space: parent must be in the same site', [b2, f.floorId]);
  } finally { db.close(); }
});

test('D6: cycles are refused (self, direct child, deep descendant) and leave the tree unchanged', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    let parent = f.floorId;
    const chain = [];
    for (let i = 0; i < 5; i++) chain.push((parent = insert(db, 'space', { site_id: f.siteId, parent_space_id: parent, type: 'zone', name: `Z${i}` })));
    const before = db.prepare(CLOSURE).all();
    const move = 'UPDATE space SET parent_space_id = ? WHERE id = ?';
    expectAbort(db, move, 'space: cycle', [chain[0], chain[0]]);           // self
    expectAbort(db, move, 'space: cycle', [chain[1], chain[0]]);           // direct child
    expectAbort(db, move, 'space: cycle', [chain[4], chain[0]]);           // deep descendant
    expectAbort(db, move, 'space: cycle', [chain[4], f.buildingId]);       // root under its own leaf
    assert.deepEqual(db.prepare(CLOSURE).all(), before);
    assertClosureMatchesOracle(db);
  } finally { db.close(); }
});

test('req 30: at least three levels; a move that pushes the subtree past depth 7 is refused', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const zone = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Zone A' });
    const room = insert(db, 'space', { site_id: f.siteId, parent_space_id: zone, type: 'room', name: 'Room 1' });
    assert.equal(db.prepare('SELECT depth FROM space WHERE id = ?').get(room).depth, 3); // building > floor > zone > room

    // a second building with a subtree of height 5 (depth 0..5)
    const b2 = insert(db, 'space', { site_id: f.siteId, type: 'building', name: 'B2' });
    let p = insert(db, 'space', { site_id: f.siteId, parent_space_id: b2, type: 'zone', name: 'B2Z1' });
    const b2top = p;
    for (let i = 2; i <= 5; i++) p = insert(db, 'space', { site_id: f.siteId, parent_space_id: p, type: 'zone', name: `B2Z${i}` });
    // b2top (height 4 below it) under zone (depth 2): new depth 3 + 4 = 7 -> allowed
    db.prepare('UPDATE space SET parent_space_id = ? WHERE id = ?').run(zone, b2top);
    assert.equal(db.prepare('SELECT max(depth) AS d FROM space').get().d, 7);
    assertClosureMatchesOracle(db);
    // back to b2, then under the leaf of another depth-3 chain -> 4 + 4 = 8: refused
    db.prepare('UPDATE space SET parent_space_id = ? WHERE id = ?').run(b2, b2top);
    const z2 = insert(db, 'space', { site_id: f.siteId, parent_space_id: zone, type: 'zone', name: 'Zone A2' }); // depth 3
    expectAbort(db, 'UPDATE space SET parent_space_id = ? WHERE id = ?', 'space: maximum depth is 8 levels', [z2, b2top]);
    assertClosureMatchesOracle(db);
  } finally { db.close(); }
});

test('space_closure matches the recursive CTE oracle on a random tree of 2,000 spaces and 200 moves', (t) => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const rand = prng(20261106);
    const pick = (a) => a[Math.floor(rand() * a.length)];
    const s2 = insert(db, 'site', { tenant_id: f.tenantId, name: 'Site 2', timezone: 'UTC' });
    const allowed = db.prepare('SELECT child_type FROM space_type_rule WHERE parent_type IS ?').pluck();
    const ins = db.prepare(`INSERT INTO space (site_id, parent_space_id, type, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`);

    // nodes: [{id, site, type, depth}] tracked in JS only to choose valid parents
    const nodes = db.prepare('SELECT id, site_id AS site, type, depth FROM space').all();
    let t0 = process.hrtime.bigint();
    db.exec('BEGIN');
    while (nodes.length < 2000) {
      const asRoot = rand() < 0.02;
      const site = rand() < 0.5 ? f.siteId : s2;
      const parent = asRoot ? null : pick(nodes.filter((n) => n.site === site && n.depth < 7));
      if (!asRoot && !parent) continue;
      const types = allowed.all(parent ? parent.type : null);
      if (!types.length) continue;
      const type = pick(types);
      const id = Number(ins.run(site, parent ? parent.id : null, type, `S${nodes.length}`, T0, T0).lastInsertRowid);
      nodes.push({ id, site, type, depth: parent ? parent.depth + 1 : 0 });
    }
    db.exec('COMMIT');
    const insertMs = Number(process.hrtime.bigint() - t0) / 1e6;
    assertClosureMatchesOracle(db);

    // 200 successful random moves; refused attempts (cycle, type, depth) must leave nothing behind
    const move = db.prepare('UPDATE space SET parent_space_id = ? WHERE id = ?');
    const byId = new Map(nodes.map((n) => [n.id, n]));
    let moved = 0, refused = 0, attempts = 0;
    t0 = process.hrtime.bigint();
    while (moved < 200 && attempts < 50000) {
      attempts++;
      const n = pick(nodes);
      const candidates = nodes.filter((x) => x.site === n.site && x.id !== n.id);
      const toRoot = rand() < 0.05;
      const target = toRoot ? null : pick(candidates);
      try {
        move.run(target ? target.id : null, n.id);
        moved++;
      } catch (e) {
        assert.match(e.message, /^space: /, `unexpected error: ${e.message}`);
        refused++;
      }
    }
    const moveMs = Number(process.hrtime.bigint() - t0) / 1e6;
    assert.equal(moved, 200, 'could not find 200 valid moves');
    assert.ok(refused > 0, 'no move was refused, so the guards were not exercised');
    assertClosureMatchesOracle(db);
    assert.equal(byId.size, 2000);
    const rows = db.prepare('SELECT count(*) AS n FROM space_closure').get().n;
    t.diagnostic(`2,000 spaces inserted in ${insertMs.toFixed(0)} ms; ${moved} moves (+${refused} refused) in ${moveMs.toFixed(0)} ms; ${rows} closure rows`);
  } finally { db.close(); }
});

test('req 59 / 55: role scope "this space and beneath" is one indexed join (no SCAN)', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const zone = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Z' });
    const room = insert(db, 'space', { site_id: f.siteId, parent_space_id: zone, type: 'room', name: 'R' });
    insert(db, 'user_role', { user_id: f.userId, role_id: f.roleId, tenant_id: f.tenantId, site_id: f.siteId, space_id: f.floorId, granted_at: T0 });
    const sql = `SELECT ur.role_id FROM user_role ur
                   JOIN space_closure sc ON sc.ancestor_space_id = ur.space_id
                  WHERE ur.user_id = ? AND sc.descendant_space_id = ?`;
    assert.equal(db.prepare(sql).all(f.userId, room).length, 1, 'role on the floor applies to a room beneath it');
    assert.equal(db.prepare(sql).all(f.userId, f.buildingId).length, 0, 'role on the floor does not apply to the building above');
    assertNoScan(explain(db, sql, [f.userId, room]), ['user_role', 'space_closure', 'space']);
  } finally { db.close(); }
});

// ---------------------------------------------------------------------------------------------
// Floor plan revisions (G7, req 29, 39) — runs the SQL in docs/db/PLAN_REPLACEMENT.md
// ---------------------------------------------------------------------------------------------

test('PLAN_REPLACEMENT.md defines the four blocks the service runs', () => {
  assert.deepEqual(Object.keys(BLOCKS).sort(), ['commit-draft', 'confirm-placement', 'reject-draft', 'upload-draft']);
});

test('G7: a second current plan and a second draft are refused', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    runBlock(db, 'upload-draft', upload(f, 1));
    const d1 = draftOf(db, f.floorId);
    runBlock(db, 'commit-draft', { ...upload(f, 1), draft_id: d1.id, draft_row_version: d1.row_version });
    // direct second current
    expectAbort(db, `INSERT INTO floor_plan (space_id, revision_no, status, file_name, mime_type, width_px, height_px, size_bytes, sha256, storage_path, uploaded_at, created_at, updated_at)
                     VALUES (?, 2, 'current', 'x.png', 'image/png', 10, 10, 10, ?, 'x', ?, ?, ?)`, 'floor_plan: a space has one current plan', [f.floorId, hex(64, 'e'), T0, T0, T0]);
    // even bypassing the trigger's message, the partial unique index holds
    runBlock(db, 'upload-draft', upload(f, 2));
    const d2 = draftOf(db, f.floorId);
    assert.throws(() => db.prepare(`UPDATE floor_plan SET status = 'current' WHERE id = ?`).run(d2.id), /supersede the replaced plan/);
    // second draft while one is pending
    assert.throws(() => runBlock(db, 'upload-draft', upload(f, 3)), /UNIQUE constraint failed: floor_plan\.space_id/);
    assert.equal(db.prepare(`SELECT count(*) AS n FROM floor_plan WHERE space_id = ? AND status = 'current'`).get(f.floorId).n, 1);
  } finally { db.close(); }
});

test('req 39: replace -> confirm -> reject restores nothing because nothing changed; replace -> confirm all -> commit', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);

    // revision 1: first plan of the space (draft without a replaced plan, then commit)
    runBlock(db, 'upload-draft', upload(f, 1));
    const r1 = draftOf(db, f.floorId);
    assert.deepEqual(runBlock(db, 'commit-draft', { ...upload(f, 1), draft_id: r1.id, draft_row_version: r1.row_version }), [0, 1]);
    for (const [k, id, x] of [['device_id', f.deviceId, 0.25], ['controller_id', f.controllerId, 0.1], ['gateway_id', f.gatewayId, 0.9]]) {
      insert(db, 'plan_placement', { floor_plan_id: r1.id, [k]: id, x, y: 0.5, placed_by_user_account_id: f.userId, placed_at: T0 });
    }
    const r1Placements = placements(db, r1.id);
    const r1Row = planRow(db, r1.id);

    // same image as the current plan: refused by the live-revision sha256 dedupe
    assert.throws(() => runBlock(db, 'upload-draft', upload(f, 11)), /UNIQUE constraint failed: floor_plan\.space_id, floor_plan\.sha256/);

    // revision 2: draft copies placements as needs_review; the current revision is untouched
    runBlock(db, 'upload-draft', upload(f, 2));
    const r2 = draftOf(db, f.floorId);
    assert.deepEqual(planRow(db, r2.id), { id: r2.id, revision_no: 2, replaces_floor_plan_id: r1.id, status: 'draft', is_current: 0, row_version: 1 });
    assert.deepEqual(placements(db, r2.id).map((p) => [p.x, p.y, p.status]), r1Placements.map((p) => [p.x, p.y, 'needs_review']));
    assert.equal(currentOf(db, f.floorId).id, r1.id);

    // commit with placements still in review: refused, transaction rolled back, nothing changed
    assert.throws(() => runBlock(db, 'commit-draft', { ...upload(f, 2), draft_id: r2.id, draft_row_version: r2.row_version }), /placements still need review/);
    assert.equal(planRow(db, r1.id).status, 'current');
    assert.equal(planRow(db, r2.id).status, 'draft');

    // confirm one placement, then reject the draft
    const p0 = db.prepare(`SELECT id, row_version FROM plan_placement WHERE floor_plan_id = ? ORDER BY id LIMIT 1`).get(r2.id);
    assert.deepEqual(runBlock(db, 'confirm-placement', { placement_id: p0.id, row_version: p0.row_version, x: 0.3, y: 0.55, rotation_deg: 0, user_id: f.userId, now: T0 + 20 }), [1]);
    assert.deepEqual(runBlock(db, 'confirm-placement', { placement_id: p0.id, row_version: p0.row_version, x: 0.3, y: 0.55, rotation_deg: 0, user_id: f.userId, now: T0 + 21 }), [0], 'stale row_version');
    assert.deepEqual(runBlock(db, 'reject-draft', { draft_id: r2.id, draft_row_version: r2.row_version, user_id: f.userId, now: T0 + 30 }), [1]);

    // the previous image and placements are exactly as they were (req 39)
    assert.deepEqual(planRow(db, r1.id), r1Row);
    assert.deepEqual(placements(db, r1.id), r1Placements);
    assert.equal(planRow(db, r2.id).status, 'rejected');
    expectAbort(db, 'UPDATE plan_placement SET x = 0.9 WHERE id = ?', 'plan_placement: plan revision is frozen', [p0.id]);

    // revision 3 re-uses the rejected image (dedupe covers live revisions only)
    runBlock(db, 'upload-draft', upload(f, 3, { sha256: hex(64, '2') }));
    const r3 = draftOf(db, f.floorId);
    for (const p of db.prepare(`SELECT id, x, y, row_version FROM plan_placement WHERE floor_plan_id = ?`).all(r3.id)) {
      assert.deepEqual(runBlock(db, 'confirm-placement', { placement_id: p.id, row_version: p.row_version, x: p.x, y: p.y, rotation_deg: 0, user_id: f.userId, now: T0 + 40 }), [1]);
    }
    assert.deepEqual(runBlock(db, 'commit-draft', { ...upload(f, 3), draft_id: r3.id, draft_row_version: r3.row_version, now: T0 + 50 }), [1, 1]);
    assert.deepEqual([planRow(db, r1.id).status, planRow(db, r2.id).status, planRow(db, r3.id).status], ['superseded', 'rejected', 'current']);
    assert.deepEqual([planRow(db, r1.id).is_current, planRow(db, r3.id).is_current], [0, 1]);
    assert.ok(placements(db, r3.id).every((p) => p.status === 'placed'));
    assert.deepEqual(placements(db, r1.id), r1Placements, 'superseded placements kept as history');
    expectAbort(db, 'DELETE FROM plan_placement WHERE floor_plan_id = ?', 'plan_placement: plan revision is frozen', [r1.id]);
  } finally { db.close(); }
});

test('D6: cross-site placement is refused for each target kind', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const s2 = insert(db, 'site', { tenant_id: f.tenantId, name: 'Site 2', timezone: 'UTC' });
    const gw = insert(db, 'gateway', { site_id: s2, name: 'GW-2', created_at: T0 });
    const ctl = insert(db, 'controller', { gateway_id: gw, protocol_id: f.simplexProtocolId, ref: '2', name: 'FACP 2', vendor_id: f.simplexVendorId });
    const dev = insert(db, 'device', { controller_id: ctl, address: 'L2-M1', address_json: '{"loop":2,"point":"M1"}', device_type_id: f.deviceTypeId, created_at: T0 });
    runBlock(db, 'upload-draft', upload(f, 1));
    const planId = draftOf(db, f.floorId).id;
    for (const [k, id] of [['device_id', dev], ['controller_id', ctl], ['gateway_id', gw]]) {
      assert.throws(() => insert(db, 'plan_placement', { floor_plan_id: planId, [k]: id, x: 0.5, y: 0.5, placed_at: T0 }), /plan_placement: target not in plan's site/);
    }
    insert(db, 'plan_placement', { floor_plan_id: planId, device_id: f.deviceId, x: 0.5, y: 0.5, placed_at: T0 }); // same site: OK
  } finally { db.close(); }
});

// ---------------------------------------------------------------------------------------------
// Mapping completeness stub (req 35)
// ---------------------------------------------------------------------------------------------

test('req 35: v_space_mapping_completeness counts devices beneath a space and those placed on a current plan', () => {
  const db = freshDb();
  try {
    const f = insertFixtures(db);
    const zone = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.floorId, type: 'zone', name: 'Z' });
    insert(db, 'device', { controller_id: f.controllerId, address: 'L1-M2', address_json: '{"loop":1,"point":"M2"}', device_type_id: f.deviceTypeId, space_id: zone, created_at: T0 });
    const q = 'SELECT device_count, mapped_count FROM v_space_mapping_completeness WHERE space_id = ?';
    assert.deepEqual(db.prepare(q).get(f.buildingId), { device_count: 2, mapped_count: 0 });
    runBlock(db, 'upload-draft', upload(f, 1));
    const d = draftOf(db, f.floorId);
    insert(db, 'plan_placement', { floor_plan_id: d.id, device_id: f.deviceId, x: 0.5, y: 0.5, placed_at: T0 });
    assert.deepEqual(db.prepare(q).get(f.buildingId), { device_count: 2, mapped_count: 0 }, 'a draft does not count');
    runBlock(db, 'commit-draft', { ...upload(f, 1), draft_id: d.id, draft_row_version: d.row_version });
    assert.deepEqual(db.prepare(q).get(f.buildingId), { device_count: 2, mapped_count: 1 });
    assert.deepEqual(db.prepare(q).get(zone), { device_count: 1, mapped_count: 0 });
    assertNoScan(explain(db, q, [f.buildingId]), ['device', 'space_closure', 'plan_placement', 'floor_plan']);
  } finally { db.close(); }
});
