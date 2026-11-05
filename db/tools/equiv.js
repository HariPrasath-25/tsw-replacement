#!/usr/bin/env node
'use strict';
// npm run db:equiv — prove db/schema modules build the same schema as a reference SQL file.
// M0: reference = frozen Draft v2, and the result must be identical. After M1 changes the schema,
// this tool is still useful as `node db/tools/equiv.js --diff` to list what changed vs Draft v2.

const { REFERENCE_FILE, buildDatabase, buildFromFile, schemaRows, tableDetail } = require('./lib/schema');

/** Compare two DBs. Returns a list of human-readable differences (empty = equivalent). */
function compare(refDb, modDb) {
  const diffs = [];
  const key = (r) => `${r.type} ${r.name}`;
  const ref = new Map(schemaRows(refDb).map((r) => [key(r), r]));
  const mod = new Map(schemaRows(modDb).map((r) => [key(r), r]));
  for (const [k, r] of ref) {
    if (!mod.has(k)) diffs.push(`missing in modules: ${k}`);
    else if (mod.get(k).sql !== r.sql || mod.get(k).tbl_name !== r.tbl_name) {
      diffs.push(`different: ${k}\n    reference: ${r.sql}\n    modules:   ${mod.get(k).sql}`);
    }
  }
  for (const k of mod.keys()) if (!ref.has(k)) diffs.push(`extra in modules: ${k}`);

  const a = tableDetail(refDb), b = tableDetail(modDb);
  for (const t of Object.keys(a)) {
    if (!b[t]) continue; // already reported
    for (const part of ['list', 'columns', 'fks', 'indexes']) {
      if (JSON.stringify(a[t][part]) !== JSON.stringify(b[t][part])) diffs.push(`pragma ${part} differs for table ${t}`);
    }
  }
  return diffs;
}

function run(referenceFile = REFERENCE_FILE) {
  const refDb = buildFromFile(referenceFile);
  const modDb = buildDatabase(':memory:', { seed: false });
  try {
    return { diffs: compare(refDb, modDb), objects: schemaRows(refDb).length };
  } finally {
    refDb.close();
    modDb.close();
  }
}

if (require.main === module) {
  try {
    const { diffs, objects } = run();
    if (diffs.length) {
      console.error(`db:equiv: modules differ from Draft v2 (${diffs.length} differences)`);
      for (const d of diffs) console.error('  ' + d);
      process.exit(process.argv.includes('--diff') ? 0 : 1);
    }
    console.log(`db:equiv: modules == Draft v2 (${objects} schema objects, normalised sqlite_schema and table/fk/index pragmas identical)`);
  } catch (e) {
    console.error('db:equiv FAILED: ' + e.message);
    process.exit(1);
  }
}

module.exports = { compare, run };
