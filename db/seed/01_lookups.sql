-- Seed 01: lookups — system, vendor, protocol (M2: N1, N6)
--
-- Idempotent: every INSERT is ON CONFLICT DO NOTHING, so applying this file twice changes nothing.
-- Fixed ids: other seeds and schema defaults (controller.system_id DEFAULT 1) rely on them.
-- created_at / updated_at = 1793923200000 (2026-11-06T00:00:00Z) so builds are deterministic.

-- Monitored systems (req 6, Section 2). Fire is the only system in release 1; the others are
-- reserved so later releases add rows, not schema.
INSERT INTO system (id, code, name, name_key, created_at, updated_at) VALUES
    (1, 'fire',   'Fire',                 'system.fire',   1793923200000, 1793923200000),
    (2, 'bms',    'Building management',  'system.bms',    1793923200000, 1793923200000),
    (3, 'energy', 'Energy',               'system.energy', 1793923200000, 1793923200000),
    (4, 'access', 'Access control',       'system.access', 1793923200000, 1793923200000),
    (5, 'cctv',   'CCTV',                 'system.cctv',   1793923200000, 1793923200000),
    (6, 'other',  'Other',                'system.other',  1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Vendors known at release 1. Others are added by commissioning (match_key keeps them unique).
INSERT INTO vendor (id, name, created_at, updated_at) VALUES
    (1, 'Simplex',  1793923200000, 1793923200000),
    (2, 'Omniconn', 1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Protocols: the Section 13 proposed module catalogue (BACnet, Modbus, CIP, Simplex, SNMP).
-- Entries are not a statement that a module is developed or licensed. The exact meaning and
-- scope of CIP is still to be recorded (Section 13); M8 links protocols to module versions.
INSERT INTO protocol (id, code, name, name_key, created_at, updated_at) VALUES
    (1, 'simplex', 'Simplex', 'protocol.simplex', 1793923200000, 1793923200000),
    (2, 'bacnet',  'BACnet',  'protocol.bacnet',  1793923200000, 1793923200000),
    (3, 'modbus',  'Modbus',  'protocol.modbus',  1793923200000, 1793923200000),
    (4, 'cip',     'CIP',     'protocol.cip',     1793923200000, 1793923200000),
    (5, 'snmp',    'SNMP',    'protocol.snmp',    1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;
