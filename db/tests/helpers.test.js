'use strict';
// The helpers themselves: explain/assertNoScan must distinguish SEARCH from SCAN on hot tables.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { freshDb, insertFixtures, explain, assertNoScan, expectAbort } = require('./helpers');

test('explain + assertNoScan: indexed lookup passes, full scan fails', () => {
  const db = freshDb();
  insertFixtures(db);
  const byDevice = explain(db, 'SELECT id FROM event WHERE device_id = ? AND rcv_time > ? ORDER BY rcv_time', [1, 0]);
  assert.ok(byDevice.some((r) => /SEARCH event USING (COVERING )?INDEX ix_event_device/.test(r.detail)), JSON.stringify(byDevice));
  assertNoScan(byDevice);

  const byCondition = explain(db, 'SELECT id FROM event WHERE condition_id = 7'); // no index until M5 (ADR-002)
  assert.throws(() => assertNoScan(byCondition), /scans event/);
  db.close();
});

test('expectAbort fails when the statement succeeds or the message differs', () => {
  const db = freshDb();
  assert.throws(() => expectAbort(db, 'SELECT 1', 'anything'));
  assert.throws(() => expectAbort(db, 'SELECT * FROM no_such_table', 'append-only'));
  expectAbort(db, 'SELECT * FROM no_such_table', 'no such table');
  db.close();
});
