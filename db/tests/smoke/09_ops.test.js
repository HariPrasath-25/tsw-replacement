'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, hex, T0 } = require('../helpers');

test('09_ops: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db);
  insert(db, 'setting', { key: 'auth.pin_on_control', value_json: 'true', updated_by_user_account_id: f.userId, updated_at: T0 });
  insert(db, 'retention_policy', { data_type: 'event', keep_days: 1095, min_days: 365, updated_at: T0 });
  insert(db, 'retention_policy', { data_type: 'audit_log', keep_days: null, updated_at: T0 });
  insert(db, 'retention_run', { data_type: 'event', started_at: T0, cutoff_time: T0 - 86400000, status: 'running' });
  const backupId = insert(db, 'backup_run', {
    kind: 'pre_update', started_at: T0, finished_at: T0 + 1000, target_path: 'D:/backup/ws.db',
    size_bytes: 1024, sha256: hex(64), status: 'done',
  });
  insert(db, 'installed_component', { component: 'product', version: '1.2.0', updated_at: T0 });
  insert(db, 'update_history', {
    from_version: '1.1.0', to_version: '1.2.0', package_sha256: hex(64), source: 'offline_package',
    started_at: T0, finished_at: T0 + 60000, status: 'succeeded', backup_run_id: backupId, started_by_user_account_id: f.userId,
  });
  assertModuleCovered(db, '09_ops');
  db.close();
});
