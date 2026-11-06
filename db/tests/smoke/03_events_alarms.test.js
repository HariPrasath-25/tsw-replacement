'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('03_events_alarms: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  const fireId = f.fireClassId; // seeded (db/seed/02_alarm.sql)
  const sensorDirtyId = db.prepare(`SELECT id FROM condition WHERE code = 'sensor_dirty'`).get().id;
  const eventId = insert(db, 'event', {
    gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'seq-1',
    controller_id: f.controllerId, device_id: f.deviceId, event_type: 'alarm', alarm_class_id: fireId,
    condition_id: sensorDirtyId, src_time: T0, rcv_time: T0 + 20, raw_json: '{"seq":1}',
  });
  insert(db, 'event', {
    gateway_id: f.gatewayId, gateway_hardware_id: f.gatewayHardwareId, source_event_id: 'seq-2',
    event_type: 'status', rcv_time: T0 + 30, raw_json: '{"seq":2}',
  });
  insert(db, 'alarm', {
    raised_event_id: eventId, site_id: f.siteId, controller_id: f.controllerId, device_id: f.deviceId,
    alarm_class_id: fireId, precedence: 1, raised_at: T0 + 20,
  });
  assertModuleCovered(db, '03_events_alarms');
  db.close();
});
