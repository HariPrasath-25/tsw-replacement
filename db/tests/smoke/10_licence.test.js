'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('10_licence: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  insert(db, 'licence', { licence_key_enc: Buffer.from([1, 2, 3]), entitlements_json: '{"sites":1}', activated_at: T0, activation_mode: 'offline' });
  insert(db, 'document_acceptance', { user_id: f.userId, document: 'terms', doc_version: '1.0', accepted_at: T0 });
  assertModuleCovered(db, '10_licence');
  db.close();
});
