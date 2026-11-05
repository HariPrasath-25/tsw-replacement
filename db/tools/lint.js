#!/usr/bin/env node
'use strict';
// npm run db:lint — schema linter for CLAUDE.md conventions 1-9 and 13.
// Builds a fresh in-memory DB from db/schema, inspects sqlite_schema + pragmas + the CREATE text,
// and compares the violations with db/tools/lint-allow.json:
//   * a violation not in the allowlist  -> FAIL (new debt)
//   * an allowlist entry with no violation -> FAIL (stale: delete it, so the count only goes down)

const fs = require('fs');
const path = require('path');
const { ROOT, buildDatabase } = require('./lib/schema');
const { parseCreateTable, checkExpressions, stripComments } = require('./lib/sql');

const ALLOW_FILE = path.join(__dirname, 'lint-allow.json');
const DECISIONS_FILE = path.join(ROOT, 'docs', 'db', 'DECISIONS.md');

// Convention 2: tables whose ids leave the database.
const AUTOINCREMENT_TABLES = ['event', 'alarm', 'command', 'audit_log'];
// Convention 5: INTEGER UTC-ms time columns, recognised by name.
const TIME_COL = /(^|_)(at|time|ts)$|_until$|^last_(heartbeat|contact|activity|seen)$/;
// Convention 6.
const BOOL_PREFIX = /^(is|has|can)_/;
// Convention 8.
const HASH_COL = /(^|_)sha256$|_hash$/;
const UUID_COL = /(^|_)uuid$/;
// Convention 9: extensible domains that must be lookup tables, not free text / CHECK lists.
const LOOKUP_DOMAINS = ['system', 'vendor', 'protocol', 'condition'];
// Convention 13.
const SNAKE = /^[a-z][a-z0-9]*(_[a-z0-9]+)*$/;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Return every convention violation in db as [{key, rule, object, message}]. */
function lintDb(db) {
  const out = [];
  const add = (rule, object, message) => out.push({ key: `${rule}:${object}`, rule, object, message });

  const objects = db.prepare(`SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name`).all();
  const tables = objects.filter((o) => o.type === 'table');

  for (const t of tables) {
    const name = t.name;
    const info = db.prepare('SELECT strict, wr FROM pragma_table_list WHERE name = ?').get(name);
    const cols = db.pragma(`table_xinfo("${name}")`);
    const fks = db.pragma(`foreign_key_list("${name}")`);
    const indexes = db.pragma(`index_list("${name}")`).map((ix) => ({
      ...ix,
      cols: db.pragma(`index_info("${ix.name}")`).sort((a, b) => a.seqno - b.seqno).map((c) => c.name),
      where: (objects.find((o) => o.type === 'index' && o.name === ix.name) || {}).sql,
    }));
    const parsed = parseCreateTable(t.sql);
    const allChecks = checkExpressions(stripComments(t.sql)).join(' \n ');
    const colDef = (c) => (parsed.columns.find((p) => p.name === c) || {}).def || '';

    // 1. STRICT / WITHOUT ROWID
    if (!info.strict) add('strict', name, 'table is not STRICT');
    if (info.wr) add('without-rowid', name, 'WITHOUT ROWID table: needs an ADR (high-volume, natural composite key, never FK-referenced)');

    // 2. id INTEGER PRIMARY KEY (rowid tables) and AUTOINCREMENT
    if (!info.wr) {
      const pk = cols.filter((c) => c.pk > 0);
      if (!(pk.length === 1 && pk[0].name === 'id' && pk[0].type === 'INTEGER')) add('pk-id', name, 'primary key is not `id INTEGER PRIMARY KEY`');
    }
    if (AUTOINCREMENT_TABLES.includes(name) && !/\bAUTOINCREMENT\b/i.test(stripComments(t.sql))) {
      add('autoincrement', name, 'id leaves the database (archive/export/sync): use INTEGER PRIMARY KEY AUTOINCREMENT');
    }

    // 2-4. Foreign keys: naming, explicit ON DELETE, supporting index
    for (const fk of fks) {
      const c = fk.from, parent = fk.table;
      const obj = `${name}.${c}`;
      if (!(c === `${parent}_id` || c.endsWith(`_${parent}_id`))) add('fk-name', obj, `FK to ${parent} should be named ${parent}_id or <role>_${parent}_id`);

      const fkText = [colDef(c), ...parsed.constraints.filter((k) => /^FOREIGN\b/i.test(k) && new RegExp(`\\(\\s*${esc(c)}\\s*[,)]`).test(k))].join(' ');
      if (!/\bON\s+DELETE\b/i.test(fkText)) add('fk-on-delete', obj, `FK to ${parent} has no explicit ON DELETE (defaults to NO ACTION)`);

      const covered = indexes.some((ix) => ix.cols[0] === c && (!ix.partial || new RegExp(`WHERE\\s+"?${esc(c)}"?\\s+IS\\s+NOT\\s+NULL\\s*$`, 'i').test(stripComments(ix.where || '').trim())));
      if (!covered) add('fk-index', obj, `no index leads with ${c} (parent deletes and joins scan ${name})`);
    }

    for (const col of cols) {
      const c = col.name, obj = `${name}.${c}`;
      const hasCheck = (re) => re.test(allChecks);

      // 5. Times
      if (TIME_COL.test(c)) {
        if (col.type !== 'INTEGER') add('time-type', obj, 'time column must be INTEGER UTC milliseconds');
        else if (!hasCheck(new RegExp(`\\b${esc(c)}\\s*>\\s*0\\b`))) add('time-positive', obj, `time column has no CHECK (${c} > 0)`);
      }

      // 6. Booleans
      const isBoolCheck = hasCheck(new RegExp(`\\b${esc(c)}\\s+IN\\s*\\(\\s*0\\s*,\\s*1\\s*\\)`, 'i'));
      if (BOOL_PREFIX.test(c)) {
        if (col.type !== 'INTEGER' || !col.notnull || !isBoolCheck) add('bool', obj, `boolean must be INTEGER NOT NULL CHECK (${c} IN (0,1))`);
      } else if (isBoolCheck) {
        add('bool-name', obj, 'boolean column must be named is_* / has_* / can_*');
      }

      // 7. JSON
      if (/_json$/.test(c)) {
        if (col.type !== 'TEXT' || !hasCheck(new RegExp(`json_valid\\s*\\(\\s*${esc(c)}\\s*\\)`, 'i'))) add('json', obj, `*_json must be TEXT with CHECK (json_valid(${c}))`);
      }

      // 8. Hashes and UUIDs
      if (HASH_COL.test(c)) {
        const ok = col.type === 'TEXT' && hasCheck(new RegExp(`length\\s*\\(\\s*${esc(c)}\\s*\\)\\s*=\\s*64`, 'i')) && hasCheck(new RegExp(`\\b${esc(c)}\\s+NOT\\s+GLOB\\b`, 'i'));
        if (!ok) add('hash', obj, `sha256 must be TEXT CHECK (length(${c})=64 AND ${c} NOT GLOB '*[^0-9a-f]*')`);
      }
      if (UUID_COL.test(c)) {
        const ok = col.type === 'TEXT' && hasCheck(new RegExp(`length\\s*\\(\\s*${esc(c)}\\s*\\)\\s*=\\s*36`, 'i'));
        if (!ok) add('uuid', obj, 'uuid must be lowercase TEXT(36) with a CHECK');
      }

      // 9. Extensible domains
      if (LOOKUP_DOMAINS.includes(c) && col.type === 'TEXT') add('enum-lookup', obj, `${c} is an extensible domain: use a lookup table + ${c}_id FK`);
    }

    // 13. Table naming
    if (!SNAKE.test(name)) add('naming', `table ${name}`, 'table name must be snake_case');
    else if (/[^s]s$/.test(name)) add('naming', `table ${name}`, 'table name must be singular');
  }

  // 13. Index / trigger / view naming
  for (const o of objects) {
    if (o.type === 'index') {
      const unique = /^CREATE\s+UNIQUE\b/i.test(o.sql || '');
      const want = `${unique ? 'ux' : 'ix'}_${o.tbl_name}_`;
      if (!o.name.startsWith(want)) add('naming', `index ${o.name}`, `index name must start with ${want}<cols>`);
    } else if (o.type === 'trigger') {
      if (!o.name.startsWith(`trg_${o.tbl_name}_`)) add('naming', `trigger ${o.name}`, `trigger name must start with trg_${o.tbl_name}_<rule>`);
    } else if (o.type === 'view') {
      if (!/^v_[a-z0-9_]+$/.test(o.name)) add('naming', `view ${o.name}`, 'view name must be v_<snake_case>');
    }
  }
  return out;
}

