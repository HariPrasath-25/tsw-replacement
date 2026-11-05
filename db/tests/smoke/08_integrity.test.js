'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('08_integrity: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  insert(db, 'quarantine', { gateway_id: f.gatewayId, topic: 'omniconn/gw1/events', payload: Buffer.from('{bad json'), error: 'invalid JSON', rcv_time: T0 });
  insert(db, 'gateway_health', { gateway_id: f.gatewayId, rcv_time: T0, cpu_pct: 12.5, mem_pct: 40, disk_pct: 22, buffer_depth: 0, detail_json: '{}' });
  assertModuleCovered(db, '08_integrity');
  db.close();
});
