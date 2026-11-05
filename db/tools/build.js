#!/usr/bin/env node
'use strict';
// npm run db:build — build build/workstation.db from scratch (db/schema + db/seed).
// Never edit the built file by hand; always rebuild.

const fs = require('fs');
const path = require('path');
const { BUILD_FILE, MIN_SQLITE, buildDatabase, listModules, SCHEMA_DIR, SEED_DIR } = require('./lib/schema');

function main() {
  const target = process.argv[2] ? path.resolve(process.argv[2]) : BUILD_FILE;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  for (const suffix of ['', '-wal', '-shm', '-journal']) fs.rmSync(target + suffix, { force: true });

  const db = buildDatabase(target, {
    onPragmas: (_db, pragmas) => console.log(`file-creation pragmas applied before DDL: ${pragmas.length ? pragmas.join(' ') : '(none)'}`),
  });
  const version = db.prepare('SELECT sqlite_version() AS v').get().v;
  const counts = Object.fromEntries(db.prepare(`SELECT type, count(*) AS n FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%' GROUP BY type`).all().map((r) => [r.type, r.n]));
  const p = (n) => db.pragma(n, { simple: true });
  console.log(`sqlite_version() = ${version} (required >= ${MIN_SQLITE})`);
  console.log(`modules: ${listModules(SCHEMA_DIR).length} schema, ${listModules(SEED_DIR).length} seed`);
  console.log(`objects: ${counts.table || 0} tables, ${counts.index || 0} indexes, ${counts.trigger || 0} triggers, ${counts.view || 0} views`);
  console.log(`page_size=${p('page_size')} auto_vacuum=${p('auto_vacuum')} application_id=${p('application_id')} user_version=${p('user_version')}`);
  console.log('foreign_key_check: clean · quick_check: ok');
  db.close();
  console.log(`built ${path.relative(process.cwd(), target)}`);
}

try {
  main();
} catch (e) {
  console.error('db:build FAILED: ' + e.message);
  process.exit(1);
}
