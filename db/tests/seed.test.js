'use strict';
// M2 seed data: idempotent (run twice = no change) and exactly the approved reference sets
// (req 6, 41, 56, 57; Section 13 gateway permissions and roles; ADR-007).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { freshDb } = require('./helpers');
const { listModules, SEED_DIR } = require('../tools/lib/schema');
const { stripComments } = require('../tools/lib/sql');

const SEEDED = ['system', 'vendor', 'protocol', 'alarm_class', 'device_state_code', 'condition', 'permission', 'role', 'role_permission', 'space_type_rule'];

function snapshot(db) {
  const out = {};
  for (const t of SEEDED) {
    const rows = db.prepare(`SELECT * FROM ${t} ORDER BY id`).all();
    out[t] = { n: rows.length, sha: crypto.createHash('sha256').update(JSON.stringify(rows)).digest('hex') };
  }
  return out;
}

test('seed modules exist and every INSERT is ON CONFLICT DO NOTHING', () => {
  const mods = listModules(SEED_DIR);
  assert.deepEqual(mods.map((m) => m.name), ['01_lookups', '02_alarm', '03_rbac', '04_space']);
  for (const m of mods) {
    const stmts = stripComments(m.sql).split(';').map((s) => s.trim()).filter(Boolean);
    for (const s of stmts) {
      assert.match(s, /^INSERT INTO\b/i, `${m.name}: only INSERTs in seeds`);
      assert.match(s, /ON CONFLICT DO NOTHING$/i, `${m.name}: INSERT without ON CONFLICT DO NOTHING`);
    }
  }
});

test('applying every seed module a second time changes nothing (idempotent)', () => {
  const db = freshDb();
  try {
    const before = snapshot(db);
    const changes0 = db.prepare('SELECT total_changes() AS n').get().n;
    for (const m of listModules(SEED_DIR)) db.exec(m.sql);
    assert.equal(db.prepare('SELECT total_changes() AS n').get().n, changes0, 'a re-applied seed wrote rows');
    assert.deepEqual(snapshot(db), before);
    for (const t of SEEDED) assert.ok(before[t].n > 0, `${t} is seeded`);
  } finally { db.close(); }
});

test('req 6: four fire alarm classes in fixed precedence, all life safety and built in', () => {
  const db = freshDb();
  try {
    const rows = db.prepare(`SELECT ac.code, ac.name, ac.precedence, ac.is_life_safety, ac.is_builtin
                             FROM alarm_class ac JOIN system s ON s.id = ac.system_id
                             WHERE s.code = 'fire' ORDER BY ac.precedence`).all();
    assert.deepEqual(rows, [
      { code: 'fire', name: 'Fire', precedence: 1, is_life_safety: 1, is_builtin: 1 },
      { code: 'priority2', name: 'Priority 2', precedence: 2, is_life_safety: 1, is_builtin: 1 },
      { code: 'supervisory', name: 'Supervisory', precedence: 3, is_life_safety: 1, is_builtin: 1 },
      { code: 'trouble', name: 'Trouble', precedence: 4, is_life_safety: 1, is_builtin: 1 },
    ]);
  } finally { db.close(); }
});

test('req 41: the eight gateway-spec conditions, each separate and translatable', () => {
  const db = freshDb();
  try {
    const names = db.prepare('SELECT raw_name FROM condition WHERE is_reported_unknown = 0 ORDER BY id').all().map((r) => r.raw_name);
    assert.deepEqual(names, ['Head Missing', 'No Answer', 'Abnormal', 'Output Abnormal', 'Bad Answer',
      'Disabled Device', 'Sensor Dirty', 'Open Circuit Reporting']);
    assert.equal(db.prepare('SELECT count(*) AS n FROM condition WHERE name_key IS NULL OR code IS NULL').get().n, 0);
  } finally { db.close(); }
});

