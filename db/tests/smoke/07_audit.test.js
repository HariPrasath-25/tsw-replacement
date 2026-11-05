'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, hex, T0 } = require('../helpers');

test('07_audit: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  insert(db, 'audit_log', {
    at: T0, user_id: f.userId, client_host: 'MS-01', action: 'auth.login', outcome: 'success',
    prev_hash: hex(64, '0'), row_hash: hex(64, 'b'),
  });
  assertModuleCovered(db, '07_audit');
  db.close();
});
