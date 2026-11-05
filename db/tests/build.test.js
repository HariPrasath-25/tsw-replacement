'use strict';
// db:build harness: version gate, file-creation pragmas before DDL, atomic build, CLI.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { buildDatabase, versionAtLeast, splitHeaderPragmas, listModules, SCHEMA_DIR, ROOT } = require('../tools/lib/schema');

function tmpDir() { return fs.mkdtempSync(path.join(os.tmpdir(), 'wsdb-')); }

/** Copy db/schema into a temp dir, letting the caller edit module text. */
function copySchema(edit = {}) {
  const dir = tmpDir();
  for (const m of listModules(SCHEMA_DIR)) fs.writeFileSync(path.join(dir, m.name + '.sql'), edit[m.name] ? edit[m.name](m.sql) : m.sql);
  return dir;
}

test('version comparison', () => {
  assert.ok(versionAtLeast('3.45.0', '3.45.0'));
  assert.ok(versionAtLeast('3.53.4', '3.45.0'));
  assert.ok(versionAtLeast('4.0.0', '3.45.0'));
  assert.ok(!versionAtLeast('3.44.2', '3.45.0'));
  assert.ok(!versionAtLeast('3.9.0', '3.45.0'));
});

test('linked SQLite is >= 3.45', () => {
  const db = buildDatabase();
  const v = db.prepare('SELECT sqlite_version() AS v').get().v;
  db.close();
  assert.ok(versionAtLeast(v, '3.45.0'), v);
});

test('header PRAGMA lines are extracted; PRAGMAs in comments are not', () => {
  const { pragmas, rest } = splitHeaderPragmas('-- PRAGMA journal_mode = WAL;\nPRAGMA page_size = 8192;  -- note\nCREATE TABLE x (id INTEGER PRIMARY KEY) STRICT;\n');
  assert.deepEqual(pragmas, ['PRAGMA page_size = 8192;']);
  assert.ok(rest.includes('-- PRAGMA journal_mode') && rest.includes('CREATE TABLE x'));
});

test('file-creation pragmas from 00_header run on the empty file, before any DDL', () => {
  const dir = copySchema({ '00_header': (s) => 'PRAGMA page_size = 8192;\nPRAGMA auto_vacuum = INCREMENTAL;\n' + s });
  const file = path.join(tmpDir(), 'p.db');
  let objectsWhenPragmasRan = null;
  const db = buildDatabase(file, {
    schemaDir: dir,
    onPragmas: (d) => { objectsWhenPragmasRan = d.prepare('SELECT count(*) AS n FROM sqlite_schema').get().n; },
  });
  assert.equal(objectsWhenPragmasRan, 0);
  // page_size and auto_vacuum only take effect if set before the first table is created.
  assert.equal(db.pragma('page_size', { simple: true }), 8192);
  assert.equal(db.pragma('auto_vacuum', { simple: true }), 2);
  db.close();
});

test('PRAGMA outside 00_header is refused', () => {
  const dir = copySchema({ '05_commands': (s) => s + '\nPRAGMA page_size = 8192;\n' });
  assert.throws(() => buildDatabase(':memory:', { schemaDir: dir }), /PRAGMA statements belong in 00_header/);
});

test('a failing module aborts the whole build (one transaction) and names the module', () => {
  const dir = copySchema({ '09_ops': (s) => s + '\nCREATE TABLE broken (id INTEGER PRIMARY KEY, x NOPE) STRICT;\n' });
  assert.throws(() => buildDatabase(':memory:', { schemaDir: dir }), /09_ops:/);
});

test('npm run db:build creates a fresh file and reports the SQLite version', () => {
  const file = path.join(tmpDir(), 'cli.db');
  fs.writeFileSync(file, 'not a database'); // must be replaced, never reused
  const r = spawnSync(process.execPath, [path.join(ROOT, 'db/tools/build.js'), file], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /sqlite_version\(\) = 3\.\d+\.\d+/);
  assert.match(r.stdout, /48 tables/);
});
