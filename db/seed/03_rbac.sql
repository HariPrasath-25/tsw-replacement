-- Seed 03: rbac — permissions, built-in roles, role-permission matrix (M2: G4, N6; req 56, 57; Section 13)
--
-- Code list and both role matrices approved 2026-11-06 (ADR-007). Idempotent: ON CONFLICT DO NOTHING.
-- Seeds apply to fresh builds only; after the schema freeze, matrix changes ship as migrations.

-- Permissions. Fire and platform: req 57, one code per listed action. Gateway: Section 13.
-- is_central_grant_required = 1: also needs a scoped, single-use central grant (Section 13, M8).
INSERT INTO permission (id, code, domain, description, name_key, is_central_grant_required, created_at, updated_at) VALUES
    -- fire (req 57)
    (1,  'alarm.view',                'fire',     'View alarms, devices and plans',                  'permission.alarm.view',                0, 1793923200000, 1793923200000),
    (2,  'alarm.acknowledge',         'fire',     'Acknowledge alarms',                              'permission.alarm.acknowledge',         0, 1793923200000, 1793923200000),
    (3,  'panel.silence',             'fire',     'Silence a fire panel',                            'permission.panel.silence',             0, 1793923200000, 1793923200000),
    (4,  'panel.reset',               'fire',     'Reset a fire panel',                              'permission.panel.reset',               0, 1793923200000, 1793923200000),
    (5,  'device.disable',            'fire',     'Disable and enable devices',                      'permission.device.disable',            0, 1793923200000, 1793923200000),
    (6,  'device.discover',           'fire',     'Request device discovery',                        'permission.device.discover',           0, 1793923200000, 1793923200000),
    (7,  'plan.edit',                 'fire',     'Edit floor plans and device mapping',             'permission.plan.edit',                 0, 1793923200000, 1793923200000),
    -- platform (req 57)
    (8,  'user.manage',               'platform', 'Manage users and roles',                          'permission.user.manage',               0, 1793923200000, 1793923200000),
    (9,  'tenant.manage',             'platform', 'Manage tenants',                                  'permission.tenant.manage',             0, 1793923200000, 1793923200000),
    (10, 'setting.manage',            'platform', 'Manage settings',                                 'permission.setting.manage',            0, 1793923200000, 1793923200000),
    (11, 'licence.manage',            'platform', 'Manage the licence',                              'permission.licence.manage',            0, 1793923200000, 1793923200000),
    (12, 'data.export',               'platform', 'Export data',                                     'permission.data.export',               0, 1793923200000, 1793923200000),
    (13, 'analytics.operator.view',   'platform', 'View per-operator analytics',                     'permission.analytics.operator.view',   0, 1793923200000, 1793923200000),
    (14, 'audit.read',                'platform', 'Read the audit log',                              'permission.audit.read',                0, 1793923200000, 1793923200000),
    -- gateway (Section 13)
    (15, 'gateway.view',              'gateway',  'View gateway dashboard and health',               'permission.gateway.view',              0, 1793923200000, 1793923200000),
    (16, 'gateway.network.configure', 'gateway',  'Change gateway IP and network settings',          'permission.gateway.network.configure', 0, 1793923200000, 1793923200000),
    (17, 'gateway.service.manage',    'gateway',  'Start, stop and restart allowlisted services',    'permission.gateway.service.manage',    1, 1793923200000, 1793923200000),
    (18, 'gateway.module.install',    'gateway',  'Install a gateway protocol module',               'permission.gateway.module.install',    1, 1793923200000, 1793923200000),
    (19, 'gateway.module.configure',  'gateway',  'Configure a gateway protocol module',             'permission.gateway.module.configure',  1, 1793923200000, 1793923200000),
    (20, 'gateway.module.activate',   'gateway',  'Activate a gateway protocol module',              'permission.gateway.module.activate',   1, 1793923200000, 1793923200000),
    (21, 'gateway.module.remove',     'gateway',  'Update, disable or remove a gateway module',      'permission.gateway.module.remove',     1, 1793923200000, 1793923200000),
    (22, 'gateway.access.approve',    'gateway',  'Approve gateway access requests and entitlements','permission.gateway.access.approve',    0, 1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Built-in roles: four fire roles (req 56) and four Gateway Management roles (Section 13).
INSERT INTO role (id, name, name_key, is_builtin, created_at, updated_at) VALUES
    (1, 'Administrator',                         'role.administrator',          1, 1793923200000, 1793923200000),
    (2, 'Engineer',                              'role.engineer',               1, 1793923200000, 1793923200000),
    (3, 'Operator',                              'role.operator',               1, 1793923200000, 1793923200000),
    (4, 'Viewer',                                'role.viewer',                 1, 1793923200000, 1793923200000),
    (5, 'Gateway Viewer',                        'role.gateway_viewer',         1, 1793923200000, 1793923200000),
    (6, 'Gateway Operator / Commissioning User', 'role.gateway_operator',       1, 1793923200000, 1793923200000),
    (7, 'Omniconn Gateway Administrator',        'role.gateway_administrator',  1, 1793923200000, 1793923200000),
    (8, 'Central Access / Module Approver',      'role.gateway_access_approver', 1, 1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Role -> permission matrix. Fire roles are cumulative (Viewer < Operator < Engineer < Administrator)
-- and hold no gateway.* code: a fire administrator is not a gateway administrator (Section 13).
-- gateway.network.configure is granted per user, not bundled in Gateway Operator (Section 13; ADR-009).
-- The approver role holds approval only, never execution (Section 13).
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
    ('Viewer', 'alarm.view'),
    ('Operator', 'alarm.view'), ('Operator', 'alarm.acknowledge'), ('Operator', 'panel.silence'),
    ('Operator', 'panel.reset'), ('Operator', 'data.export'),
    ('Engineer', 'alarm.view'), ('Engineer', 'alarm.acknowledge'), ('Engineer', 'panel.silence'),
    ('Engineer', 'panel.reset'), ('Engineer', 'data.export'), ('Engineer', 'device.disable'),
    ('Engineer', 'device.discover'), ('Engineer', 'plan.edit'),
    ('Administrator', 'alarm.view'), ('Administrator', 'alarm.acknowledge'), ('Administrator', 'panel.silence'),
    ('Administrator', 'panel.reset'), ('Administrator', 'data.export'), ('Administrator', 'device.disable'),
    ('Administrator', 'device.discover'), ('Administrator', 'plan.edit'), ('Administrator', 'user.manage'),
    ('Administrator', 'tenant.manage'), ('Administrator', 'setting.manage'), ('Administrator', 'licence.manage'),
    ('Administrator', 'analytics.operator.view'), ('Administrator', 'audit.read'),
    ('Gateway Viewer', 'gateway.view'),
    ('Gateway Operator / Commissioning User', 'gateway.view'),
    ('Omniconn Gateway Administrator', 'gateway.view'), ('Omniconn Gateway Administrator', 'gateway.network.configure'),
    ('Omniconn Gateway Administrator', 'gateway.service.manage'), ('Omniconn Gateway Administrator', 'gateway.module.install'),
    ('Omniconn Gateway Administrator', 'gateway.module.configure'), ('Omniconn Gateway Administrator', 'gateway.module.activate'),
    ('Omniconn Gateway Administrator', 'gateway.module.remove'),
    ('Central Access / Module Approver', 'gateway.access.approve')
) AS m
JOIN role r ON r.name = m.column1
JOIN permission p ON p.code = m.column2
WHERE true
ON CONFLICT DO NOTHING;
