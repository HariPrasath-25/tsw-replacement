'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, hex, T0 } = require('../helpers');

test('01_tenancy: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db); // tenant, site, space
  const planId = insert(db, 'floor_plan', {
    space_id: f.floorId, file_name: 'f16.png', mime_type: 'image/png', width_px: 4000, height_px: 3000,
    size_bytes: 1048576, sha256: hex(64), storage_path: 'plans/f16.png', uploaded_by_user_account_id: f.userId, uploaded_at: T0,
  });
  insert(db, 'plan_placement', { floor_plan_id: planId, device_id: f.deviceId, x: 0.25, y: 0.5, placed_by_user_account_id: f.userId, placed_at: T0 });
  insert(db, 'plan_placement', { floor_plan_id: planId, controller_id: f.controllerId, x: 0.1, y: 0.1, placed_at: T0 });
  insert(db, 'plan_placement', { floor_plan_id: planId, gateway_id: f.gatewayId, x: 0.9, y: 0.9, placed_at: T0 });
  assertModuleCovered(db, '01_tenancy');
  db.close();
});
