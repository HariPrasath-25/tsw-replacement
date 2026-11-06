'use strict';
// Shared test helpers. Every test builds its own fresh database from db/schema + db/seed;
// never test against a hand-edited or previously built file.

const assert = require('node:assert/strict');
const path = require('path');
const { buildDatabase, listModules, objectsDefinedIn, SCHEMA_DIR } = require('../../tools/lib/schema');

/** Fixed base time for fixtures (UTC ms, 2026-11-05T00:00:00Z). */
const T0 = Date.UTC(2026, 10, 5);

/** A fresh database built from the schema modules. opts.file builds to a file instead of memory. */
function freshDb(opts = {}) {
  return buildDatabase(opts.file || ':memory:', opts);
}

/** Assert that running sql (with optional params) aborts and the error message contains fragment. */
function expectAbort(db, sql, fragment, params = []) {
  assert.throws(
    () => {
      const stmt = db.prepare(sql);
      if (stmt.reader) stmt.all(...[].concat(params));
      else stmt.run(...[].concat(params));
    },
    (e) => {
      assert.ok(String(e.message).includes(fragment), `expected error containing "${fragment}", got "${e.message}"`);
      return true;
    },
  );
}

/** EXPLAIN QUERY PLAN rows ({id, parent, detail}) for sql. */
function explain(db, sql, params = []) {
  return db.prepare('EXPLAIN QUERY PLAN ' + sql).all(...[].concat(params));
}

/** Assert that a plan does not full-scan any of the given tables (CLAUDE.md alarm-path rule). */
function assertNoScan(plan, tables = ['event', 'alarm', 'device', 'audit_log']) {
  for (const row of plan) {
    for (const t of tables) {
      // Any "SCAN <t>" (including a full scan of an index, "SCAN t USING INDEX ...") fails;
      // only "SEARCH <t> ..." (bounded by an index key) is acceptable on hot tables.
      if (new RegExp(`^SCAN ${t}(\\s|$)`).test(row.detail)) {
        assert.fail(`query plan scans ${t}: ${row.detail}`);
      }
    }
  }
}

// Per-handle cache of each table's column names (for the P8 audit-column defaults below).
const columnCache = new WeakMap();
function tableColumns(db, table) {
  let m = columnCache.get(db);
  if (!m) columnCache.set(db, (m = new Map()));
  if (!m.has(table)) m.set(table, new Set(db.pragma(`table_xinfo("${table}")`).map((c) => c.name)));
  return m.get(table);
}

/**
 * INSERT a row given as an object; returns the new rowid.
 * Mutable config tables (P8) require created_at / updated_at: when the row omits them they default to T0,
 * so fixtures stay focused on the columns under test. Pass them explicitly to test their CHECKs.
 */
function insert(db, table, row) {
  const cols0 = tableColumns(db, table);
  row = { ...row };
  for (const c of ['created_at', 'updated_at']) if (cols0.has(c) && !(c in row)) row[c] = T0;
  const cols = Object.keys(row);
  const sql = `INSERT INTO ${table} (${cols.join(', ')}) VALUES (${cols.map((c) => '@' + c).join(', ')})`;
  return Number(db.prepare(sql).run(row).lastInsertRowid);
}

/**
 * Minimal valid graph: tenant > site > building > floor; gateway (+ current hardware) >
 * controller > device; device categories/types (id 0 = unknown); one admin user; ids of the seeded
 * Administrator role, panel.silence permission, fire system, Simplex protocol/vendor and fire/trouble classes.
 * Returns the ids.
 */
function insertFixtures(db) {
  const f = {};
  f.tenantId = insert(db, 'tenant', { name: 'Fixture Tenant', created_at: T0 });
  f.siteId = insert(db, 'site', { tenant_id: f.tenantId, name: 'Fixture Site', timezone: 'Asia/Dubai', created_at: T0 });
  f.buildingId = insert(db, 'space', { site_id: f.siteId, type: 'building', name: 'Tower A' });
  f.floorId = insert(db, 'space', { site_id: f.siteId, parent_space_id: f.buildingId, type: 'floor', name: 'Floor 16' });

  f.userId = insert(db, 'user_account', {
    username: 'admin', display_name: 'Fixture Admin', auth_type: 'local',
    password_hash: '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA', created_at: T0,
  });
  // Seeded reference data (db/seed, M2): look ids up by natural key, never re-insert them.
  const idOf = (table, col, value) => db.prepare(`SELECT id FROM ${table} WHERE ${col} = ?`).get(value).id;
  f.roleId = idOf('role', 'name', 'Administrator');
  f.permissionId = idOf('permission', 'code', 'panel.silence');
  f.fireSystemId = idOf('system', 'code', 'fire');
  f.simplexProtocolId = idOf('protocol', 'code', 'simplex');
  f.simplexVendorId = idOf('vendor', 'match_key', 'SIMPLEX');
  f.fireClassId = idOf('alarm_class', 'name_key', 'alarm_class.fire');
  f.troubleClassId = idOf('alarm_class', 'name_key', 'alarm_class.trouble');

  f.gatewayId = insert(db, 'gateway', { site_id: f.siteId, space_id: f.floorId, name: 'GW-1', created_at: T0 });
  f.gatewayHardwareId = insert(db, 'gateway_hardware', { gateway_id: f.gatewayId, serial: 'GW1B2511004', installed_at: T0 });
  f.controllerId = insert(db, 'controller', { gateway_id: f.gatewayId, space_id: f.floorId, protocol_id: f.simplexProtocolId, ref: '1', name: 'FACP 1', vendor_id: f.simplexVendorId });

  f.unknownCategoryId = insert(db, 'device_category', { code: 'unknown', name: 'Unknown', is_physical: 0 });
  f.detectorCategoryId = insert(db, 'device_category', { code: 'detector', name: 'Detector' });
  insert(db, 'device_type', { id: 0, code: 'unknown', device_category_id: f.unknownCategoryId, name: 'Unknown' });
  f.deviceTypeId = insert(db, 'device_type', { code: 'smoke_detector', device_category_id: f.detectorCategoryId, name: 'Smoke detector', has_analog: 1 });
  f.deviceId = insert(db, 'device', {
    controller_id: f.controllerId, address: 'L1-M1', address_json: '{"loop":1,"point":"M1"}',
    device_type_id: f.deviceTypeId, space_id: f.floorId, created_at: T0,
  });
  return f;
}

/** Tables defined by a schema module, e.g. moduleTables('02_sources'). */
function moduleTables(moduleName) {
  const m = listModules(SCHEMA_DIR).find((x) => x.name === moduleName);
  if (!m) throw new Error(`no schema module ${moduleName}`);
  return objectsDefinedIn(m.sql).filter((o) => o.type === 'table').map((o) => o.name);
}

/** Assert every table defined by the module holds at least one row (smoke coverage gate). */
function assertModuleCovered(db, moduleName) {
  const empty = moduleTables(moduleName).filter((t) => db.prepare(`SELECT count(*) AS n FROM ${t}`).get().n === 0);
  assert.deepEqual(empty, [], `${moduleName}: tables without a smoke-test row: ${empty.join(', ')}`);
}

/** Hex string of n chars (for sha256 / hash columns). */
const hex = (n, ch = 'a') => ch.repeat(n);

module.exports = {
  T0, freshDb, expectAbort, explain, assertNoScan, insert, insertFixtures,
  moduleTables, assertModuleCovered, hex, SCHEMA_DIR, ROOT: path.resolve(__dirname, '..', '..', '..'),
};
