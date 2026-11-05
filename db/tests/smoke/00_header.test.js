'use strict';
const { test } = require('node:test');
const { freshDb, insert, assertModuleCovered, hex, T0 } = require('../helpers');

test('00_header: every table accepts a valid row', () => {
  const db = freshDb();
  // The build already logged one row per module (ADR-004); a later migration appends another.
  insert(db, 'schema_version', { version: 4, module: 'm0004_example', checksum: hex(64), applied_at: T0, applied_by: 'test', description: 'example migration' });
  assertModuleCovered(db, '00_header');
  db.close();
});
