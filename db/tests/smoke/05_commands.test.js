'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, T0 } = require('../helpers');

test('05_commands: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  const silenceId = insert(db, 'command_type', { system: 'fire', code: 'silence', name: 'Silence', target: 'controller', permission_id: f.permissionId, pin_policy: 'if_enabled' });
  const syncId = insert(db, 'command_type', { system: 'fire', code: 'sync_clock', name: 'Sync clock', target: 'controller', permission_id: f.permissionId, allow_schedule: 1 });
  const schedId = insert(db, 'command_schedule', {
    name: 'Nightly clock sync', command_type_id: syncId, site_id: f.siteId, controller_id: f.controllerId,
    cron_expr: '0 3 * * *', created_by: f.userId, created_at: T0,
  });
  const runId = insert(db, 'schedule_run', { command_schedule_id: schedId, due_at: T0, started_at: T0, status: 'running' });
  insert(db, 'command', {
    correlation_id: 'c-0001', user_id: f.userId, command_type_id: silenceId, controller_id: f.controllerId,
    status: 'pending', requested_at: T0, expires_at: T0 + 30000, raw_json: '{"cmd":"silence"}',
  });
  insert(db, 'command', {
    correlation_id: 'c-0002', user_id: f.userId, command_type_id: syncId, controller_id: f.controllerId,
    status: 'success', requested_at: T0, expires_at: T0 + 30000, completed_at: T0 + 400, raw_json: '{}', schedule_run_id: runId,
  });
  assertModuleCovered(db, '05_commands');
  db.close();
});