/** Validate the allowlist and compare it with the violations. */
function checkAllowlist(violations, allow, decisionsText) {
  const problems = [];
  const adrs = new Set((decisionsText.match(/^##+\s+(ADR-\d{3})\b/gm) || []).map((h) => h.match(/ADR-\d{3}/)[0]));
  const seen = new Set();
  for (const e of allow) {
    if (!e.key || typeof e.key !== 'string') { problems.push(`allowlist entry without key: ${JSON.stringify(e)}`); continue; }
    if (seen.has(e.key)) problems.push(`duplicate allowlist entry: ${e.key}`);
    seen.add(e.key);
    if (!e.reason || !String(e.reason).trim()) problems.push(`allowlist entry ${e.key} has no reason`);
    if (!/^ADR-\d{3}$/.test(e.adr || '')) problems.push(`allowlist entry ${e.key} has no ADR id`);
    else if (!adrs.has(e.adr)) problems.push(`allowlist entry ${e.key} cites ${e.adr}, which is not in DECISIONS.md`);
  }
  const found = new Set(violations.map((v) => v.key));
  const fresh = violations.filter((v) => !seen.has(v.key));
  const stale = allow.filter((e) => e.key && !found.has(e.key));
  return { problems, fresh, stale, allowed: violations.length - fresh.length };
}

function loadAllowlist(file = ALLOW_FILE) {
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : [];
}

function main() {
  const db = buildDatabase(':memory:');
  const violations = lintDb(db);
  db.close();
  const decisions = fs.existsSync(DECISIONS_FILE) ? fs.readFileSync(DECISIONS_FILE, 'utf8') : '';
  const { problems, fresh, stale, allowed } = checkAllowlist(violations, loadAllowlist(), decisions);

  const byRule = {};
  for (const v of violations) byRule[v.rule] = (byRule[v.rule] || 0) + 1;
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(violations, null, 2));
    return;
  }
  console.log(`db:lint: ${violations.length} violations (${allowed} allowlisted)`);
  console.log('  by rule: ' + Object.entries(byRule).sort().map(([r, n]) => `${r}=${n}`).join(' '));
  for (const p of problems) console.error('  ALLOWLIST: ' + p);
  for (const v of fresh) console.error(`  NEW   ${v.key} — ${v.message}`);
  for (const e of stale) console.error(`  STALE ${e.key} — no longer violated; remove it from lint-allow.json`);
  if (problems.length || fresh.length || stale.length) {
    console.error(`db:lint FAILED: ${fresh.length} new, ${stale.length} stale, ${problems.length} allowlist problems`);
    process.exit(1);
  }
  console.log('db:lint: OK (no new violations, no stale allowlist entries)');
}

if (require.main === module) {
  try { main(); } catch (e) { console.error('db:lint FAILED: ' + e.message); process.exit(1); }
}

module.exports = { lintDb, checkAllowlist, loadAllowlist, ALLOW_FILE };
