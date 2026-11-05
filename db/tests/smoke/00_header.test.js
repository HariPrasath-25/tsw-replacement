'use strict';
const { test } = require('node:test');
const { freshDb, insert, assertModuleCovered, T0 } = require('../helpers');

test('00_header: every table accepts a valid row', () => {
  const db = freshDb();
  insert(db, 'schema_version', { version: 2, applied_at: T0, description: 'Draft v2 baseline' });
  assertModuleCovered(db, '00_header');
  db.close();
});
