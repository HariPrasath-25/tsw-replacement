'use strict';
const { test } = require('node:test');
const { freshDb, insert, insertFixtures, assertModuleCovered, hex, T0 } = require('../helpers');

test('06_identity: every table accepts a valid row', () => {
  const db = freshDb();
  const f = insertFixtures(db); // user_account, role, permission
  insert(db, 'user_account', { username: 'op1', display_name: 'Operator One', auth_type: 'windows', windows_sid: 'S-1-5-21-1-2-3-1001', created_at: T0 });
  insert(db, 'role_permission', { role_id: f.roleId, permission_id: f.permissionId });
  insert(db, 'user_role', { user_id: f.userId, role_id: f.roleId, tenant_id: f.tenantId, site_id: f.siteId, space_id: f.floorId, granted_by: f.userId, granted_at: T0 });
  insert(db, 'directory_group_role', { group_sid: 'S-1-5-21-1-2-3-513', role_id: f.roleId, tenant_id: f.tenantId, site_id: f.siteId });
  insert(db, 'session', { user_id: f.userId, token_hash: hex(64), client_kind: 'desktop', client_host: 'MS-01', started_at: T0, last_activity: T0 });
  assertModuleCovered(db, '06_identity');
  db.close();
});
