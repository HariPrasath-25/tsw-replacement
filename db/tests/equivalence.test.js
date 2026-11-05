'use strict';
// Draft v2 is the diff reference. M0 proved modules == Draft v2. From M1 the schema changes on
// purpose, so these tests assert that nothing from Draft v2 was removed (only recorded renames).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { run, compare, guard, RENAMES } = require('../tools/equiv');
const { buildDatabase, buildFromFile, listModules, objectsDefinedIn, SCHEMA_DIR, REFERENCE_FILE } = require('../tools/lib/schema');

test('no Draft v2 table, column, index or trigger was removed (renames are recorded)', () => {
  const { problems, diffs, objects } = run();
  assert.deepEqual(problems, []);
  assert.equal(objects, 83); // Draft v2: 48 tables + 27 indexes + 8 triggers
  assert.ok(diffs.length > 0, 'M1 changes the schema, so differences are expected');
});

test('every schema object is defined in exactly one module, and every Draft v2 object is among them', () => {
  const mods = listModules(SCHEMA_DIR).flatMap((m) => objectsDefinedIn(m.sql)).map((o) => `${o.type} ${o.name}`);
  assert.equal(new Set(mods).size, mods.length, 'an object is defined in two modules');
  const ref = objectsDefinedIn(fs.readFileSync(REFERENCE_FILE, 'utf8')).map((o) => `${o.type} ${o.name}`);
  const missing = ref.map((k) => RENAMES.objects[k] || k).filter((k) => !mods.includes(k));
  assert.deepEqual(missing, []);
});

test('the guard detects a removed column and a removed table', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsdb-eq-'));
  for (const m of listModules(SCHEMA_DIR)) {
    let sql = m.sql;
    if (m.name === '09_ops') sql = sql.replace('    is_verified      INTEGER NOT NULL DEFAULT 0 CHECK (is_verified IN (0,1)),  -- restore-tested\n', '');
    if (m.name === '10_licence') sql = sql.replace(/CREATE TABLE licence \([\s\S]*?\) STRICT;\n/, '');
    fs.writeFileSync(path.join(dir, m.name + '.sql'), sql);
  }
  const ref = buildFromFile(REFERENCE_FILE);
  const mod = buildDatabase(':memory:', { schemaDir: dir, seed: false });
  const problems = guard(ref, mod);
  ref.close(); mod.close();
  assert.ok(problems.includes('removed column: backup_run.verified (expected as is_verified)'), problems.join('\n'));
  assert.ok(problems.includes('removed: table licence'), problems.join('\n'));
});

test('the frozen reference is untouched and still loads', () => {
  const text = fs.readFileSync(REFERENCE_FILE, 'utf8');
  assert.equal(text.split(/\r?\n/).length - 1, 782);
  buildFromFile(REFERENCE_FILE).close();
});

test('the equivalence check detects a changed module', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsdb-eq-'));
  for (const m of listModules(SCHEMA_DIR)) {
    const sql = m.name === '01_tenancy' ? m.sql.replace("timezone     TEXT    NOT NULL,", "timezone     TEXT    NOT NULL DEFAULT 'UTC',") + '\nCREATE TABLE extra (id INTEGER PRIMARY KEY) STRICT;\n' : m.sql;
    fs.writeFileSync(path.join(dir, m.name + '.sql'), sql);
  }
  const ref = buildFromFile(REFERENCE_FILE);
  const mod = buildDatabase(':memory:', { schemaDir: dir, seed: false });
  const diffs = compare(ref, mod);
  ref.close(); mod.close();
  assert.ok(diffs.some((d) => d.startsWith('different: table site')), diffs.join('\n'));
  assert.ok(diffs.some((d) => d === 'extra in modules: table extra'), diffs.join('\n'));
});
