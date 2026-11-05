'use strict';
// Shared build logic for db:build, db:lint, db:equiv and the test helpers.
// The schema is the ordered list of db/schema/NN_<area>.sql modules, then db/seed/NN_<area>.sql.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');
const { stripComments, normalise } = require('./sql');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const SCHEMA_DIR = path.join(ROOT, 'db', 'schema');
const SEED_DIR = path.join(ROOT, 'db', 'seed');
const REFERENCE_FILE = path.join(ROOT, 'db', 'reference', 'fire_workstation_schema_draft_v2.sql');
const BUILD_FILE = path.join(ROOT, 'build', 'workstation.db');
const MIN_SQLITE = '3.45.0';
const MODULE_RE = /^\d{2}_[a-z0-9_]+\.sql$/;

/** Ordered module files of a directory ({name, file, sql}). Missing directory = no modules. */
function listModules(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => MODULE_RE.test(f))
    .sort()
    .map((f) => ({ name: f.replace(/\.sql$/, ''), file: path.join(dir, f), sql: fs.readFileSync(path.join(dir, f), 'utf8') }));
}

function versionAtLeast(actual, min) {
  const a = actual.split('.').map(Number), b = min.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  }
  return true;
}

/** Throws if the linked SQLite is older than the runtime target. Returns the version string. */
function assertSqliteVersion(db) {
  const v = db.prepare('SELECT sqlite_version() AS v').get().v;
  if (!versionAtLeast(v, MIN_SQLITE)) {
    throw new Error(`SQLite ${v} is older than the required ${MIN_SQLITE}`);
  }
  return v;
}

// File-creation pragmas (page_size, auto_vacuum, application_id...) must run on the empty file,
// before the first CREATE. Convention: they live in 00_header.sql, one PRAGMA statement per line,
// starting at the beginning of the line (a PRAGMA inside a -- comment is documentation, not code).
const USER_VERSION = /^PRAGMA\s+user_version\s*=\s*(\d+)\s*;$/i;

