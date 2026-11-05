'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('02_sources: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db); // gateway, gateway_hardware, controller, device_category, device_type, device
  insert(db, 'vendor_type_map', { vendor: 'Simplex', vendor_type: 'SMOKE DETECTOR', device_type_id: f.deviceTypeId });
  insert(db, 'device_hardware', {
    device_id: f.deviceId, controller_id: f.controllerId, address: 'L1-M1', address_json: '{"loop":1,"point":"M1"}',
    vendor_type: 'SMOKE DETECTOR', installed_at: T0, changed_by_user_account_id: f.userId,
  });
  insert(db, 'device_tag', { device_id: f.deviceId, tag: 'kitchen' });
  insert(db, 'device_state', {
    device_id: f.deviceId, states_json: '["trouble","supervisory"]', primary_state: 'trouble',
    updated_src_time: T0, updated_rcv_time: T0 + 5, last_seen_at: T0 + 5,
  });
  insert(db, 'device_state_history', {
    device_id: f.deviceId, old_states_json: '["normal"]', new_states_json: '["trouble"]', new_primary_state: 'trouble',
    src_time: T0, rcv_time: T0 + 5,
  });
  assertModuleCovered(db, '02_sources');
  db.close();
});
