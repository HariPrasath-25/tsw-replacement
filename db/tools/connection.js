'use strict';
// Reference connection profile for the workstation database (req 97, P1, ADR-003).
// The service must open every connection through an equivalent of openWriter / openReader and refuse
// to start if assertProfile throws. Full rationale: docs/db/CONNECTION_PROFILE.md.

const Database = require('better-sqlite3');
const { assertSqliteVersion } = require('./lib/schema');

const APPLICATION_ID = 1330466377; // 0x4F4D4E49 'OMNI' (00_header.sql)
const SCHEMA_VERSION = 3;          // PRAGMA user_version declared in 00_header.sql

// Expected values as PRAGMA reads them back (numbers, or strings for journal_mode).
const COMMON = {
  journal_mode: 'wal',
  synchronous: 2,            // FULL: fsync the WAL on every commit, so COMMIT = durable (req 97)
  foreign_keys: 1,
  trusted_schema: 0,         // schema-embedded SQL functions/virtual tables cannot run with app privilege
  busy_timeout: 5000,
  temp_store: 2,             // MEMORY: sorts/temp b-trees never hit disk
  mmap_size: 0,              // I/O faults return SQLITE_IOERR instead of crashing the process
  journal_size_limit: 67108864, // after a TRUNCATE/RESTART checkpoint, the WAL file is cut back to <= 64 MB
};
const PROFILES = {
  writer: { ...COMMON, wal_autocheckpoint: 0, cache_size: -65536, query_only: 0 },   // service owns checkpoints; 64 MiB cache
  reader: { ...COMMON, wal_autocheckpoint: 0, cache_size: -32768, query_only: 1 },   // 32 MiB cache, read-only
};

/** Apply the profile's pragmas to an open handle (order matters: journal_mode first). */
function applyProfile(db, role) {
  const p = PROFILES[role];
  if (!p) throw new Error(`unknown connection role ${role}`);
  if (role === 'writer') db.pragma('journal_mode = WAL'); // persistent in the file; readers only assert it
  for (const [k, v] of Object.entries(p)) {
    if (k === 'journal_mode') continue;
    db.pragma(`${k} = ${v}`);
  }
}

/**
 * Throw if any setting differs from the profile, if DEFENSIVE is off, or if the file is not an
 * Omniconn workstation database of the expected schema version.
 */
function assertProfile(db, role, opts = {}) {
  const p = PROFILES[role];
  if (!p) throw new Error(`unknown connection role ${role}`);
  const bad = [];
  for (const [k, want] of Object.entries(p)) {
    const got = db.pragma(k, { simple: true });
    if (String(got).toLowerCase() !== String(want)) bad.push(`${k}=${got} (want ${want})`);
  }
  const appId = db.pragma('application_id', { simple: true });
  if (appId !== APPLICATION_ID) bad.push(`application_id=${appId} (want ${APPLICATION_ID}): not an Omniconn workstation database`);
  const uv = db.pragma('user_version', { simple: true });
  const wantUv = opts.schemaVersion ?? SCHEMA_VERSION;
  if (uv !== wantUv) bad.push(`user_version=${uv} (want ${wantUv})`);
  if (!isDefensive(db)) bad.push('DEFENSIVE is off (sqlite_schema is writable)');
  if (bad.length) throw new Error(`connection profile (${role}) violated: ${bad.join('; ')}`);
  return true;
}

/**
 * DEFENSIVE has no PRAGMA to read it back, so test its effect: with writable_schema ON, a defensive
 * handle refuses even to PREPARE a write to sqlite_schema (nothing executes, so this is safe on a
 * live file and works under query_only). Leaves writable_schema OFF.
 */
function isDefensive(db) {
  db.pragma('writable_schema = ON');
  try {
    db.prepare('UPDATE sqlite_schema SET sql = sql WHERE 0');
    return false;
  } catch (e) {
    return /may not be modified/.test(e.message);
  } finally {
    db.pragma('writable_schema = OFF');
  }
}

/** Open the single writer connection (the service). Writes must use BEGIN IMMEDIATE. */
function openWriter(file, opts = {}) {
  const db = new Database(file, { fileMustExist: true });
  try {
    assertSqliteVersion(db);
    applyProfile(db, 'writer');
    assertProfile(db, 'writer', opts);
    return db;
  } catch (e) { db.close(); throw e; }
}

/** Open a reader connection (reports, statistics). query_only=ON: it can never take a write lock. */
function openReader(file, opts = {}) {
  const db = new Database(file, { fileMustExist: true });
  try {
    assertSqliteVersion(db);
    applyProfile(db, 'reader');
    assertProfile(db, 'reader', opts);
    return db;
  } catch (e) { db.close(); throw e; }
}

/**
 * Run fn(db) in a BEGIN IMMEDIATE transaction and return its result only after COMMIT returned.
 * Callers acknowledge to the source / show as recorded only after this returns (req 97).
 */
function writeTx(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const r = fn(db);
    db.exec('COMMIT');
    return r;
  } catch (e) {
    if (db.inTransaction) db.exec('ROLLBACK');
    throw e;
  }
}

/**
 * Checkpoint step for the service's writer thread (ADR-003): PASSIVE on the timer, TRUNCATE when idle.
 * Returns {busy, log, checkpointed} from PRAGMA wal_checkpoint.
 */
function checkpoint(db, mode = 'PASSIVE') {
  if (!['PASSIVE', 'TRUNCATE'].includes(mode)) throw new Error(`checkpoint mode ${mode} not in the profile`);
  return db.pragma(`wal_checkpoint(${mode})`)[0];
}

module.exports = {
  APPLICATION_ID, SCHEMA_VERSION, PROFILES, applyProfile, assertProfile, isDefensive,
  openWriter, openReader, writeTx, checkpoint,
};
