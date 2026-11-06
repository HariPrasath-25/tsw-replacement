'use strict';
// M2 reference data behaviour: lookups replace CHECK lists (N1), vendor/condition matching is
// case-insensitive, unknown conditions are counted on first sight (G9, req 41), fire precedence is
// immutable while other classes and custom roles stay editable (req 6, 56).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { freshDb, insert, insertFixtures, T0 } = require('./helpers');
const { lintDb } = require('../tools/lint');

function setup() {
  const db = freshDb();
  return { db, f: insertFixtures(db) };
}

test('N1: no system/vendor/protocol/condition CHECK lists or free-text columns remain', () => {
  const db = freshDb();
  try {
    assert.deepEqual(lintDb(db).filter((v) => v.rule === 'enum-lookup').map((v) => v.key), []);
    const lists = db.prepare(`SELECT name FROM sqlite_schema WHERE type = 'table' AND sql LIKE '%''bms''%'`).all();
    assert.deepEqual(lists, [], 'a system CHECK list is still inline');
  } finally { db.close(); }
});

test('controller defaults to the fire system; FKs refuse unknown lookup ids', () => {
  const { db, f } = setup();
  try {
    assert.equal(db.prepare('SELECT system_id FROM controller WHERE id = ?').get(f.controllerId).system_id, f.fireSystemId);
    assert.throws(() => insert(db, 'controller', { gateway_id: f.gatewayId, protocol_id: 999, ref: '9', name: 'X' }), /FOREIGN KEY/);
    assert.throws(() => db.prepare('DELETE FROM protocol WHERE id = ?').run(f.simplexProtocolId), /FOREIGN KEY/);
  } finally { db.close(); }
});

test('vendor matching is case-insensitive through match_key', () => {
  const { db } = setup();
  try {
    assert.equal(db.prepare('SELECT id FROM vendor WHERE match_key = upper(trim(?))').get('  simplex ').id, 1);
    assert.throws(() => insert(db, 'vendor', { name: ' SIMPLEX' }), /UNIQUE constraint failed: vendor.match_key/);
  } finally { db.close(); }
});

test('G9 / req 41: unknown condition inserted on first sight, counted under its reported name (ADR-006)', () => {
  const { db, f } = setup();
  try {
    const upsert = db.prepare(`INSERT INTO condition (raw_name, is_reported_unknown, created_at, updated_at)
                               VALUES (?, 1, ?, ?) ON CONFLICT (match_key) DO NOTHING`);
    const lookup = db.prepare('SELECT id FROM condition WHERE match_key = upper(trim(?))');
    const firstSight = (raw) => { upsert.run(raw, T0, T0); return lookup.get(raw).id; };

    const before = db.prepare('SELECT count(*) AS n FROM condition').get().n;
    const a = firstSight('Ground Fault');
    const b = firstSight('  GROUND fault ');
    assert.equal(a, b, 'case/space variants are one condition');
    assert.equal(db.prepare('SELECT count(*) AS n FROM condition').get().n, before + 1);
    assert.deepEqual(db.prepare('SELECT code, raw_name, is_reported_unknown, name_key FROM condition WHERE id = ?').get(a),
      { code: null, raw_name: 'Ground Fault', is_reported_unknown: 1, name_key: null });

    // A known name maps to the seeded row, not a new one.
    assert.equal(firstSight('sensor dirty'), db.prepare(`SELECT id FROM condition WHERE code = 'sensor_dirty'`).get().id);

    // RETURNING yields nothing on conflict, which is why the pattern needs the SELECT.
    const ret = db.prepare(`INSERT INTO condition (raw_name, is_reported_unknown, created_at, updated_at)
                            VALUES ('Ground Fault', 1, ?, ?) ON CONFLICT (match_key) DO NOTHING RETURNING id`).all(T0, T0);
    assert.deepEqual(ret, []);

    // Events reference it, so it is counted (req 41: not discarded).
    for (const [i, id] of [a, a, b].entries()) {
      insert(db, 'event', { gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: `c${i}`,
        event_type: 'alarm', alarm_class_id: f.troubleClassId, condition_id: id, rcv_time: T0 + i, raw_json: '{}' });
    }
    const counts = db.prepare(`SELECT c.raw_name, count(*) AS n FROM event e JOIN condition c ON c.id = e.condition_id
                               GROUP BY c.id`).all();
    assert.deepEqual(counts, [{ raw_name: 'Ground Fault', n: 3 }]);
  } finally { db.close(); }
});

test('req 6: precedence is unique per system; other systems may reuse a number', () => {
  const { db } = setup();
  try {
    const bms = db.prepare(`SELECT id FROM system WHERE code = 'bms'`).get().id;
    const fire = db.prepare(`SELECT id FROM system WHERE code = 'fire'`).get().id;
    assert.throws(() => insert(db, 'alarm_class', { system_id: fire, code: 'extra', name: 'Extra', precedence: 2 }),
      /UNIQUE constraint failed: alarm_class.system_id, alarm_class.precedence/);
    insert(db, 'alarm_class', { system_id: bms, code: 'high_temp', name: 'High temperature', precedence: 1 });
  } finally { db.close(); }
});

test('req 6: fire class wording stays editable; non-fire custom classes are fully editable', () => {
  const { db, f } = setup();
  try {
    db.prepare(`UPDATE alarm_class SET name = 'Fire alarm', row_version = row_version + 1 WHERE id = ?`).run(f.fireClassId);
    const bms = db.prepare(`SELECT id FROM system WHERE code = 'bms'`).get().id;
    const id = insert(db, 'alarm_class', { system_id: bms, code: 'high_temp', name: 'High temperature', precedence: 1 });
    db.prepare('UPDATE alarm_class SET precedence = 2, code = ?, is_life_safety = 1 WHERE id = ?').run('very_high_temp', id);
    db.prepare('DELETE FROM alarm_class WHERE id = ?').run(id);
    // After every attempt the fire order is unchanged.
    assert.deepEqual(db.prepare(`SELECT code FROM alarm_class WHERE system_id = ? ORDER BY precedence`).all(f.fireSystemId).map((r) => r.code),
      ['fire', 'priority2', 'supervisory', 'trouble']);
  } finally { db.close(); }
});

test('req 56: custom roles can be renamed and deleted; built-in role permissions stay amendable', () => {
  const { db, f } = setup();
  try {
    const id = insert(db, 'role', { name: 'Night Shift' });
    db.prepare(`UPDATE role SET name = 'Night Operators' WHERE id = ?`).run(id);
    db.prepare('DELETE FROM role WHERE id = ?').run(id);
    // Amend the built-in Operator role without a code change: remove and re-add a permission.
    const op = db.prepare(`SELECT id FROM role WHERE name = 'Operator'`).get().id;
    const reset = db.prepare(`SELECT id FROM permission WHERE code = 'panel.reset'`).get().id;
    assert.equal(db.prepare('DELETE FROM role_permission WHERE role_id = ? AND permission_id = ?').run(op, reset).changes, 1);
    insert(db, 'role_permission', { role_id: op, permission_id: reset });
    assert.ok(f.roleId);
  } finally { db.close(); }
});
