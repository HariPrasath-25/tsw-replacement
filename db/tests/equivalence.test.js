'use strict';
// M0 acceptance: the schema modules build exactly Draft v2.
// When a later milestone changes the schema on purpose, replace the first test with an assertion
// on the intended diff (node db/tools/equiv.js --diff) rather than deleting it.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { run, compare } = require('../tools/equiv');
const { buildDatabase, buildFromFile, listModules, objectsDefinedIn, SCHEMA_DIR, REFERENCE_FILE } = require('../tools/lib/schema');

test('modules == Draft v2 (normalised sqlite_schema + table/fk/index pragmas)', () => {
  const { diffs, objects } = run();
  assert.deepEqual(diffs, []);
  assert.equal(objects, 83); // 48 tables + 27 indexes + 8 triggers
});

test('every Draft v2 object is defined in exactly one module', () => {
  const ref = objectsDefinedIn(fs.readFileSync(REFERENCE_FILE, 'utf8')).map((o) => `${o.type} ${o.name}`).sort();
  const mods = listModules(SCHEMA_DIR).flatMap((m) => objectsDefinedIn(m.sql)).map((o) => `${o.type} ${o.name}`).sort();
  assert.deepEqual(mods, ref);
});

test('the frozen reference is untouched and still loads', () => {
  const text = fs.readFileSync(REFERENCE_FILE, 'utf8');
  assert.equal(text.split(/\r?\n/).length - 1, 782);
  buildFromFile(REFERENCE_FILE).close();
});

test('the equivalence check detects a changed module', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsdb-eq-'));
  for (const m of listModules(SCHEMA_DIR)) {
    const sql = m.name === '01_tenancy' ? m.sql.replace("DEFAULT 'Asia/Dubai'", "DEFAULT 'UTC'") + '\nCREATE TABLE extra (id INTEGER PRIMARY KEY) STRICT;\n' : m.sql;
    fs.writeFileSync(path.join(dir, m.name + '.sql'), sql);
  }
  const ref = buildFromFile(REFERENCE_FILE);
  const mod = buildDatabase(':memory:', { schemaDir: dir, seed: false });
  const diffs = compare(ref, mod);
  ref.close(); mod.close();
  assert.ok(diffs.some((d) => d.startsWith('different: table site')), diffs.join('\n'));
  assert.ok(diffs.some((d) => d === 'extra in modules: table extra'), diffs.join('\n'));
});