test('req 57 / Section 13: exactly the approved permission codes, domains and central-grant flags', () => {
  const db = freshDb();
  try {
    const rows = db.prepare('SELECT code, domain, is_central_grant_required AS g FROM permission ORDER BY id').all();
    const fmt = rows.map((r) => `${r.domain}:${r.code}${r.g ? ':grant' : ''}`);
    assert.deepEqual(fmt, [
      'fire:alarm.view', 'fire:alarm.acknowledge', 'fire:panel.silence', 'fire:panel.reset',
      'fire:device.disable', 'fire:device.discover', 'fire:plan.edit',
      'platform:user.manage', 'platform:tenant.manage', 'platform:setting.manage', 'platform:licence.manage',
      'platform:data.export', 'platform:analytics.operator.view', 'platform:audit.read',
      'gateway:gateway.view', 'gateway:gateway.network.configure', 'gateway:gateway.service.manage:grant',
      'gateway:gateway.module.install:grant', 'gateway:gateway.module.configure:grant',
      'gateway:gateway.module.activate:grant', 'gateway:gateway.module.remove:grant', 'gateway:gateway.access.approve',
    ]);
  } finally { db.close(); }
});

/** {role name: [permission codes sorted]} */
function matrix(db) {
  const out = {};
  for (const r of db.prepare(`SELECT r.name, p.code FROM role r LEFT JOIN role_permission rp ON rp.role_id = r.id
                              LEFT JOIN permission p ON p.id = rp.permission_id ORDER BY r.id, p.code`).all()) {
    (out[r.name] = out[r.name] || []).push(r.code);
  }
  return out;
}

test('req 56 / Section 13: built-in roles and the approved role-permission matrix (ADR-007)', () => {
  const db = freshDb();
  try {
    const builtin = db.prepare('SELECT name FROM role WHERE is_builtin = 1 ORDER BY id').all().map((r) => r.name);
    assert.deepEqual(builtin, ['Administrator', 'Engineer', 'Operator', 'Viewer', 'Gateway Viewer',
      'Gateway Operator / Commissioning User', 'Omniconn Gateway Administrator', 'Central Access / Module Approver']);

    const viewer = ['alarm.view'];
    const operator = [...viewer, 'alarm.acknowledge', 'panel.silence', 'panel.reset', 'data.export'];
    const engineer = [...operator, 'device.disable', 'device.discover', 'plan.edit'];
    const admin = [...engineer, 'user.manage', 'tenant.manage', 'setting.manage', 'licence.manage', 'analytics.operator.view', 'audit.read'];
    const gwAdmin = ['gateway.view', 'gateway.network.configure', 'gateway.service.manage', 'gateway.module.install',
      'gateway.module.configure', 'gateway.module.activate', 'gateway.module.remove'];
    const sort = (a) => [...a].sort();
    assert.deepEqual(matrix(db), {
      Administrator: sort(admin),
      Engineer: sort(engineer),
      Operator: sort(operator),
      Viewer: sort(viewer),
      'Gateway Viewer': ['gateway.view'],
      'Gateway Operator / Commissioning User': ['gateway.view'],
      'Omniconn Gateway Administrator': sort(gwAdmin),
      'Central Access / Module Approver': ['gateway.access.approve'],
    });
  } finally { db.close(); }
});

test('Section 13: fire roles hold no gateway permission; approval is separate from execution', () => {
  const db = freshDb();
  try {
    const crossed = db.prepare(`SELECT r.name, p.code FROM role_permission rp JOIN role r ON r.id = rp.role_id
                                JOIN permission p ON p.id = rp.permission_id
                                WHERE (p.domain = 'gateway') <> (r.name_key GLOB 'role.gateway_*')`).all();
    assert.deepEqual(crossed, [], 'fire role with a gateway permission, or gateway role with a fire/platform permission');
    const m = matrix(db);
    assert.ok(!m['Omniconn Gateway Administrator'].includes('gateway.access.approve'), 'executor cannot approve');
    assert.deepEqual(m['Central Access / Module Approver'], ['gateway.access.approve'], 'approver cannot execute');
    assert.ok(!m['Gateway Operator / Commissioning User'].includes('gateway.network.configure'), 'network is granted per user');
    // req 56: the seeded installation has a role holding user.manage.
    assert.ok(m.Administrator.includes('user.manage'));
  } finally { db.close(); }
});
