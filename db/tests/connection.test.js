'use strict';
// Connection profile (req 97, P1, ADR-003): open via the profile and assert every pragma value.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Database = require('better-sqlite3');
const { buildDatabase } = require('../tools/lib/schema');
const conn = require('../tools/connection');
const { T0 } = require('./helpers');

function builtFile() {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wsdb-conn-')), 'ws.db');
  buildDatabase(file).close();
  return file;
}

test('writer: every pragma has the profile value', () => {
  const db = conn.openWriter(builtFile());
  try {
    const p = (k) => db.pragma(k, { simple: true });
    assert.equal(p('journal_mode'), 'wal');
    assert.equal(p('synchronous'), 2);          // FULL
    assert.equal(p('foreign_keys'), 1);
    assert.equal(p('trusted_schema'), 0);
    assert.equal(p('busy_timeout'), 5000);
    assert.equal(p('wal_autocheckpoint'), 0);   // the service owns checkpoints
    assert.equal(p('journal_size_limit'), 67108864);
    assert.equal(p('temp_store'), 2);           // MEMORY
    assert.equal(p('cache_size'), -65536);
    assert.equal(p('mmap_size'), 0);
    assert.equal(p('query_only'), 0);
    assert.equal(p('application_id'), conn.APPLICATION_ID);
    assert.equal(p('user_version'), conn.SCHEMA_VERSION);
    assert.ok(conn.isDefensive(db), 'DEFENSIVE must be on');
    assert.ok(conn.assertProfile(db, 'writer'));
  } finally { db.close(); }
});

test('reader: query_only, smaller cache, same durability settings; cannot write', () => {
  const file = builtFile();
  const w = conn.openWriter(file); // WAL is persistent; set by the writer
  const r = conn.openReader(file);
  try {
    const p = (k) => r.pragma(k, { simple: true });
    assert.equal(p('journal_mode'), 'wal');
    assert.equal(p('query_only'), 1);
    assert.equal(p('cache_size'), -32768);
    assert.equal(p('synchronous'), 2);
    assert.equal(p('foreign_keys'), 1);
    assert.equal(p('trusted_schema'), 0);
    assert.ok(conn.isDefensive(r));
    assert.throws(() => r.prepare(`INSERT INTO tenant (name, created_at, updated_at) VALUES ('x', ${T0}, ${T0})`).run(), /readonly/i);
  } finally { r.close(); w.close(); }
});

test('assertProfile throws on a tampered setting, a foreign file or a wrong schema version', () => {
  const file = builtFile();
  const db = conn.openWriter(file);
  try {
    db.pragma('synchronous = NORMAL');
    assert.throws(() => conn.assertProfile(db, 'writer'), /synchronous=1 \(want 2\)/);
    db.pragma('synchronous = FULL');
    db.pragma('foreign_keys = OFF');
    assert.throws(() => conn.assertProfile(db, 'writer'), /foreign_keys=0/);
    db.pragma('foreign_keys = ON');
    assert.throws(() => conn.assertProfile(db, 'writer', { schemaVersion: 4 }), /user_version=3 \(want 4\)/);
  } finally { db.close(); }

  const other = path.join(path.dirname(file), 'other.db');
  const o = new Database(other); o.exec('CREATE TABLE t (x)'); o.close();
  assert.throws(() => conn.openWriter(other), /not an Omniconn workstation database/);
});

test('DEFENSIVE is detected as off when the handle is in unsafe mode', () => {
  const db = new Database(':memory:');
  try {
    assert.equal(conn.isDefensive(db), true);
    db.unsafeMode(true);
    assert.equal(conn.isDefensive(db), false);
  } finally { db.close(); }
});

test('writeTx commits before returning (commit-before-ack) and rolls back on error', () => {
  const file = builtFile();
  const w = conn.openWriter(file);
  const r = conn.openReader(file);
  try {
    const id = conn.writeTx(w, (db) => db.prepare(`INSERT INTO tenant (name, created_at, updated_at) VALUES ('ack', ${T0}, ${T0}) RETURNING id`).get().id);
    // Visible to another connection as soon as writeTx returned: it was committed, not just executed.
    assert.equal(r.prepare('SELECT name FROM tenant WHERE id = ?').get(id).name, 'ack');
    assert.throws(() => conn.writeTx(w, (db) => {
      db.prepare(`INSERT INTO tenant (name, created_at, updated_at) VALUES ('lost', ${T0}, ${T0})`).run();
      throw new Error('ingest failed');
    }), /ingest failed/);
    assert.equal(r.prepare(`SELECT count(*) AS n FROM tenant WHERE name = 'lost'`).get().n, 0);
    assert.equal(w.inTransaction, false);
  } finally { r.close(); w.close(); }
});

test('checkpoint: PASSIVE and TRUNCATE are allowed, other modes are not in the profile', () => {
  const db = conn.openWriter(builtFile());
  try {
    assert.equal(conn.checkpoint(db, 'PASSIVE').busy, 0);
    assert.equal(conn.checkpoint(db, 'TRUNCATE').log, 0); // WAL truncated to zero frames
    assert.throws(() => conn.checkpoint(db, 'FULL'), /not in the profile/);
  } finally { db.close(); }
});
