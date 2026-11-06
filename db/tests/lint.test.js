'use strict';
// db:lint as a ratchet: no new violations, no stale allowlist entries, and the rules really fire.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { lintDb, checkAllowlist, loadAllowlist } = require('../tools/lint');
const { freshDb, ROOT } = require('./helpers');

const decisions = fs.readFileSync(path.join(ROOT, 'docs/db/DECISIONS.md'), 'utf8');

test('schema has no lint violations outside the allowlist, and no stale entries', () => {
  const db = freshDb();
  const v = lintDb(db);
  db.close();
  const r = checkAllowlist(v, loadAllowlist(), decisions);
  assert.deepEqual(r.problems, []);
  assert.deepEqual(r.fresh.map((x) => x.key), [], 'new violations');
  assert.deepEqual(r.stale.map((x) => x.key), [], 'stale allowlist entries (remove them)');
});

test('every allowlist entry has a reason, tag and an ADR present in DECISIONS.md', () => {
  for (const e of loadAllowlist()) {
    assert.ok(e.reason && e.reason.length > 10, e.key);
    assert.ok(e.tag, e.key);
    assert.match(decisions, new RegExp(`^##+ ${e.adr}\\b`, 'm'), e.key);
  }
});

test('rules fire on a table that breaks every convention', () => {
  const db = freshDb();
  db.exec(`
    CREATE TABLE Widgets (
      id TEXT PRIMARY KEY,
      owner INTEGER REFERENCES tenant(id),
      tenant_id INTEGER REFERENCES tenant(id) ON DELETE RESTRICT,
      created_at INTEGER NOT NULL,
      seen_time TEXT,
      is_ok INTEGER,
      active INTEGER NOT NULL CHECK (active IN (0,1)),
      meta_json TEXT,
      file_sha256 TEXT,
      run_uuid TEXT,
      vendor TEXT,
      name_key TEXT
    );
    CREATE INDEX widgets_owner ON Widgets(owner);
    CREATE TABLE gadget (id INTEGER PRIMARY KEY, created_at INTEGER NOT NULL CHECK (created_at > 0)) STRICT;
    CREATE TRIGGER gadget_guard BEFORE DELETE ON gadget BEGIN SELECT RAISE(ABORT, 'x'); END;
  `);
  const keys = new Set(lintDb(db).map((v) => v.key));
  db.close();
  for (const k of [
    'strict:Widgets', 'pk-id:Widgets', 'naming:table Widgets',
    'fk-name:Widgets.owner', 'fk-on-delete:Widgets.owner', 'fk-index:Widgets.tenant_id',
    'time-positive:Widgets.created_at', 'time-type:Widgets.seen_time',
    'bool:Widgets.is_ok', 'bool-name:Widgets.active', 'json:Widgets.meta_json',
    'hash:Widgets.file_sha256', 'uuid:Widgets.run_uuid', 'enum-lookup:Widgets.vendor', 'name-key:Widgets.name_key',
    'naming:index widgets_owner', 'naming:trigger gadget_guard',
  ]) assert.ok(keys.has(k), `expected violation ${k}`);
  // Conforming parts are not reported.
  for (const k of ['fk-on-delete:Widgets.tenant_id', 'fk-index:Widgets.owner', 'time-positive:gadget.created_at', 'strict:gadget', 'pk-id:gadget']) {
    assert.ok(!keys.has(k), `unexpected violation ${k}`);
  }
});

test('allowlist check reports new, stale and malformed entries', () => {
  const violations = [{ key: 'json:a.x_json' }, { key: 'json:b.y_json' }];
  const allow = [
    { key: 'json:a.x_json', reason: 'baseline debt', adr: 'ADR-000', tag: 'baseline' },
    { key: 'json:gone.z_json', reason: 'fixed already', adr: 'ADR-000', tag: 'baseline' },
    { key: 'json:c.bad', reason: '', adr: 'ADR-999', tag: 'baseline' },
  ];
  const r = checkAllowlist(violations, allow, decisions);
  assert.deepEqual(r.fresh.map((v) => v.key), ['json:b.y_json']);
  assert.deepEqual(r.stale.map((e) => e.key).sort(), ['json:c.bad', 'json:gone.z_json']);
  assert.ok(r.problems.some((p) => p.includes('no reason')));
  assert.ok(r.problems.some((p) => p.includes('ADR-999')));
});
