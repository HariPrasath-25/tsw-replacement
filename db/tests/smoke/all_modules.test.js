'use strict';
// Gate: every schema module has a smoke test file in this directory.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { listModules, SCHEMA_DIR } = require('../../tools/lib/schema');

test('every schema module has a smoke test', () => {
  const have = new Set(fs.readdirSync(__dirname).map((f) => f.replace(/\.test\.js$/, '')));
  const missing = listModules(SCHEMA_DIR).map((m) => m.name).filter((n) => !have.has(n));
  assert.deepEqual(missing, [], 'modules without db/tests/smoke/<module>.test.js: ' + missing.join(', '));
});
