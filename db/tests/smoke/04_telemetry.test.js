'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('04_telemetry: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  const keyId = insert(db, 'telemetry_key', { code: 'sensitivity', name: 'Sensitivity', unit: '%/ft', value_kind: 'numeric', storage_mode: 'deadband', deadband: 0.1 });
  const cpuId = insert(db, 'telemetry_key', { code: 'cpu_pct', name: 'CPU', unit: '%', value_kind: 'numeric', storage_mode: 'interval', interval_sec: 60, rollup: 'hourly' });
  insert(db, 'device_type_telemetry', { device_type_id: f.deviceTypeId, telemetry_key_id: keyId, advisory_high: 3.5 });
  insert(db, 'vendor_key_map', { vendor_id: f.simplexVendorId, raw_key: 'presentSensitivitySelected', telemetry_key_id: keyId });
  insert(db, 'telemetry', { device_id: f.deviceId, telemetry_key_id: keyId, ts: T0, value: 2.1 });
  insert(db, 'gateway_telemetry', { gateway_id: f.gatewayId, telemetry_key_id: cpuId, ts: T0, value: 12.5 });
  insert(db, 'telemetry_rollup', {
    source_kind: 'gateway', source_id: f.gatewayId, telemetry_key_id: cpuId, period: 'hour', period_ts: T0,
    min_value: 10, max_value: 15, avg_value: 12.5, last_value: 12.5, samples: 60,
  });
  assertModuleCovered(db, '04_telemetry');
  db.close();
});
