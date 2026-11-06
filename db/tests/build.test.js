'use strict';
// db:build harness: version gate, file-creation pragmas before DDL, atomic build, CLI.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const { buildDatabase, versionAtLeast, splitHeaderPragmas, listModules, SCHEMA_DIR, SEED_DIR, ROOT } = require('../tools/lib/schema');

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

test('built file carries the 00_header settings: page_size, auto_vacuum, application_id, user_version (P2, P3, N5)', () => {
  const file = path.join(tmpDir(), 'h.db');
  let ranBeforeDdl = null;
  const db = buildDatabase(file, { onPragmas: (_d, pragmas) => { ranBeforeDdl = pragmas; } });
  try {
    assert.deepEqual(ranBeforeDdl, ['PRAGMA page_size = 4096;', 'PRAGMA auto_vacuum = INCREMENTAL;', 'PRAGMA application_id = 1330466377;']);
    assert.equal(db.pragma('page_size', { simple: true }), 4096);
    assert.equal(db.pragma('auto_vacuum', { simple: true }), 2); // INCREMENTAL
    assert.equal(db.pragma('application_id', { simple: true }), 0x4F4D4E49);
    assert.equal(db.pragma('user_version', { simple: true }), 3);
  } finally { db.close(); }
});

test('migration log: one row per module at user_version, checksum = sha256 of the module text (ADR-004)', () => {
  const db = buildDatabase(':memory:', { appliedBy: 'test-build' });
  try {
    const rows = db.prepare('SELECT version, module, checksum, applied_by FROM schema_version ORDER BY id').all();
    // Schema modules first, then seed modules (prefixed 'seed/'), each with its own checksum.
    const mods = [...listModules(SCHEMA_DIR), ...listModules(SEED_DIR).map((m) => ({ ...m, name: 'seed/' + m.name }))];
    assert.ok(mods.length > listModules(SCHEMA_DIR).length, 'seed modules are logged');
    assert.deepEqual(rows.map((r) => r.module), mods.map((m) => m.name));
    for (const [i, m] of mods.entries()) {
      assert.equal(rows[i].checksum, crypto.createHash('sha256').update(m.sql, 'utf8').digest('hex'), m.name);
      assert.equal(rows[i].version, db.pragma('user_version', { simple: true }));
      assert.equal(rows[i].applied_by, 'test-build');
    }
  } finally { db.close(); }
});

test('user_version stays 0 when the build fails after the DDL ran (set last, inside the transaction)', () => {
  const file = path.join(tmpDir(), 'fail.db');
  assert.throws(() => buildDatabase(file, { beforeUserVersion: () => { throw new Error('late failure'); } }), /late failure/);
  const db = new Database(file);
  try {
    assert.equal(db.pragma('user_version', { simple: true }), 0);
    assert.equal(db.prepare('SELECT count(*) AS n FROM sqlite_schema').get().n, 0); // whole build rolled back
  } finally { db.close(); }
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
  assert.match(r.stdout, /55 tables/);
  assert.match(r.stdout, /4 seed/);
});

test('docs/db/DATA_DICTIONARY.md is generated from the current schema (not stale)', () => {
  const r = spawnSync(process.execPath, [path.join(ROOT, 'db/tools/dictionary.js'), '--check'], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr + ' — run: node db/tools/dictionary.js');
});