/** sha256 (lowercase hex) of a module's text exactly as read from disk (migration log checksum). */
function moduleChecksum(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

/** First comment line of a module (its banner), used as the migration-log description. */
function moduleDescription(text, name) {
  const m = /^--\s*(.+)$/m.exec(text);
  return m ? m[1].trim() : name;
}

const PRAGMA_LINE = /^[ \t]*PRAGMA\s+[^;]+;\s*(--.*)?$/i;

function splitHeaderPragmas(sql) {
  const pragmas = [];
  const rest = sql.split(/\r?\n/).map((line) => {
    if (!PRAGMA_LINE.test(line)) return line;
    pragmas.push(line.replace(/--.*$/, '').trim());
    return ''; // keep line numbers stable for error messages
  }).join('\n');
  return { pragmas, rest };
}

/** Run foreign_key_check and quick_check; throw with details on any problem. */
function assertIntegrity(db) {
  const fk = db.pragma('foreign_key_check');
  if (fk.length) throw new Error('foreign_key_check failed: ' + JSON.stringify(fk.slice(0, 5)));
  const qc = db.pragma('quick_check', { simple: true });
  if (qc !== 'ok') throw new Error('quick_check failed: ' + qc);
}

/**
 * Build a database from the schema (and seed) modules.
 * target: file path or ':memory:'. Returns the open better-sqlite3 handle.
 * opts.schemaDir / opts.seedDir override the source directories (used by tests).
 * opts.onPragmas(db, pragmas) is a hook called after pragmas ran and before any DDL (tests).
 */
function buildDatabase(target = ':memory:', opts = {}) {
  const schema = listModules(opts.schemaDir || SCHEMA_DIR);
  const seed = opts.seed === false ? [] : listModules(opts.seedDir || SEED_DIR);
  if (!schema.length) throw new Error('no schema modules found');

  const db = new Database(target);
  try {
    assertSqliteVersion(db);
    if (db.prepare('SELECT count(*) AS n FROM sqlite_schema').get().n !== 0) {
      throw new Error(`${target} is not empty; builds always start from a fresh file`);
    }

    // 1. File-creation pragmas, only from 00_header, before any DDL and outside a transaction.
    const modules = schema.map((m) => ({ ...m, code: m.sql }));
    modules.forEach((m, i) => {
      const { pragmas, rest } = splitHeaderPragmas(m.sql);
      if (pragmas.length && !(i === 0 && m.name.startsWith('00_'))) {
        throw new Error(`${m.name}: PRAGMA statements belong in 00_header.sql only`);
      }
      if (i === 0) { m.pragmas = pragmas; m.code = rest; }
    });
    // user_version is the schema version of record (N5, ADR-004). It is NOT a file-creation pragma:
    // it is set last, inside the build transaction, after foreign_key_check, so a failed build leaves 0.
    const header = modules[0].pragmas || [];
    const uv = header.map((p) => USER_VERSION.exec(p)).find(Boolean);
    const filePragmas = header.filter((p) => !USER_VERSION.test(p));
    for (const p of filePragmas) db.exec(p);
    if (db.prepare('SELECT count(*) AS n FROM sqlite_schema').get().n !== 0) {
      throw new Error('a header PRAGMA created schema objects');
    }
    if (opts.onPragmas) opts.onPragmas(db, filePragmas);

    // 2. DDL + seed + migration log + user_version in one transaction (atomic build).
    db.pragma('foreign_keys = ON');
    db.exec('BEGIN IMMEDIATE');
    try {
      const all = [...modules, ...seed.map((s) => ({ ...s, code: s.sql, kind: 'seed' }))];
      for (const m of all) {
        try { db.exec(m.code); } catch (e) { e.message = `${m.name}: ${e.message}`; throw e; }
      }
      if (uv) {
        const version = Number(uv[1]);
        const hasLog = db.prepare(`SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'schema_version'`).get();
        if (hasLog) {
          const ins = db.prepare(`INSERT INTO schema_version (version, module, checksum, applied_at, applied_by, description)
                                  VALUES (?, ?, ?, ?, ?, ?)`);
          const now = opts.appliedAt || Date.now();
          for (const m of all) {
            ins.run(version, (m.kind === 'seed' ? 'seed/' : '') + m.name, moduleChecksum(m.sql), now,
              opts.appliedBy || 'db:build', moduleDescription(m.sql, m.name));
          }
        }
        if (opts.beforeUserVersion) opts.beforeUserVersion(db);
        const fk = db.pragma('foreign_key_check');
        if (fk.length) throw new Error('foreign_key_check failed: ' + JSON.stringify(fk.slice(0, 5)));
        db.pragma(`user_version = ${version}`);
      }
      db.exec('COMMIT');
    } catch (e) {
      if (db.inTransaction) db.exec('ROLLBACK');
      throw e;
    }
    assertIntegrity(db);
    return db;
  } catch (e) {
    db.close();
    throw e;
  }
}

/** Load a single SQL file (the frozen reference) into a fresh in-memory DB. */
function buildFromFile(file) {
  const db = new Database(':memory:');
  db.pragma('foreign_keys = ON');
  db.exec(fs.readFileSync(file, 'utf8'));
  assertIntegrity(db);
  return db;
}

/** Schema objects in comparable normal form, sorted by type and name (rootpage ignored). */
function schemaRows(db) {
  return db.prepare(`SELECT type, name, tbl_name, sql FROM sqlite_schema
                     WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name`).all()
    .map((r) => ({ type: r.type, name: r.name, tbl_name: r.tbl_name, sql: normalise(r.sql) }));
}

/** Per-table structural detail from pragmas, for a second equivalence check. */
function tableDetail(db) {
  const out = {};
  for (const { name } of db.prepare(`SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`).all()) {
    out[name] = {
      list: db.prepare(`SELECT strict, wr, ncol FROM pragma_table_list WHERE name = ?`).get(name),
      columns: db.pragma(`table_xinfo("${name}")`),
      fks: db.pragma(`foreign_key_list("${name}")`),
      indexes: db.pragma(`index_list("${name}")`)
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((ix) => ({ ...ix, seq: undefined, cols: db.pragma(`index_xinfo("${ix.name}")`) })),
    };
  }
  return out;
}

/** Names created by CREATE TABLE / INDEX / TRIGGER / VIEW in a piece of SQL. */
function objectsDefinedIn(sql) {
  const code = stripComments(sql);
  const re = /CREATE\s+(?:UNIQUE\s+)?(TABLE|INDEX|TRIGGER|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?["`[]?(\w+)/gi;
  const out = [];
  let m;
  while ((m = re.exec(code))) out.push({ type: m[1].toLowerCase(), name: m[2] });
  return out;
}

module.exports = {
  ROOT, SCHEMA_DIR, SEED_DIR, REFERENCE_FILE, BUILD_FILE, MIN_SQLITE,
  listModules, versionAtLeast, moduleChecksum, USER_VERSION, assertSqliteVersion, splitHeaderPragmas, assertIntegrity,
  buildDatabase, buildFromFile, schemaRows, tableDetail, objectsDefinedIn,
};
